import PeluCore
import PeluUI
import SwiftUI

// MARK: - CodexJSONLReader

/// Reads the latest token_count event from ~/.codex/sessions/YYYY/MM/DD/*.jsonl
/// and ~/.codex/archived_sessions/ to extract Codex rate limit percentages.
struct CodexJSONLReader {
    private let codexDir: URL

    init() {
        codexDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    func readLatestMetric() -> UsageMetric {
        guard let match = latestTokenCountMatch() else {
            return UsageMetric(provider: .codex, usedPercent: nil, note: "今日無 Codex 使用紀錄")
        }
        return metric(from: match.payload, measuredAt: match.timestamp)
    }

    func latestTokenCountFileURL() -> URL? {
        latestTokenCountMatch()?.fileURL
    }

    /// All jsonl files modified within `withinHours` hours — these are the
    /// sessions that could still receive appends. We watch each one so a
    /// background terminal's writes trigger refresh, not just the currently
    /// active session.
    func recentlyActiveJSONLFiles(withinHours: Double = 24) -> [URL] {
        let cutoff = Date().addingTimeInterval(-withinHours * 3600)
        return candidateJSONLFiles().filter { url in
            guard let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return false }
            return mod >= cutoff
        }
    }

    /// Sum the latest `total_token_usage` from every jsonl modified within
    /// the last `withinHours`. Each session contributes its single latest
    /// token_count event (the session's running cumulative at that point);
    /// the aggregate is the running cumulative across all active sessions,
    /// which `PeluHistoryScreen` feeds into `CodexPricing.estimateUSD` and
    /// passes through the same day-over-day delta logic as Claude's
    /// `cost.total_cost_usd`. Returns nil when no jsonl in the window
    /// has a usable token_count event.
    func summedTokenUsage(withinHours: Double = 24) -> CodexTokenUsage? {
        let cutoff = Date().addingTimeInterval(-withinHours * 3600)
        let activeFiles = candidateJSONLFiles().filter { url in
            guard let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return false }
            return mod >= cutoff
        }

        var total = CodexTokenUsage.zero
        var anyContribution = false

        for fileURL in activeFiles {
            guard let match = latestTokenCountMatch(in: fileURL),
                  let info = match.payload["info"] as? [String: Any],
                  let totals = info["total_token_usage"] as? [String: Any]
            else { continue }

            // Codex writes these as integers, but Foundation surfaces JSON
            // numbers as NSNumber — read via Int first, fall back to Double
            // for safety against any future shape changes.
            let input = (totals["input_tokens"] as? Int) ?? Int(totals["input_tokens"] as? Double ?? 0)
            let cached = (totals["cached_input_tokens"] as? Int) ?? Int(totals["cached_input_tokens"] as? Double ?? 0)
            let output = (totals["output_tokens"] as? Int) ?? Int(totals["output_tokens"] as? Double ?? 0)
            let sessionUsage = CodexTokenUsage(
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output
            )
            guard !sessionUsage.isEmpty else { continue }
            total = total.adding(sessionUsage)
            anyContribution = true
        }

        return anyContribution ? total : nil
    }

    func currentSessionsDirectory(now: Date = Date()) -> URL {
        let cal = Calendar.current
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        let d = cal.component(.day, from: now)
        return codexDir.appendingPathComponent(
            String(format: "sessions/%d/%02d/%02d", y, m, d)
        )
    }

    private struct TokenCountMatch {
        let timestamp: Date
        let fileURL: URL
        let payload: [String: Any]
    }

    private func latestTokenCountMatch() -> TokenCountMatch? {
        let jsonlFiles = candidateJSONLFiles()

        var newest: TokenCountMatch?
        for fileURL in jsonlFiles {
            guard let match = latestTokenCountMatch(in: fileURL) else { continue }
            if newest == nil || match.timestamp > newest!.timestamp {
                newest = match
            }
        }

        return newest
    }

    private func candidateJSONLFiles() -> [URL] {
        // Codex rate_limits 是 5h / 7d 滾動式 window；昨天最後一筆 event 的 rate_limits
        // 在 reset 前仍代表當前 quota。所以掃最近 8 天，找 modification date 最新的 jsonl。
        let now = Date()
        let cal = Calendar.current
        let lookbackDays = 8
        let earliest = cal.date(byAdding: .day, value: -lookbackDays, to: now) ?? now

        var jsonlFiles: [URL] = []

        // sessions/YYYY/MM/DD/*.jsonl — 列出最近幾天的目錄
        for dayOffset in 0..<lookbackDays {
            guard let date = cal.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let y = cal.component(.year, from: date)
            let m = cal.component(.month, from: date)
            let d = cal.component(.day, from: date)
            let dir = codexDir.appendingPathComponent(
                String(format: "sessions/%d/%02d/%02d", y, m, d)
            )
            if let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) {
                jsonlFiles += files.filter { $0.pathExtension == "jsonl" }
            }
        }

        // archived_sessions/*.jsonl — 只要 modification date 在 lookback window 內
        let archivedDir = codexDir.appendingPathComponent("archived_sessions")
        if let files = try? FileManager.default.contentsOfDirectory(
            at: archivedDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            let recent = files.filter { url -> Bool in
                guard url.pathExtension == "jsonl",
                      let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mod = attrs.contentModificationDate else { return false }
                return mod >= earliest
            }
            jsonlFiles += recent
        }

        return jsonlFiles
    }

    private func latestTokenCountMatch(in fileURL: URL) -> TokenCountMatch? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let fileModifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        var latest: TokenCountMatch?

        for line in content.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count"
            else { continue }
            let timestamp = (obj["timestamp"] as? String).flatMap(Self.parseCodexTimestamp) ?? fileModifiedAt
            let match = TokenCountMatch(timestamp: timestamp, fileURL: fileURL, payload: payload)
            // Use `>=` so when timestamps collide (e.g. burst of events in the
            // same millisecond, or all-fallback-to-fileMtime) the later event
            // in the file wins — JSONL order is chronological by construction.
            if let current = latest, match.timestamp < current.timestamp { continue }
            latest = match
        }
        return latest
    }

    private static func parseCodexTimestamp(_ string: String) -> Date? {
        // Codex writes ISO-8601 with fractional seconds (e.g.
        // "2026-05-21T09:01:40.976Z"). The default ISO8601DateFormatter
        // rejects the `.976` — bumping formatOptions fixes that.
        // Without this every event silently falls back to file mtime, all
        // matches in a file land on the same timestamp, and the in-file
        // ">" comparison keeps the FIRST event instead of the latest.
        if let date = Self.fractionalFormatter.date(from: string) { return date }
        return Self.plainFormatter.date(from: string)
    }

    // ISO8601DateFormatter is documented thread-safe; `nonisolated(unsafe)`
    // tells Swift 6 strict concurrency to trust that.
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plainFormatter = ISO8601DateFormatter()

    private func metric(from payload: [String: Any], measuredAt: Date) -> UsageMetric {
        let rateLimits = payload["rate_limits"] as? [String: Any]
        let primary = rateLimits?["primary"] as? [String: Any]
        let secondary = rateLimits?["secondary"] as? [String: Any]

        let rawPrimary = primary?["used_percent"] as? Double
        let resetDate = (primary?["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let rawWeekly = secondary?["used_percent"] as? Double
        let weeklyResetDate = (secondary?["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }

        // 若 reset 時間已過代表 window 已滾動但 user 沒新 event，當前實際 quota 是 0
        let now = Date()
        let primaryPercent: Double? = {
            guard let v = rawPrimary else { return nil }
            if let r = resetDate, r < now { return 0 }
            return v
        }()
        let weeklyPercent: Double? = {
            guard let v = rawWeekly else { return nil }
            if let r = weeklyResetDate, r < now { return 0 }
            return v
        }()

        return UsageMetric(
            provider: .codex,
            usedPercent: primaryPercent,
            weeklyPercent: weeklyPercent,
            resetDate: resetDate,
            weeklyResetDate: weeklyResetDate,
            dataSource: .localEstimate,
            measuredAt: measuredAt
        )
    }
}

// MARK: - UsageMonitor

/// Reads ~/.claude/usag-status.json and ~/.codex/sessions JSONL files,
/// watches Claude file for changes via DispatchSource, and uploads to CloudKit.
@Observable
final class UsageMonitor: @unchecked Sendable {
    private(set) var snapshot: UsageSnapshot = .demo()

    var showClaude: Bool {
        didSet { UserDefaults.standard.set(showClaude, forKey: "pelu.menubar.showClaude") }
    }
    var showCodex: Bool {
        didSet { UserDefaults.standard.set(showCodex, forKey: "pelu.menubar.showCodex") }
    }

    private let claudeFilePath: URL
    private let claudeParser = ClaudeCodeParser()
    private let codexReader = CodexJSONLReader()
    /// Serial queue for refresh work. The previous `.global(qos: .utility)`
    /// was concurrent — when init's first refresh raced with the provider's
    /// onUpdate-triggered second refresh, the slower (jsonl) task could
    /// dispatch its main-thread write *after* the faster (RPC) one, leaving
    /// the UI on the localEstimate metric and surfacing the "估算" badge.
    private let refreshQueue = DispatchQueue(label: "org.tobywu.pelu.refresh", qos: .utility)
    private let codexQuotaProvider = CodexQuotaProvider(
        clientInfo: .init(
            name: "Pelu",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        )
    )
    private var fileSource: DispatchSourceFileSystemObject?
    /// Per-file FSEvent watchers keyed by absolute path. We watch every
    /// recently-active Codex jsonl, not just the latest one, so a write in
    /// a background terminal triggers refresh immediately instead of waiting
    /// for the 60s timer.
    private var codexFileSources: [String: DispatchSourceFileSystemObject] = [:]
    private var codexDirectorySource: DispatchSourceFileSystemObject?
    private var watchedCodexDirectoryPath: String?
    private var periodicTimer: Timer?
    // Keyed by the resetDate's `timeIntervalSince1970` rounded to nearest sec
    // so we can dedupe identical fire-at times across providers.
    private var resetTimers: [TimeInterval: DispatchSourceTimer] = [:]

    init() {
        let ud = UserDefaults.standard
        showClaude = ud.object(forKey: "pelu.menubar.showClaude") as? Bool ?? true
        showCodex  = ud.object(forKey: "pelu.menubar.showCodex")  as? Bool ?? false

        claudeFilePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/usag-status.json")

        // NOTE: hook installation moved to onboarding (MacOnboardingView).
        // The previous "silent install on first launch" silently overwrote
        // any pre-existing statusLine command, which violates user trust.
        // The Settings window's "重新安裝 Claude Code hook" button covers
        // re-install scenarios; legitimate first-run install runs from the
        // onboarding step where the user explicitly consents.

        // Codex app-server pushes server-initiated quota updates and gives us
        // canonical numbers that survive across machines / non-CLI Codex
        // entry points. Wire it before the first refresh so an early read
        // can hit it. The jsonl reader stays as a fallback when the binary
        // isn't installed or the daemon hasn't initialized yet.
        codexQuotaProvider.onUpdate = { [weak self] _ in
            self?.refresh()
        }
        codexQuotaProvider.start()

        refresh()
        startWatching()
        startPeriodicRefresh()
    }

    deinit {
        periodicTimer?.invalidate()
        fileSource?.cancel()
        codexFileSources.values.forEach { $0.cancel() }
        codexDirectorySource?.cancel()
        resetTimers.values.forEach { $0.cancel() }
        codexQuotaProvider.stop()
    }

    /// Forward "user / system seems to care about Codex right now" signals to
    /// the quota provider so it doesn't fall back to idle cadence. Called
    /// from jsonl FSEvents handlers and from popover-becomes-key.
    func markCodexActive() {
        codexQuotaProvider.markActive()
    }

    func refresh() {
        refreshQueue.async { [weak self] in
            guard let self else { return }

            let claudeMetric: UsageMetric
            if let data = try? Data(contentsOf: self.claudeFilePath),
               let parsed = try? self.claudeParser.parse(data: data) {
                claudeMetric = parsed
            } else {
                claudeMetric = UsageMetric(
                    provider: .claudeCode,
                    usedPercent: nil,
                    note: "Claude status JSON 尚未可讀"
                )
            }

            // Prefer app-server quota while it is fresh. If RPC has been
            // stale for five minutes and JSONL has a newer observation, use
            // that estimate until the provider reconnects.
            let codexMetric: UsageMetric
            if let snapshot = self.codexQuotaProvider.latestSnapshot() {
                let official = snapshot.asUsageMetric()
                let officialIsStale = Date().timeIntervalSince(snapshot.fetchedAt) >= 300
                if officialIsStale {
                    let localEstimate = self.codexReader.readLatestMetric()
                    if let localMeasuredAt = localEstimate.measuredAt,
                       localMeasuredAt > snapshot.fetchedAt {
                        codexMetric = localEstimate
                    } else {
                        codexMetric = official
                    }
                } else {
                    codexMetric = official
                }
            } else {
                codexMetric = self.codexReader.readLatestMetric()
            }
            let activeCodexFiles = self.codexReader.recentlyActiveJSONLFiles()
            let codexSessionsDirectory = self.codexReader.currentSessionsDirectory()

            // Codex RPC doesn't expose raw token counts, so we always pull
            // them from JSONL (sum of latest `total_token_usage` across all
            // sessions active in the last 24h). This drives the history
            // screen's USD estimate; percentages still come from whichever
            // source `codexMetric` was just resolved from.
            let codexTokens = self.codexReader.summedTokenUsage()
            let codexMetricWithTokens = codexMetric.attachingTokenUsage(codexTokens)

            let snap = UsageSnapshot(
                generatedAt: Date(),
                source: .local,
                metrics: [claudeMetric, codexMetricWithTokens]
            )
            DispatchQueue.main.async {
                self.snapshot = snap
                self.updateCodexFileWatchers(fileURLs: activeCodexFiles)
                self.updateCodexDirectoryWatcher(directoryURL: codexSessionsDirectory)
                self.rescheduleResetTimers(for: snap)
            }
        }
    }

    /// Schedule a one-shot DispatchSourceTimer to fire at each future resetDate
    /// in the snapshot. When it fires we call `refresh()` — which re-runs the
    /// parsers, sees `resetDate < now`, and writes `usedPercent = 0` to cloud.
    /// Result: the dashboard zeroes out at the exact reset moment without
    /// waiting for the 60s polling timer (or the user to nudge the CLI).
    private func rescheduleResetTimers(for snapshot: UsageSnapshot) {
        let now = Date()
        let allDates = snapshot.metrics.flatMap { metric in
            [metric.resetDate, metric.weeklyResetDate]
        }
        let futureDates: Set<TimeInterval> = Set(
            allDates.compactMap { date in
                guard let date, date > now else { return nil }
                return floor(date.timeIntervalSince1970)
            }
        )

        // Cancel timers no longer in the snapshot's reset set
        for (key, timer) in resetTimers where !futureDates.contains(key) {
            timer.cancel()
            resetTimers.removeValue(forKey: key)
        }

        // Schedule timers for new reset times
        for key in futureDates where resetTimers[key] == nil {
            let fireDate = Date(timeIntervalSince1970: key)
            // Tiny buffer so the timer fires *after* the actual reset second —
            // otherwise our `resetDate < now` check might still be false.
            let delay = max(1, fireDate.timeIntervalSinceNow + 0.5)

            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + delay)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.resetTimers.removeValue(forKey: key)
                self.refresh()
            }
            timer.resume()
            resetTimers[key] = timer
        }
    }

    private func startWatching() {
        let fd = open(claudeFilePath.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Claude Code's statusLine hook writes atomically (rename / unlink + create),
            // which invalidates our file descriptor. On rename/delete we must reopen.
            let flags = source.data
            if flags.contains(.rename) || flags.contains(.delete) {
                self.fileSource?.cancel()
                self.fileSource = nil
                self.refresh()
                // Reopen after a short delay so the replacement file is in place.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.startWatching()
                }
            } else {
                self.refresh()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    /// Reconcile our per-file FSEvent watchers against the set of currently
    /// active Codex session files. Adds new ones, cancels stale ones, leaves
    /// existing ones untouched. Multiple terminals writing in parallel each
    /// trigger refresh independently.
    private func updateCodexFileWatchers(fileURLs: [URL]) {
        let desired = Set(fileURLs.map(\.path))
        let current = Set(codexFileSources.keys)

        for stalePath in current.subtracting(desired) {
            codexFileSources[stalePath]?.cancel()
            codexFileSources.removeValue(forKey: stalePath)
        }

        for newPath in desired.subtracting(current) {
            let fd = open(newPath, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let flags = source.data
                if flags.contains(.rename) || flags.contains(.delete) {
                    self.codexFileSources[newPath]?.cancel()
                    self.codexFileSources.removeValue(forKey: newPath)
                }
                // jsonl write = real Codex activity on this machine. Bump
                // the provider to active so its next read is quick (60s)
                // instead of waiting for the idle cadence (20 min).
                self.codexQuotaProvider.markActive()
                self.refresh()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            codexFileSources[newPath] = source
        }
    }

    private func updateCodexDirectoryWatcher(directoryURL: URL) {
        guard watchedCodexDirectoryPath != directoryURL.path else { return }

        codexDirectorySource?.cancel()
        codexDirectorySource = nil
        watchedCodexDirectoryPath = nil

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.rename) || flags.contains(.delete) {
                self.codexDirectorySource?.cancel()
                self.codexDirectorySource = nil
                self.watchedCodexDirectoryPath = nil
            }
            // New jsonl appearing in today's sessions/ dir = fresh Codex
            // session just started. Treat as activity.
            self.codexQuotaProvider.markActive()
            self.refresh()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        codexDirectorySource = source
        watchedCodexDirectoryPath = directoryURL.path
    }

    private func startPeriodicRefresh() {
        // Register on `.common` modes so the timer keeps firing while the
        // MenuBarExtra popover is open (popover puts the run loop into
        // event-tracking mode; `.default`-only timers skip those ticks and
        // the dashboard appears to freeze while the user looks at it).
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer
    }
}

/// Serializes CloudKit writes and collapses bursts of local refresh events to
/// the newest pending snapshot. JSONL sessions can append many times while one
/// network save is in flight; saving every intermediate value causes record
/// change-tag conflicts without improving what the phone ultimately displays.
private actor CloudSnapshotUploader {
    private let syncer: CloudKitSyncer
    private var pending: MacSnapshot?
    private var isUploading = false

    init(bundleVersion: String) {
        syncer = CloudKitSyncer(bundleVersion: bundleVersion)
    }

    func submit(_ snapshot: MacSnapshot) async {
        pending = snapshot
        guard !isUploading else { return }
        isUploading = true
        defer { isUploading = false }

        while let next = pending {
            pending = nil
            do {
                try await syncer.save(next)
            } catch {
                print("Pelu CloudKit save failed: \(error)")
            }
        }
    }
}

// MARK: - App

@main
struct PeluMacApp: App {
    @State private var monitor = UsageMonitor()
    @State private var uploader = CloudSnapshotUploader(
        bundleVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    )
    @StateObject private var updater = PeluUpdater()

    var body: some Scene {
        MenuBarExtra {
            MacMenuBarContent(monitor: monitor) {
                MacBottomBar(monitor: monitor)
            }
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
        .onChange(of: monitor.snapshot) { _, newSnapshot in
            guard newSnapshot.source != .demo else { return }
            saveToAppGroup(newSnapshot)
            uploadSnapshotToCloud(newSnapshot)
        }

        Window("歡迎使用 Pelu", id: PeluMacApp.onboardingWindowID) {
            MacOnboardingView()
        }
        .defaultSize(width: 520, height: 460)
        .windowResizability(.contentSize)

        Window("Pelu 設定", id: PeluMacApp.settingsWindowID) {
            PeluMacSettingsView(monitor: monitor, updater: updater)
                .background(FloatingWindowConfigurator())
        }
        .defaultSize(width: 520, height: 560)
        .windowResizability(.contentSize)
    }

    static let onboardingWindowID = "pelu-onboarding"
    static let settingsWindowID   = "pelu-settings"

    private var menuBarLabel: some View {
        HStack(spacing: 4) {
            // The PNG behind "PeluSimpleLogo" is 512×512 marked as 1x, so SwiftUI
            // treats its intrinsic point size as 512. MenuBarExtra ignores .frame()
            // for images; we have to give it an NSImage with `.size` pre-set.
            Image(nsImage: PeluMacApp.menuBarIcon)
            let text = menuBarText
            if !text.isEmpty {
                Text(text)
            }
        }
    }

    private static let menuBarIcon: NSImage = {
        guard let original = NSImage(named: "PeluSimpleLogo")?.copy() as? NSImage else {
            return NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Pelu")
                ?? NSImage()
        }
        original.size = NSSize(width: 16, height: 16)
        return original
    }()

    private var menuBarText: String {
        let claude = monitor.snapshot.metric(for: .claudeCode)?.usedPercent
        let codex  = monitor.snapshot.metric(for: .codex)?.usedPercent
        var parts: [String] = []
        if monitor.showClaude, let c = claude { parts.append("C \(Int(c.rounded()))%") }
        if monitor.showCodex,  let x = codex  { parts.append("X \(Int(x.rounded()))%") }
        return parts.joined(separator: " · ")
    }

    private func saveToAppGroup(_ snapshot: UsageSnapshot) {
        guard let store = AppGroupStore() else { return }
        let aggregate = AggregateSnapshot(macs: [
            MacSnapshot(macId: MacIdentity.macId(), label: MacIdentity.label(), snapshot: snapshot)
        ])
        do {
            try store.save(aggregate)
        } catch {
            print("Pelu AppGroupStore save failed: \(error)")
        }
    }

    private func uploadSnapshotToCloud(_ snapshot: UsageSnapshot) {
        let mac = MacSnapshot(
            macId: MacIdentity.macId(),
            label: MacIdentity.label(),
            snapshot: snapshot
        )
        Task {
            await uploader.submit(mac)
        }
    }
}

/// Menu bar popover wrapper. Pulled out of `PeluMacApp.body` so we can use
/// `@Environment(\.openWindow)` and auto-open the onboarding window on first
/// launch (the App scene itself isn't a View and can't host environment values).
private struct MacMenuBarContent<BottomBar: View>: View {
    let monitor: UsageMonitor
    let bottomBar: () -> BottomBar

    @Environment(\.openWindow) private var openWindow
    @AppStorage("pelu.onboardingCompleted") private var onboardingCompleted = false
    @State private var didTryOpenOnboarding = false

    var body: some View {
        PeluDashboardView(snapshot: monitor.snapshot)
            .frame(width: 360, height: 520)
            .overlay(alignment: .bottomTrailing) {
                bottomBar()
                    .padding(10)
            }
            .background(
                // Pin the popover NSPanel so the user can't drag it around the
                // screen, and bump the Codex quota provider out of idle every
                // time the user opens us. MenuBarExtra's `.window` style is
                // an NSPanel; both behaviors hook off its NSWindow lifecycle.
                MenuBarPopoverPinner(onWindowBecomeKey: {
                    monitor.markCodexActive()
                })
            )
            .task {
                // Run the location check once per launch. Must happen before
                // onboarding so a translocated app gets relocated first — TCC
                // won't remember any grants the user makes while translocated.
                AppLocationHelper.warnIfNeeded()

                // `Window` scenes on macOS don't auto-open with MenuBarExtra
                // apps, so we trigger the onboarding window from here once.
                guard !didTryOpenOnboarding, !onboardingCompleted else { return }
                didTryOpenOnboarding = true
                openWindow(id: PeluMacApp.onboardingWindowID)
            }
    }
}

/// NSViewRepresentable that locks the enclosing NSPanel so it can't be
/// dragged, and fires `onWindowBecomeKey` each time the popover opens.
///
/// The "becomes key" hook beats SwiftUI's `.onAppear` here — MenuBarExtra's
/// `.window` style caches its hosted view, so onAppear only fires on the
/// first open. NSWindow.didBecomeKeyNotification fires on every open.
private struct MenuBarPopoverPinner: NSViewRepresentable {
    var onWindowBecomeKey: () -> Void = {}

    func makeNSView(context: Context) -> PinningView {
        let v = PinningView()
        v.onWindowBecomeKey = onWindowBecomeKey
        return v
    }
    func updateNSView(_ nsView: PinningView, context: Context) {
        nsView.onWindowBecomeKey = onWindowBecomeKey
    }

    final class PinningView: NSView {
        var onWindowBecomeKey: () -> Void = {}
        private var keyObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Tear down any observer from the previous window (view can be
            // detached then re-attached during SwiftUI updates).
            if let token = keyObserver {
                NotificationCenter.default.removeObserver(token)
                keyObserver = nil
            }
            guard let window else { return }
            window.isMovable = false
            window.isMovableByWindowBackground = false

            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onWindowBecomeKey()
                }
            }
        }

        // viewDidMoveToWindow(nil) handles teardown when the view leaves a
        // window; that's the normal path for an NSView in a MenuBarExtra
        // popover. A nonisolated deinit can't touch NSObjectProtocol under
        // Swift 6 strict concurrency, and the worst case (view dropped
        // without leaving a window first) is a stale observer block that
        // hits a `[weak self]` nil and no-ops.
    }
}

/// Pins the host NSWindow to `.floating` level so the Settings window stays
/// above every other app's windows. Same trick as `MenuBarPopoverPinner` —
/// `viewDidMoveToWindow` is the synchronous moment we get a real window ref.
private struct FloatingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> FloatingHostView { FloatingHostView() }
    func updateNSView(_ nsView: FloatingHostView, context: Context) {}

    final class FloatingHostView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.level = .floating
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
    }
}

/// Tiny floating settings button overlaid on the popover's bottom-right
/// corner. All preferences (including manual refresh) live in the Settings
/// window now, so this is just the entry point.
private struct MacBottomBar: View {
    let monitor: UsageMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: PeluMacApp.settingsWindowID)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help("設定")
    }
}
