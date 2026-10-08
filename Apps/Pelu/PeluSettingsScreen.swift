import PeluCore
import PeluUI
import SwiftUI
import UserNotifications

struct PeluSettingsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("pelu.liveActivityEnabled") private var liveActivityEnabled = false
    @AppStorage("pelu.notify.lowQuota") private var lowQuotaEnabled = false
    @AppStorage("pelu.notify.reset") private var resetEnabled = false
    @AppStorage("pelu.notify.weeklyReset") private var weeklyResetEnabled = false

    @StateObject private var notifications = NotificationManager.shared
    @State private var permissionDeniedAlert = false
    @State private var iCloudInfo: CloudKitAccountChecker.AccountInfo = .init(
        status: .unknown(underlying: "checking"),
        userRecordName: nil
    )
    @State private var pendingLinkAlert = false
    @State private var devices: [MacSnapshot] = []
    @State private var isLoadingDevices = true
    @State private var deviceErrorMessage: String?
    @State private var deletingMacIds: Set<String> = []

    private static let syncer = CloudKitSyncer(
        bundleVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    )

    private static let privacyPolicyURL: URL? = URL(string: "https://pelu.wutoby.com/privacy.html")
    private static let supportCenterURL: URL? = URL(string: "https://pelu.wutoby.com/support.html")
    private static let tutorialCenterURL: URL? = URL(string: "https://pelu.wutoby.com/tutorial.html")

    var body: some View {
        NavigationStack {
            Form {
                brandSection
                iCloudSection
                devicesSection
                notificationsSection
                liveActivitySection
                resourcesSection
                aboutSection
            }
            .navigationTitle("設定")
            .listSectionSpacing(22)
            .contentMargins(.top, 8, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(PeluTheme.background(for: colorScheme))
            .task {
                await notifications.refreshAuthorizationStatus()
                iCloudInfo = await CloudKitAccountChecker().info()
                await loadDevices()
            }
            .onReceive(NotificationCenter.default.publisher(for: .peluUsageDidUpdate)) { _ in
                // Dashboard 拉到新資料時，順便用本地 aggregate 把列表刷一下，
                // 不用再多打一次 CloudKit。
                loadDevicesFromLocal()
            }
            .alert("通知權限被拒絕", isPresented: $permissionDeniedAlert) {
                Button("前往設定") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("請至「設定 → Pelu → 通知」開啟通知。")
            }
            .alert("尚未開放", isPresented: $pendingLinkAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text("這個頁面還沒上線，敬請期待。")
            }
        }
    }

    private var brandSection: some View {
        Section {
            HStack(spacing: 12) {
                Image("PeluLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Pelu")
                        .font(.headline)
                    Text("Usage signal for Claude Code and Codex")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle("低額度警告", isOn: $lowQuotaEnabled)
                .onChange(of: lowQuotaEnabled) { _, enabled in
                    Task { await handleToggleChange(.lowQuota, enabled: enabled) }
                }

            Toggle("短期額度重置提醒", isOn: $resetEnabled)
                .onChange(of: resetEnabled) { _, enabled in
                    Task { await handleToggleChange(.reset, enabled: enabled) }
                }

            Toggle("每週重置提醒", isOn: $weeklyResetEnabled)
                .onChange(of: weeklyResetEnabled) { _, enabled in
                    Task { await handleToggleChange(.weeklyReset, enabled: enabled) }
                }

            VStack(alignment: .leading, spacing: 6) {
                Text("低額度警告：目前主要額度剩餘低於 10%（已使用 > 90%）時推送。")
                Text("短期額度重置提醒：5 小時或每日等短期視窗重置時通知。")
                Text("每週重置提醒：7 天用量重置時通知。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            Text("通知")
        } footer: {
            if notifications.authorizationStatus == .denied {
                Text("通知權限已被拒絕，請至系統設定開啟。")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var liveActivitySection: some View {
        Section {
            Toggle("啟用動態島 / 即時活動", isOn: $liveActivityEnabled)
                .onChange(of: liveActivityEnabled) { _, enabled in
                    if !enabled { LiveActivityManager.shared.end() }
                }
            Text("開啟後刷新資料時會自動啟動 Live Activity，顯示在動態島與鎖定畫面。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Live Activity")
        }
    }

    private var devicesSection: some View {
        Section {
            if isLoadingDevices {
                HStack {
                    ProgressView()
                    Text("讀取中…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if devices.isEmpty {
                Text("尚未偵測到 Mac")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices) { mac in
                    deviceRow(mac)
                }
                .onDelete(perform: deleteDevices)
            }
        } header: {
            Text("裝置")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let deviceErrorMessage {
                    Text(deviceErrorMessage)
                        .foregroundStyle(.orange)
                }
                Text("左滑可刪除已退役的 Mac。若該 Mac 仍在執行 Pelu，下次上傳時會自動重新加回列表。")
            }
            .font(.caption2)
        }
    }

    private func deviceRow(_ mac: MacSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.label)
                    .font(.callout.weight(.medium))
                Text("最後更新 \(UpdatedAtFormatter.string(from: mac.snapshot.generatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if deletingMacIds.contains(mac.macId) {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
    }

    private func deleteDevices(at offsets: IndexSet) {
        let targets = offsets.map { devices[$0] }
        for target in targets {
            Task { await deleteDevice(target) }
        }
    }

    @MainActor
    private func deleteDevice(_ mac: MacSnapshot) async {
        deletingMacIds.insert(mac.macId)
        defer { deletingMacIds.remove(mac.macId) }

        do {
            try await Self.syncer.deleteMac(macId: mac.macId)
            // 立刻從清單拿掉；下次背景 fetch 還會以 CloudKit 為準。
            devices.removeAll { $0.macId == mac.macId }
            // 也讓 dashboard / widget 重新讀一次最新的 aggregate。
            _ = try? await UsageSurfaceUpdater.fetchFromCloud(updateLiveActivity: false)
            deviceErrorMessage = nil
        } catch {
            deviceErrorMessage = "刪除「\(mac.label)」失敗，請稍後再試。"
        }
    }

    @MainActor
    private func loadDevices() async {
        isLoadingDevices = true
        defer { isLoadingDevices = false }
        loadDevicesFromLocal()
        // 直接打一次 CloudKit 確保拿到最新名單（不只是 dashboard 的快取）。
        do {
            let aggregate = try await Self.syncer.fetchAllMacs()
            devices = aggregate.macs
            deviceErrorMessage = nil
        } catch {
            // 失敗就以本地 aggregate 為主，不覆蓋。
            if devices.isEmpty {
                deviceErrorMessage = "無法讀取裝置列表，請確認 iCloud 連線。"
            }
        }
    }

    private func loadDevicesFromLocal() {
        guard let store = AppGroupStore(),
              let aggregate = try? store.loadLatestAggregate() else { return }
        devices = aggregate.macs
    }

    private var iCloudSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: iCloudIconName)
                    .foregroundStyle(iCloudColor)
                Text(CloudKitAccountChecker.displayMessage(for: iCloudInfo.status))
                    .font(.callout)
            }
            if let fingerprint = CloudKitAccountChecker.displayFingerprint(iCloudInfo.userRecordName) {
                LabeledContent("帳號 ID") {
                    Text(fingerprint)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("iCloud 同步")
        } footer: {
            if iCloudInfo.userRecordName != nil {
                Text("這個 ID 是 Apple 用來識別你的 iCloud 帳號的代號（Pelu 看不到你的 email）。在不同裝置上看到一樣的 ID，就代表它們連的是同一個 iCloud 帳號。")
                    .font(.caption2)
            }
        }
    }

    private var iCloudIconName: String {
        switch iCloudInfo.status {
        case .available: return "icloud.fill"
        case .noAccount, .restricted: return "icloud.slash"
        case .unknown, .unexpected: return "icloud"
        }
    }

    private var iCloudColor: Color {
        switch iCloudInfo.status {
        case .available: return .green
        case .noAccount, .restricted: return .orange
        case .unknown, .unexpected: return .secondary
        }
    }

    private var resourcesSection: some View {
        Section("資源") {
            linkRow(label: "教學中心", systemImage: "book", url: Self.tutorialCenterURL)
            linkRow(label: "支援中心", systemImage: "lifepreserver", url: Self.supportCenterURL)
            linkRow(label: "隱私權政策", systemImage: "hand.raised", url: Self.privacyPolicyURL)
        }
    }

    @ViewBuilder
    private func linkRow(label: String, systemImage: String, url: URL?) -> some View {
        Button {
            if let url {
                UIApplication.shared.open(url)
            } else {
                pendingLinkAlert = true
            }
        } label: {
            HStack {
                Label(label, systemImage: systemImage)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var aboutSection: some View {
        Section("關於") {
            LabeledContent("版本", value: Self.appVersion)
            LabeledContent("資料儲存位置", value: "你的 iCloud")
        }
    }

    private static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    private enum NotificationKind {
        case lowQuota
        case reset
        case weeklyReset
    }

    private func handleToggleChange(_ kind: NotificationKind, enabled: Bool) async {
        switch kind {
        case .lowQuota:    NotificationManager.shared.lowQuotaEnabled     = enabled
        case .reset:       NotificationManager.shared.resetEnabled        = enabled
        case .weeklyReset: NotificationManager.shared.weeklyResetEnabled  = enabled
        }

        guard enabled else {
            switch kind {
            case .lowQuota:    await LocalUsageNotifier.cancelLowQuotaWarnings()
            case .reset:       await LocalUsageNotifier.cancelFiveHourResetReminders()
            case .weeklyReset: await LocalUsageNotifier.cancelWeeklyResetReminders()
            }
            return
        }

        let granted = await NotificationManager.shared.requestAuthorizationIfNeeded()
        if !granted {
            switch kind {
            case .lowQuota:
                lowQuotaEnabled = false
                NotificationManager.shared.lowQuotaEnabled = false
            case .reset:
                resetEnabled = false
                NotificationManager.shared.resetEnabled = false
            case .weeklyReset:
                weeklyResetEnabled = false
                NotificationManager.shared.weeklyResetEnabled = false
            }
            permissionDeniedAlert = true
        }
    }
}

#Preview {
    PeluSettingsScreen()
}
