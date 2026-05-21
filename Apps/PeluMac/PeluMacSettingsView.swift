import PeluCore
import SwiftUI

/// Standalone Settings window for the macOS app. Opened from the menu bar popover.
/// Mirrors the iOS settings concept but exposes Mac-specific actions like
/// re-installing the Claude statusLine hook and resetting onboarding.
struct PeluMacSettingsView: View {
    @AppStorage("pelu.onboardingCompleted") private var onboardingCompleted = true
    @State private var iCloudInfo: CloudKitAccountChecker.AccountInfo = .init(
        status: .unknown(underlying: "checking"),
        userRecordName: nil
    )
    @State private var hookInstallToast: String?

    var body: some View {
        Form {
            Section("iCloud 同步") {
                HStack(spacing: 10) {
                    Image(systemName: iCloudIconName).foregroundStyle(iCloudColor)
                    Text(CloudKitAccountChecker.displayMessage(for: iCloudInfo.status))
                }
                if let fingerprint = CloudKitAccountChecker.displayFingerprint(iCloudInfo.userRecordName) {
                    LabeledContent("帳號 ID") {
                        Text(fingerprint).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Claude Code hook") {
                Button("重新安裝 hook") {
                    ClaudeHookInstaller.installIfNeeded()
                    hookInstallToast = "已重新安裝 statusLine hook"
                }
                .help("如果 hook 不見了或被其他工具覆蓋，按這個重裝。")

                if let toast = hookInstallToast {
                    Text(toast).font(.caption).foregroundStyle(.green)
                }
            }

            Section("一般") {
                Button("重設首次啟動引導") {
                    onboardingCompleted = false
                }
                .help("下次啟動 Pelu 會再跑一次 4 步驟 onboarding。")
            }

            Section("關於") {
                LabeledContent("版本", value: "1.0.0")
                LabeledContent("資料儲存位置", value: "你的 iCloud")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 380, idealHeight: 460)
        .task {
            iCloudInfo = await CloudKitAccountChecker().info()
        }
        .navigationTitle("Pelu 設定")
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
}

#Preview {
    PeluMacSettingsView()
}
