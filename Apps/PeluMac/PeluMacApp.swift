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
        guard let payload = latestTokenCountPayload() else {
            return UsageMetric(provider: .codex, usedPercent: nil, note: "今日無 Codex 使用紀錄")
        }
        return metric(from: payload)
    }

    private func latestTokenCountPayload() -> [String: Any]? {
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

        // Sort newest-first, search for the last token_count event
        jsonlFiles.sort {
            let aDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }

        for fileURL in jsonlFiles {
            if let payload = lastTokenCountPayload(in: fileURL) {
                return payload
            }
        }

        return nil
    }

    private func lastTokenCountPayload(in fileURL: URL) -> [String: Any]? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        var last: [String: Any]? = nil

        for line in content.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count"
            else { continue }
            last = payload
        }
        return last
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
/// watches Claude file for changes via DispatchSource, and uploads to Cloudflare.
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
    private var periodicTimer: Timer?

    init() {
        let ud = UserDefaults.standard
        showClaude = ud.object(forKey: "pelu.menubar.showClaude") as? Bool ?? true
        showCodex  = ud.object(forKey: "pelu.menubar.showCodex")  as? Bool ?? false

        claudeFilePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/usag-status.json")

        // Install Claude Code's statusLine hook on first launch so users don't
        // have to set it up manually. Idempotent + non-blocking.
        ClaudeHookInstaller.installIfNeeded()

        refresh()
        startWatching()
        startPeriodicRefresh()
    }

    deinit {
        periodicTimer?.invalidate()
        fileSource?.cancel()
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            guard let data = try? Data(contentsOf: self.claudeFilePath),
                  let claudeMetric = try? self.claudeParser.parse(data: data) else { return }

            let codexMetric = self.codexReader.readLatestMetric()

            let snap = UsageSnapshot(
                generatedAt: Date(),
                source: .local,
                metrics: [claudeMetric, codexMetric]
            )
            DispatchQueue.main.async { self.snapshot = snap }
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

    private func startPeriodicRefresh() {
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
}

// MARK: - Pairing

@MainActor
@Observable
final class PairingCoordinator {
    var code: String?
    var expiresAt: Date?
    var isWorking = false
    var lastError: String?

    private let keychain = KeychainSecretStore(service: PeluMacConfig.keychainService)

    /// Resolve the admin secret: Keychain first, otherwise bootstrap from
    /// PeluMacConfig and persist. Migrating to Keychain on first run removes the
    /// runtime dependency on the gitignored Swift constant.
    func resolveAdminSecret() -> String {
        if let stored = try? keychain.get(account: KeychainSecretStore.Account.adminSecret),
           !stored.isEmpty {
            return stored
        }
        try? keychain.set(PeluMacConfig.bootstrapSecret, account: KeychainSecretStore.Account.adminSecret)
        return PeluMacConfig.bootstrapSecret
    }

    func startPairing() {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        let secret = resolveAdminSecret()

        Task {
            defer { isWorking = false }
            do {
                var request = URLRequest(url: PeluMacConfig.pairCreateEndpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
                request.httpBody = "{}".data(using: .utf8)

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    lastError = "配對 server 回傳錯誤"
                    return
                }
                struct PairResponse: Decodable { let code: String; let expiresAt: Double }
                let decoded = try JSONDecoder().decode(PairResponse.self, from: data)
                code = decoded.code
                expiresAt = Date(timeIntervalSince1970: decoded.expiresAt / 1000)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func clear() {
        code = nil
        expiresAt = nil
        lastError = nil
    }
}

// MARK: - App

@main
struct PeluMacApp: App {
    @State private var monitor = UsageMonitor()
    @State private var pairing = PairingCoordinator()
    @State private var pairingSheetVisible = false

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                PeluDashboardView(snapshot: monitor.snapshot)
                    .frame(width: 360, height: 520)

                bottomBar
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
            }
            .sheet(isPresented: $pairingSheetVisible) {
                PairingSheet(pairing: pairing)
            }
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
        .onChange(of: monitor.snapshot) { _, newSnapshot in
            guard newSnapshot.source != .demo else { return }
            saveToAppGroup(newSnapshot)
            // Always upload so iPhone sees a fresh "last updated" timestamp every minute.
            // The Worker still gates APNs pushes by metric-diff (dispatchPushes), so quota
            // is only spent on real changes — but `latest` in KV stays current.
            uploadSnapshotToCloud(newSnapshot)
        }
    }

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

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Text("Menu bar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle("Claude %", isOn: $monitor.showClaude)
                .toggleStyle(.checkbox)
                .font(.callout)

            Toggle("Codex %", isOn: $monitor.showCodex)
                .toggleStyle(.checkbox)
                .font(.callout)

            Spacer()

            Button {
                pairing.clear()
                pairing.startPairing()
                pairingSheetVisible = true
            } label: {
                Image(systemName: "iphone.gen3")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .help("配對新的 iPhone")

            Text(UpdatedAtFormatter.string(from: monitor.snapshot.generatedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .help("立即刷新（每分鐘自動更新）")
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        let secret = pairing.resolveAdminSecret()
        let macId = MacIdentity.macId()
        let label = MacIdentity.label()
        let client = CloudUsageClient(
            endpoint: PeluMacConfig.usageEndpoint,
            sharedSecret: secret
        )
        Task {
            do {
                try await client.upload(macId: macId, label: label, snapshot: snapshot)
            } catch {
                print("Pelu cloud upload failed: \(error)")
            }
        }
    }
}

// MARK: - Pairing Sheet

private struct PairingSheet: View {
    let pairing: PairingCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("配對新的 iPhone")
                .font(.title3.weight(.semibold))

            if pairing.isWorking {
                ProgressView().controlSize(.regular)
            } else if let code = pairing.code {
                Text(formatted(code))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .tracking(6)

                if let expiresAt = pairing.expiresAt {
                    Text("有效到 \(expiresAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("在 iPhone Pelu 開啟「配對」並輸入這 6 位數字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let lastError = pairing.lastError {
                Text(lastError).foregroundStyle(.red).font(.callout)
                Button("重試") { pairing.startPairing() }
            }

            Button("關閉") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(28)
        .frame(width: 320)
    }

    private func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 3)
        return code[code.startIndex..<mid] + " " + code[mid...]
    }
}
