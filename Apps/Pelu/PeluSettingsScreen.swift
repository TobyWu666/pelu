import PeluCore
import SwiftUI
import UserNotifications

struct PeluSettingsScreen: View {
    @AppStorage("pelu.liveActivityEnabled") private var liveActivityEnabled = false
    @AppStorage("pelu.notify.lowQuota") private var lowQuotaEnabled = false
    @AppStorage("pelu.notify.reset") private var resetEnabled = false

    @StateObject private var notifications = NotificationManager.shared
    @State private var permissionDeniedAlert = false

    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                brandSection
                notificationsSection
                liveActivitySection
                pairingSection
                aboutSection
            }
            .navigationTitle("設定")
            .confirmationDialog(
                "解除配對？",
                isPresented: $confirmUnpair,
                titleVisibility: .visible
            ) {
                Button("解除配對", role: .destructive) {
                    AppAuth.shared.reset()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("解除後需要重新從 Mac 取得配對碼。")
            }
            .task { await notifications.refreshAuthorizationStatus() }
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

    private var pairingSection: some View {
        Section {
            Button(role: .destructive) {
                confirmUnpair = true
            } label: {
                Label("解除配對", systemImage: "iphone.slash")
            }
        } header: {
            Text("配對")
        } footer: {
            Text("解除後 app 會回到配對畫面，需要再從 Mac 取得 6 位數配對碼。")
        }
    }

    private var aboutSection: some View {
        Section("關於") {
            LabeledContent("版本", value: "0.1.0")
            LabeledContent("後端", value: "pelu.tobywu.org")
            LabeledContent("Bundle ID", value: "org.tobywu.pelu")
        }
    }

    private enum NotificationKind {
        case lowQuota
        case reset
    }

    private func handleToggleChange(_ kind: NotificationKind, enabled: Bool) async {
        // 同步寫到 NotificationManager 給上傳邏輯用
        switch kind {
        case .lowQuota: NotificationManager.shared.lowQuotaEnabled = enabled
        case .reset:    NotificationManager.shared.resetEnabled    = enabled
        }

        if enabled {
            let granted = await NotificationManager.shared.requestAuthorizationIfNeeded()
            if !granted {
                // 權限被拒：回滾 UI 與 manager 狀態
                switch kind {
                case .lowQuota:
                    lowQuotaEnabled = false
                    NotificationManager.shared.lowQuotaEnabled = false
                case .reset:
                    resetEnabled = false
                    NotificationManager.shared.resetEnabled = false
                }
                permissionDeniedAlert = true
                return
            }
        }

        await NotificationManager.shared.uploadPreferences()
    }
}

#Preview {
    PeluSettingsScreen()
}
