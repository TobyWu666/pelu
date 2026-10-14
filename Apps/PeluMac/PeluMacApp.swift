import PeluCore
import PeluUI
import SwiftUI

// MARK: - UsageMonitor

/// Reads ~/.claude/usag-status.json and ~/.codex/sessions JSONL files,
/// watches Claude file for changes via DispatchSource, and uploads to CloudKit.
@Observable
final class UsageMonitor: @unchecked Sendable {
    private(set) var snapshot: UsageSnapshot = .demo()
    /// Main-thread mirror of `recordedHistory` for the analysis window.
    private(set) var history = MacUsageHistory()
    private(set) var historyError: String?

    var showClaude: Bool {
        didSet { UserDefaults.standard.set(showClaude, forKey: "pelu.menubar.showClaude") }
    }
    var showCodex: Bool {
        didSet { UserDefaults.standard.set(showCodex, forKey: "pelu.menubar.showCodex") }
    }
    var showCursor: Bool {
        didSet { UserDefaults.standard.set(showCursor, forKey: "pelu.menubar.showCursor") }
    }
    var showGrokBot: Bool {
        didSet { UserDefaults.standard.set(showGrokBot, forKey: "pelu.menubar.showGrokBot") }
    }
    /// "text" (C 37%) or "rings" (`MenuBarRings`).
    var menuBarStyle: String {
        didSet { UserDefaults.standard.set(menuBarStyle, forKey: "pelu.menubar.style") }
    }

    private let claudeFilePath: URL
    private let claudeParser = ClaudeCodeParser()
    private let claudeDesktopParser = ClaudeDesktopUsageParser()
    /// Primary Claude source; the statusLine hook only fires in terminal sessions.
    private let claudeUsageClient = ClaudeUsageAPIClient(
        clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    )
    private let cursorClient = CursorUsageClient(
        clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    )
    private let grokBotClient = GrokBotUsageClient(
        clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    )
    private let codexReader = CodexJSONLReader()
    /// Keep refreshes serial and coalesce bursts of file/provider updates.
    /// At most one pass runs and one followup waits; starts are at least 1s apart.
    private let refreshScheduler = CoalescingRefreshScheduler(
        queue: DispatchQueue(label: "org.tobywu.pelu.refresh", qos: .utility, autoreleaseFrequency: .workItem)
    )
    private let historyStore = MacUsageHistoryStore()
    /// Owned by the serial refresh queue. Loaded once so a refresh doesn't re-read the
    /// whole history file; an unreadable file starts a fresh history.
    private var recordedHistory: MacUsageHistory?
    private let codexQuotaProvider = CodexQuotaProvider(
        clientInfo: .init(
            name: "Pelu",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        )
    )
    private var fileSource: DispatchSourceFileSystemObject?
    /// Watch at most 128 recently modified Codex files for immediate updates.
    /// The 60s timer still reads totals from all active sessions.
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
        showCursor = ud.object(forKey: "pelu.menubar.showCursor") as? Bool ?? false
        showGrokBot = ud.object(forKey: "pelu.menubar.showGrokBot") as? Bool ?? false
        // A panel list saved before Grok Bot existed can't have opted out of it.
        if !ud.bool(forKey: "pelu.mac.panelProviders.grokBotAdded") {
            if let saved = ud.string(forKey: "pelu.mac.panelProviders") {
                ud.set(MacPanelProviders(rawValue: saved).setting(.grokBot, visible: true).rawValue, forKey: "pelu.mac.panelProviders")
            }
            ud.set(true, forKey: "pelu.mac.panelProviders.grokBotAdded")
        }
        menuBarStyle = ud.string(forKey: "pelu.menubar.style") ?? "text"

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
        claudeUsageClient.onUpdate = { [weak self] in
            self?.refresh()
        }
        cursorClient.onUpdate = { [weak self] in
            self?.refresh()
        }
        grokBotClient.onUpdate = { [weak self] in
            self?.refresh()
        }

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
        refreshScheduler.request { [weak self] in self?.performRefresh() }
    }

    private func performRefresh() {
        self.claudeUsageClient.refreshIfDue()
        let hookMetric: UsageMetric
        let claudeModifiedAt = try? self.claudeFilePath.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let data = try? Data(contentsOf: self.claudeFilePath),
           let parsed = try? self.claudeParser.parse(data: data, fileModifiedAt: claudeModifiedAt) {
            hookMetric = parsed
        } else {
            hookMetric = UsageMetric(
                provider: .claudeCode,
                usedPercent: nil,
                note: "Claude status JSON 尚未可讀"
            )
        }
        var claudeMetric = ClaudeUsageAPIParser.merge(
            api: self.claudeUsageClient.latestMetric(),
            hook: hookMetric,
            desktop: self.claudeDesktopParser.read()
        )
        if self.claudeUsageClient.credentialState == .expired,
           claudeMetric.measuredAt.map({ Date().timeIntervalSince($0) >= UsageMetric.staleAfter }) ?? true {
            claudeMetric = claudeMetric.withNote("Claude Code 登入已過期，在終端機執行一次 claude 即可更新")
        }

        // Prefer app-server quota while it is fresh. If RPC has been
        // stale for five minutes and JSONL has a newer observation, use
        // that estimate until the provider reconnects.
        let codexLocalSnapshot = self.codexReader.readSnapshot()
        let codexMetric: UsageMetric
        if let snapshot = self.codexQuotaProvider.latestSnapshot() {
            let official = snapshot.asUsageMetric()
            let officialIsStale = Date().timeIntervalSince(snapshot.fetchedAt) >= 300
            if officialIsStale {
                let localEstimate = codexLocalSnapshot.metric
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
            codexMetric = codexLocalSnapshot.metric
        }
        let watchedCodexFiles = codexLocalSnapshot.watchedFileURLs
        let codexSessionsDirectory = self.codexReader.currentSessionsDirectory()

        // Codex RPC doesn't expose raw token counts, so we always pull
        // them from JSONL (sum of latest `total_token_usage` across all
        // sessions active in the last 24h). This drives the history
        // screen's USD estimate; percentages still come from whichever
        // source `codexMetric` was just resolved from.
        let codexTokens = codexLocalSnapshot.tokenUsage
        let codexMetricWithTokens = codexMetric.attachingTokenUsage(codexTokens)

        var metrics = [claudeMetric, codexMetricWithTokens]
        if self.cursorClient.isAvailable {
            self.cursorClient.refreshIfDue()
            metrics.append(self.cursorClient.currentMetric())
        }
        if self.grokBotClient.isAvailable {
            self.grokBotClient.refreshIfDue()
            if let grokBot = self.grokBotClient.currentMetric() { metrics.append(grokBot) }
        }
        let snap = UsageSnapshot(
            generatedAt: Date(),
            source: .local,
            metrics: metrics
        )
        let isFirstLoad = self.recordedHistory == nil
        var history = self.recordedHistory ?? (try? self.historyStore.load()) ?? MacUsageHistory()
        var historyError: String?
        let historyChanged = history.record(snap)
        if historyChanged {
            do {
                try self.historyStore.save(history)
            } catch {
                historyError = "歷史資料無法寫入，請確認本機儲存空間與權限。"
            }
        }
        self.recordedHistory = history
        let updatedHistory = historyChanged || isFirstLoad ? history : nil
        let updatedHistoryError = historyError
        DispatchQueue.main.async {
            if let updatedHistory { self.history = updatedHistory }
            // Keep a save error visible until a later save succeeds.
            if historyChanged { self.historyError = updatedHistoryError }
            self.snapshot = snap
            self.updateCodexFileWatchers(fileURLs: watchedCodexFiles)
            self.updateCodexDirectoryWatcher(directoryURL: codexSessionsDirectory)
            self.rescheduleResetTimers(for: snap)
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
            guard let flags = self.fileSource?.data else { return }
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
                guard let flags = self.codexFileSources[newPath]?.data else { return }
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
            guard self.watchedCodexDirectoryPath == directoryURL.path,
                  let flags = self.codexDirectorySource?.data else { return }
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

        Window("Pelu 用量分析", id: "pelu-analysis") {
            PeluMacAnalysisView(snapshot: monitor.snapshot, history: monitor.history, historyError: monitor.historyError)
                .background(FloatingWindowConfigurator())
        }
        .defaultSize(width: 880, height: 700)

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

    @ViewBuilder
    private var menuBarLabel: some View {
        let rings = menuBarRingItems
        let text = menuBarText
        if monitor.menuBarStyle == "rings", !rings.isEmpty {
            // One composed image: MenuBarExtra flattens its label, and a
            // single NSImage keeps the rings evenly spaced.
            Image(nsImage: MenuBarRings.image(items: rings))
        } else if !text.isEmpty {
            Text(text)
        } else {
            // Without the logo an empty label would leave nothing to click.
            // The PNG behind "PeluSimpleLogo" is 512×512 marked as 1x, so SwiftUI
            // treats its intrinsic point size as 512. MenuBarExtra ignores .frame()
            // for images; we have to give it an NSImage with `.size` pre-set.
            Image(nsImage: PeluMacApp.menuBarIcon)
        }
    }

    private var menuBarProviders: [ProviderKind] {
        [(ProviderKind.claudeCode, monitor.showClaude), (.codex, monitor.showCodex), (.cursor, monitor.showCursor), (.grokBot, monitor.showGrokBot)]
            .filter(\.1).map(\.0)
    }

    private var menuBarRingItems: [MenuBarRings.Item] {
        let now = Date()
        return menuBarProviders.compactMap { provider in
            monitor.snapshot.metric(for: provider).map { MenuBarRings.Item(metric: $0.effective(at: now), now: now) }
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
        menuBarProviders.compactMap { provider in
            monitor.snapshot.metric(for: provider)?.usedPercent.map { "\(provider.menuBarLetter) \(Int($0.rounded()))%" }
        }
        .joined(separator: " · ")
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
        // iOS 1.1 picks the newest Codex / Cursor / Grok Bot reading across Macs, where a
        // placeholder would beat another Mac's real one; only measured readings leave.
        let uploaded = UsageSnapshot(
            id: snapshot.id,
            generatedAt: snapshot.generatedAt,
            source: snapshot.source,
            metrics: snapshot.metrics.filter { $0.provider == .claudeCode || $0.measuredAt != nil }
        )
        let mac = MacSnapshot(
            macId: MacIdentity.macId(),
            label: MacIdentity.label(),
            snapshot: uploaded
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
        PeluMacDashboardView(snapshot: monitor.snapshot, refreshAction: { monitor.refresh() }, analysisAction: { openFrontWindow(id: "pelu-analysis") })
            .frame(width: 392)
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
                openFrontWindow(id: PeluMacApp.onboardingWindowID)
            }
    }

    private func openFrontWindow(id: String) {
        openWindow(id: id)
        // LSUIElement agent: a new window won't take keyboard focus by itself.
        NSApp.activate()
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
            window.isOpaque = false
            window.backgroundColor = .clear
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
            NSApp.activate()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pelu 設定")
        .help("設定")
    }
}
