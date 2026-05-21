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
        return metric(from: match.payload)
    }

    func latestTokenCountFileURL() -> URL? {
        latestTokenCountMatch()?.fileURL
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
            if latest == nil || match.timestamp > latest!.timestamp {
                latest = match
            }
        }
        return latest
    }

    private static func parseCodexTimestamp(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    private func metric(from payload: [String: Any]) -> UsageMetric {
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
            weeklyResetDate: weeklyResetDate
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
    private var fileSource: DispatchSourceFileSystemObject?
    private var codexFileSource: DispatchSourceFileSystemObject?
    private var codexDirectorySource: DispatchSourceFileSystemObject?
    private var watchedCodexFilePath: String?
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

        refresh()
        startWatching()
        startPeriodicRefresh()
    }

    deinit {
        periodicTimer?.invalidate()
        fileSource?.cancel()
        codexFileSource?.cancel()
        codexDirectorySource?.cancel()
        resetTimers.values.forEach { $0.cancel() }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
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

            let codexMetric = self.codexReader.readLatestMetric()
            let latestCodexFileURL = self.codexReader.latestTokenCountFileURL()
            let codexSessionsDirectory = self.codexReader.currentSessionsDirectory()

            let snap = UsageSnapshot(
                generatedAt: Date(),
                source: .local,
                metrics: [claudeMetric, codexMetric]
            )
            DispatchQueue.main.async {
                self.snapshot = snap
                self.updateCodexFileWatcher(fileURL: latestCodexFileURL)
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

    private func updateCodexFileWatcher(fileURL: URL?) {
        guard let fileURL else { return }
        guard watchedCodexFilePath != fileURL.path else { return }

        codexFileSource?.cancel()
        codexFileSource = nil
        watchedCodexFilePath = nil

        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.rename) || flags.contains(.delete) {
                self.codexFileSource?.cancel()
                self.codexFileSource = nil
                self.watchedCodexFilePath = nil
            }
            self.refresh()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        codexFileSource = source
        watchedCodexFilePath = fileURL.path
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
            self.refresh()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        codexDirectorySource = source
        watchedCodexDirectoryPath = directoryURL.path
    }

    private func startPeriodicRefresh() {
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
}

// MARK: - App

@main
struct PeluMacApp: App {
    @State private var monitor = UsageMonitor()
    @State private var syncer = CloudKitSyncer(
        bundleVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    )

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
            PeluMacSettingsView(monitor: monitor)
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
            do {
                try await syncer.save(mac)
            } catch {
                print("Pelu CloudKit save failed: \(error)")
            }
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
                // screen. MenuBarExtra's `.window` style is an NSPanel under
                // the hood; we lock it the moment it gets a window.
                MenuBarPopoverPinner()
            )
            .task {
                // `Window` scenes on macOS don't auto-open with MenuBarExtra
                // apps, so we trigger the onboarding window from here once.
                guard !didTryOpenOnboarding, !onboardingCompleted else { return }
                didTryOpenOnboarding = true
                openWindow(id: PeluMacApp.onboardingWindowID)
            }
    }
}

/// NSViewRepresentable that locks the enclosing NSPanel so it can't be
/// dragged. Subclassed NSView used so we can override `viewDidMoveToWindow`
/// — that hook fires synchronously the moment the view enters a window,
/// which is more reliable than DispatchQueue.main.async would be.
private struct MenuBarPopoverPinner: NSViewRepresentable {
    func makeNSView(context: Context) -> PinningView { PinningView() }
    func updateNSView(_ nsView: PinningView, context: Context) {}

    final class PinningView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isMovable = false
            window.isMovableByWindowBackground = false
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
