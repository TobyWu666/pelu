import PeluCore
import PeluUI
import ServiceManagement
import SwiftUI

/// Standalone Settings window for the macOS app. Holds *all* user-facing
/// preferences so the menu bar popover stays a clean glance surface.
struct PeluMacSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var monitor: UsageMonitor
    @ObservedObject var updater: PeluUpdater

    @AppStorage("pelu.onboardingCompleted") private var onboardingCompleted = true
    @State private var iCloudInfo: CloudKitAccountChecker.AccountInfo = .init(
        status: .unknown(underlying: "checking"),
        userRecordName: nil
    )
    @State private var hookInstallToast: String?
    @State private var pendingLinkAlert = false
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    private static let privacyPolicyURL: URL? = URL(string: "https://pelu.wutoby.com/privacy.html")
    private static let supportCenterURL: URL? = URL(string: "https://pelu.wutoby.com/support.html")
    private static let tutorialCenterURL: URL? = URL(string: "https://pelu.wutoby.com/tutorial.html")

    var body: some View {
        Form {
            brandSection
            menuBarSection
            launchSection
            iCloudSection
            updatesSection
            resourcesSection
            advancedSection
            aboutSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PeluTheme.background(for: colorScheme))
        .frame(minWidth: 460, idealWidth: 520, minHeight: 480, idealHeight: 560)
        .task {
            iCloudInfo = await CloudKitAccountChecker().info()
        }
        .alert("尚未開放", isPresented: $pendingLinkAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("這個頁面還沒上線，敬請期待。")
        }
        .navigationTitle("Pelu 設定")
    }

    // MARK: - Brand

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

    // MARK: - Menu bar display

    private var menuBarSection: some View {
        Section {
            Toggle("Claude %", isOn: $monitor.showClaude)
            Toggle("Codex %", isOn: $monitor.showCodex)
        } header: {
            Text("選單列顯示")
        } footer: {
            Text("勾選的項目會跟著 Pelu logo 一起顯示在選單列上。")
                .font(.caption2)
        }
    }

    // MARK: - Launch at login

    private var launchSection: some View {
        Section {
            Toggle("登入時自動啟動 Pelu", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    let result = LaunchAtLogin.setEnabled(newValue)
                    switch result {
                    case .success:
                        launchAtLogin = newValue
                        launchAtLoginError = nil
                    case .needsApproval:
                        launchAtLogin = newValue
                        launchAtLoginError = "已要求啟用，請在「系統設定 → 一般 → 登入項目」中允許 Pelu。"
                    case .failure(let message):
                        launchAtLogin = LaunchAtLogin.isEnabled
                        launchAtLoginError = message
                    }
                }
            ))
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("啟動")
        } footer: {
            Text("開啟後，每次登入 macOS 都會自動啟動 Pelu。可在「系統設定 → 一般 → 登入項目」中關閉。")
                .font(.caption2)
        }
    }

    // MARK: - iCloud

    private var iCloudSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: iCloudIconName).foregroundStyle(iCloudColor)
                Text(CloudKitAccountChecker.displayMessage(for: iCloudInfo.status))
            }
            if let fingerprint = CloudKitAccountChecker.displayFingerprint(iCloudInfo.userRecordName) {
                LabeledContent("帳號 ID") {
                    Text(fingerprint).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("iCloud 同步")
        } footer: {
            if iCloudInfo.userRecordName != nil {
                Text("Mac 與 iPhone 看到一樣的 ID 才代表連到同一個 iCloud。")
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

    // MARK: - Updates

    private var updatesSection: some View {
        Section {
            Toggle("自動檢查更新", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))
            Button("立即檢查更新…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        } header: {
            Text("更新")
        } footer: {
            Text("Pelu 會從 \(Self.appcastDisplayHost) 取得新版本，下載後驗證簽章再安裝。")
                .font(.caption2)
        }
    }

    private static let appcastDisplayHost = "pelu.wutoby.com"

    // MARK: - Resource links

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
                NSWorkspace.shared.open(url)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section("進階") {
            Button("重新安裝 Claude Code hook") {
                ClaudeHookInstaller.installIfNeeded()
                hookInstallToast = "已重新安裝 statusLine hook"
            }

            if let toast = hookInstallToast {
                Text(toast).font(.caption).foregroundStyle(.green)
            }

            Button("重設首次啟動引導") {
                onboardingCompleted = false
            }
        }
    }

    // MARK: - About

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
}
