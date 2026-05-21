import PeluCore
import SwiftUI

/// Standalone Settings window for the macOS app. Holds *all* user-facing
/// preferences so the menu bar popover stays a clean glance surface.
struct PeluMacSettingsView: View {
    @Bindable var monitor: UsageMonitor

    @AppStorage("pelu.onboardingCompleted") private var onboardingCompleted = true
    @State private var iCloudInfo: CloudKitAccountChecker.AccountInfo = .init(
        status: .unknown(underlying: "checking"),
        userRecordName: nil
    )
    @State private var hookInstallToast: String?
    @State private var pendingLinkAlert = false

    /// Outbound link targets. Replace with the real URLs once the pages exist;
    /// tapping a nil one shows a "尚未開放" alert.
    private static let privacyPolicyURL: URL? = nil
    private static let supportCenterURL: URL? = nil
    private static let tutorialCenterURL: URL? = nil

    var body: some View {
        Form {
            menuBarSection
            iCloudSection
            resourcesSection
            advancedSection
            aboutSection
        }
        .formStyle(.grouped)
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
            LabeledContent("版本", value: "1.0.0")
            LabeledContent("資料儲存位置", value: "你的 iCloud")
        }
    }
}
