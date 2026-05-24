// Mac-only — depends on `CodexAppServerClient`, which spawns a child process.
// iOS reads the CloudKit payload PeluMac produces instead of running its own
// provider.
#if os(macOS)
import Foundation
import Darwin

/// Owns a `CodexAppServerClient`, drives periodic polling, exposes the most
/// recent snapshot, and rebuilds the app-server connection after transient
/// startup or read failures.
///
/// Threading: callbacks fire on a private serial queue; consumers should
/// hop to main themselves if updating UI. `latestSnapshot` reads are
/// synchronized via the queue.
public final class CodexQuotaProvider: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case starting
        case ready
        /// Codex binary not located, or initialize handshake failed. Caller
        /// should fall back to the jsonl reader.
        case unavailable(reason: String)
    }

    /// Polling cadence mode. `unavailable` lives in `Status` instead — when
    /// we're unavailable we don't poll at all, so it isn't a cadence.
    public enum Mode: Sendable {
        /// Foreground / recent activity. Poll every `activeInterval`.
        case active
        /// No activity for `idleAfter`. Poll every `idleInterval` to catch
        /// quota changes from other Macs / non-CLI Codex entry points.
        case idle
    }

    public typealias UpdateHandler = @Sendable (CodexQuotaSnapshot) -> Void
    public typealias StatusHandler = @Sendable (Status) -> Void

    private let queue = DispatchQueue(label: "org.tobywu.pelu.codex-quota", qos: .utility)
    private let clientInfo: CodexAppServerClient.ClientInfo
    private let activeInterval: TimeInterval
    private let idleInterval: TimeInterval
    private let idleAfter: TimeInterval
    private var pollTimer: DispatchSourceTimer?

    /// Backoff series from plan §13 — 1, 2, 5, 15, 30 minutes. We index into
    /// this with `consecutiveFailures - 1`, clamped to the last entry, so a
    /// hard-down peer eventually settles at 30-min retries instead of
    /// hammering every minute.
    private static let backoffSeconds: [TimeInterval] = [60, 120, 300, 900, 1800]
    private var consecutiveFailures: Int = 0

    private var client: CodexAppServerClient?
    private var _status: Status = .starting
    private var _latest: CodexQuotaSnapshot?
    private var _mode: Mode = .active
    /// When the provider last saw external activity. Drives the active→idle
    /// transition. Boot counts as activity (we want an initial active phase
    /// so the first dashboard render reflects current quota fast).
    private var lastActivityAt: Date = Date()
    /// When we last *initiated* a fetch (any path: scheduled tick, markActive,
    /// refresh). Used to throttle event-driven fetches so a busy Codex run
    /// writing jsonl every few seconds doesn't spam OpenAI with RPCs.
    private var lastFetchInitiatedAt: Date?
    private var lastUserReconnectAt: Date?
    private var isFetchInFlight = false
    /// Minimum spacing between event-driven fetches. Plan §13 suggests
    /// 2-5s for file-event debounce; 3 is a reasonable middle.
    private static let activityThrottleWindow: TimeInterval = 3

    public var onUpdate: UpdateHandler?
    public var onStatusChange: StatusHandler?

    public init(
        clientInfo: CodexAppServerClient.ClientInfo,
        activeInterval: TimeInterval = 60,
        idleInterval: TimeInterval = 1200,  // 20 min — middle of plan §13's 15–30
        idleAfter: TimeInterval = 600       // 10 min of no activity → idle
    ) {
        self.clientInfo = clientInfo
        self.activeInterval = activeInterval
        self.idleInterval = idleInterval
        self.idleAfter = idleAfter
    }

    public func latestSnapshot() -> CodexQuotaSnapshot? {
        queue.sync { _latest }
    }

    public func currentStatus() -> Status {
        queue.sync { _status }
    }

    public func currentMode() -> Mode {
        queue.sync { _mode }
    }

    /// Mark that something interesting just happened — user opened the
    /// popover, jsonl saw new activity, app came back to foreground, etc.
    /// Throttle aside, fires an immediate fetch so the user sees fresh
    /// numbers right away (the old behavior — only fetch on idle→active
    /// transitions — left a 60s gap when the user started a new Codex
    /// session in an already-active provider).
    public func markActive() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastActivityAt = Date()
            self._mode = .active

            // An app installed after Pelu launched, or a previously failed
            // server, should recover when the user returns. Keep file-event
            // bursts from spawning discovery attempts continuously.
            if self.client == nil {
                let now = Date()
                let elapsed = now.timeIntervalSince(self.lastUserReconnectAt ?? .distantPast)
                if elapsed >= 30 {
                    self.lastUserReconnectAt = now
                    self.scheduleReconnect(after: 0)
                }
                return
            }
            guard self._status == .ready else { return }

            // Skip the immediate fetch if we just fired one — jsonl writes
            // can fan out several events per second during a busy run, and
            // we don't want to RPC the upstream that fast.
            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastFetchInitiatedAt ?? .distantPast)
            if elapsed >= Self.activityThrottleWindow {
                self.scheduleNextFetch(after: 0)
            }
            // If we're inside the throttle window, the in-flight or just-
            // completed fetch will have already returned fresh-enough data
            // for this activity burst.
        }
    }

    /// Spawn the app-server, run one read, then schedule periodic reads.
    /// Idempotent — calling twice does nothing.
    public func start() {
        NSLog("Pelu Codex provider: start() called")
        queue.async { [weak self] in
            NSLog("Pelu Codex provider: start() queue.async firing, self=\(self == nil ? "nil" : "ok")")
            guard let self else { return }
            guard self.client == nil else {
                NSLog("Pelu Codex provider: start() skipped — client already exists")
                return
            }
            self.bootstrap()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pollTimer?.cancel()
            self.pollTimer = nil
            if let client = self.client {
                Task { await client.stop() }
            }
            self.client = nil
            self.isFetchInFlight = false
        }
    }

    /// Trigger an immediate read off-schedule (e.g. popover opened, jsonl
    /// activity detected, scenePhase active). Also counts as activity, so
    /// the provider stays in `.active` mode for the next 10 min window.
    public func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastActivityAt = Date()
            self._mode = .active
            self.fetchOnce()
        }
    }

    private func bootstrap() {
        guard client == nil else { return }
        guard let binary = CodexAppServerClient.locateBinary() else {
            NSLog("Pelu Codex provider: binary not found — falling back to jsonl")
            setStatus(.unavailable(reason: "Codex binary not found"))
            scheduleReconnect(after: nextBackoffDelay())
            return
        }
        NSLog("Pelu Codex provider: using binary at \(binary.path)")
        setStatus(.starting)

        let client = CodexAppServerClient(
            clientInfo: clientInfo,
            binaryURL: binary,
            notificationHandler: { [weak self] method, _ in
                // Single notification path right now: server-pushed quota
                // updates → re-read so we get the canonical snapshot back
                // into our cache and downstream observers.
                if method == "account/rateLimits/updated" {
                    self?.refresh()
                }
            }
        )
        self.client = client

        Task { [weak self] in
            guard let self else { return }
            do {
                NSLog("Pelu Codex provider: starting app-server…")
                try await client.start()
                NSLog("Pelu Codex provider: initialize OK")
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.consecutiveFailures = 0
                    self.setStatus(.ready)
                    self.fetchOnce()
                    self.startPolling()
                }
            } catch {
                NSLog("Pelu Codex provider: start failed: \(error)")
                await client.stop()
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.client = nil
                    self.setStatus(.unavailable(reason: String(describing: error)))
                    self.scheduleReconnect(after: self.nextBackoffDelay())
                }
            }
        }
    }

    /// Schedule the next single fetch. Replaces the previous repeating-timer
    /// approach so we can vary the interval per result (success → poll
    /// interval, failure → backoff). One-shot timer; reschedule from the
    /// fetch completion handler.
    ///
    /// `delay <= 1` skips jitter so `markActive()` can yank a fetch right
    /// away. Otherwise we add 0-10s of jitter so multiple Macs on the same
    /// account don't synchronize on the same minute boundary.
    private func scheduleNextFetch(after delay: TimeInterval) {
        pollTimer?.cancel()
        let jitter = delay <= 1 ? 0 : Double.random(in: 0...10)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay + jitter)
        timer.setEventHandler { [weak self] in self?.fetchOnce() }
        timer.resume()
        pollTimer = timer
    }

    private func startPolling() {
        scheduleNextFetch(after: activeInterval)
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        pollTimer?.cancel()
        let jitter = delay <= 1 ? 0 : Double.random(in: 0...10)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay + jitter)
        timer.setEventHandler { [weak self] in
            self?.pollTimer = nil
            self?.bootstrap()
        }
        timer.resume()
        pollTimer = timer
    }

    private func nextBackoffDelay() -> TimeInterval {
        consecutiveFailures += 1
        let idx = min(consecutiveFailures - 1, Self.backoffSeconds.count - 1)
        return Self.backoffSeconds[idx]
    }

    /// Picks the next cadence based on how long since the last activity.
    /// Called after each successful fetch. Failure goes through backoff
    /// instead and ignores mode.
    private func scheduleByCadence() {
        let elapsed = Date().timeIntervalSince(lastActivityAt)
        if elapsed >= idleAfter {
            _mode = .idle
            scheduleNextFetch(after: idleInterval)
        } else {
            _mode = .active
            scheduleNextFetch(after: activeInterval)
        }
    }

    private func fetchOnce() {
        guard let client else { return }
        guard !isFetchInFlight else { return }
        isFetchInFlight = true
        // Record initiation time before we await — every fetch path goes
        // through here, so the throttle in markActive() correctly accounts
        // for scheduled ticks too.
        lastFetchInitiatedAt = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                let snap = try await client.readRateLimits()
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.isFetchInFlight = false
                    self._latest = snap
                    self.consecutiveFailures = 0
                    // %% so NSLog's printf parser doesn't eat the percent
                    // sign with whatever follows. Without doubling, "8% s"
                    // becomes a "%s" directive that prints "(null)".
                    NSLog("Pelu Codex provider: read OK primary=\(snap.rateLimits.primary?.usedPercent ?? -1)%% secondary=\(snap.rateLimits.secondary?.usedPercent ?? -1)%%")
                    self.onUpdate?(snap)
                    self.scheduleByCadence()
                }
            } catch {
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.isFetchInFlight = false
                    let delay = self.nextBackoffDelay()
                    NSLog("Pelu CodexQuotaProvider read failed (#\(self.consecutiveFailures), retry in \(Int(delay))s): \(error)")
                    self.setStatus(.unavailable(reason: String(describing: error)))
                    let failedClient = self.client
                    self.client = nil
                    if let failedClient {
                        Task { await failedClient.stop() }
                    }
                    self.scheduleReconnect(after: delay)
                }
            }
        }
    }

    private func setStatus(_ next: Status) {
        guard _status != next else { return }
        _status = next
        let handler = onStatusChange
        let snapshot = next
        DispatchQueue.main.async { handler?(snapshot) }
    }
}

#endif // os(macOS)
