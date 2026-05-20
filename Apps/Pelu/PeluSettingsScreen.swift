import PeluCore
import SwiftUI
import UserNotifications

struct PeluSettingsScreen: View {
    @AppStorage("pelu.liveActivityEnabled") private var liveActivityEnabled = false
    @AppStorage("pelu.notify.lowQuota") private var lowQuotaEnabled = false
    @AppStorage("pelu.notify.reset") private var resetEnabled = false

    @StateObject private var notifications = NotificationManager.shared
    @State private var permissionDeniedAlert = false
    @State private var iCloudStatus: CloudKitAccountChecker.Result = .unknown(underlying: "checking")

    var body: some View {
        NavigationStack {
            Form {
                brandSection
                iCloudSection
                notificationsSection
                liveActivitySection
                aboutSection
            }
            .navigationTitle("設定")
            .task {
                await notifications.refreshAuthorizationStatus()
                iCloudStatus = await CloudKitAccountChecker().status()
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

            Toggle("重置提醒", isOn: $resetEnabled)
                .onChange(of: resetEnabled) { _, enabled in
                    Task { await handleToggleChange(.reset, enabled: enabled) }
                }

            VStack(alignment: .leading, spacing: 6) {
                Text("低額度警告：5 小時剩餘額度低於 10%（已使用 > 90%）時推送。")
                Text("重置提醒：5 小時 / 每週用量重置可再使用時推送。")
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

    private var iCloudSection: some View {
        Section {
            HStack {
                Image(systemName: iCloudIconName)
                    .foregroundStyle(iCloudColor)
                Text(CloudKitAccountChecker.displayMessage(for: iCloudStatus))
                    .font(.callout)
            }
        } header: {
            Text("iCloud 同步")
        }
    }

    private var iCloudIconName: String {
        switch iCloudStatus {
        case .available: return "icloud.fill"
        case .noAccount, .restricted: return "icloud.slash"
        case .unknown, .unexpected: return "icloud"
        }
    }

    private var iCloudColor: Color {
        switch iCloudStatus {
        case .available: return .green
        case .noAccount, .restricted: return .orange
        case .unknown, .unexpected: return .secondary
        }
    }

    private var aboutSection: some View {
        Section("關於") {
            LabeledContent("版本", value: "1.0.0")
            LabeledContent("資料儲存位置", value: "你的 iCloud")
            LabeledContent("Bundle ID", value: "org.tobywu.pelu")
        }
    }

    private enum NotificationKind {
        case lowQuota
        case reset
    }

    private func handleToggleChange(_ kind: NotificationKind, enabled: Bool) async {
        switch kind {
        case .lowQuota: NotificationManager.shared.lowQuotaEnabled = enabled
        case .reset:    NotificationManager.shared.resetEnabled    = enabled
        }

        guard enabled else { return }

        let granted = await NotificationManager.shared.requestAuthorizationIfNeeded()
        if !granted {
            switch kind {
            case .lowQuota:
                lowQuotaEnabled = false
                NotificationManager.shared.lowQuotaEnabled = false
            case .reset:
                resetEnabled = false
                NotificationManager.shared.resetEnabled = false
            }
            permissionDeniedAlert = true
        }
    }
}

#Preview {
    PeluSettingsScreen()
}
