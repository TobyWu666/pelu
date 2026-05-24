import PeluCore
import PeluUI
import SwiftUI

/// 4-step first-launch onboarding for PeluMac. Persists completion via UserDefaults.
/// Walks the user through: welcome → iCloud check → provider detection → hook install.
struct MacOnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("pelu.onboardingCompleted") private var onboardingCompleted = false

    @State private var step: Step = .welcome
    @State private var iCloudStatus: CloudKitAccountChecker.Result = .unknown(underlying: "checking")
    @State private var detection: ProviderDetector.Result?
    @State private var hookInstallFailed = false
    @State private var conflictDecision: ConflictDecision = .replace

    enum Step: Int { case welcome = 0, iCloud, providers, hook }

    enum ConflictDecision: String, CaseIterable {
        case replace, codexOnly
        var label: String {
            switch self {
            case .replace:   return "使用 Pelu hook（備份原 hook）"
            case .codexOnly: return "跳過 Claude，只用 Codex"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("PeluSimpleLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
            Text("Pelu 設定")
                .font(.headline)
            Spacer()
            Text("步驟 \(step.rawValue + 1) / 4")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:   welcomeStep
        case .iCloud:    iCloudStep
        case .providers: providersStep
        case .hook:      hookStep
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("上一步") {
                    if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            primaryButton
        }
        .padding(18)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            Button("開始") { advance(to: .iCloud) }
                .buttonStyle(.borderedProminent)
        case .iCloud:
            Button("下一步") { advance(to: .providers) }
                .buttonStyle(.borderedProminent)
                .disabled(iCloudStatus != .available)
        case .providers:
            Button("下一步") { advance(to: .hook) }
                .buttonStyle(.borderedProminent)
                .disabled(!(detection?.hasAnyProvider ?? false) || !(detection?.python3Available ?? false))
        case .hook:
            Button("完成") { finishOnboarding() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func advance(to next: Step) {
        step = next
        Task {
            switch next {
            case .iCloud:    iCloudStatus = await CloudKitAccountChecker().status()
            case .providers: detection = ProviderDetector.detect()
            default: break
            }
        }
    }

    private func finishOnboarding() {
        // Apply hook decision before leaving onboarding.
        if let det = detection {
            switch det.claudeHookState {
            case .unconfigured, .conflict:
                if conflictDecision == .replace {
                    ClaudeHookInstaller.installIfNeeded()
                    let after = ProviderDetector.detect()
                    if case .peluInstalled = after.claudeHookState {
                        completeAndDismiss()
                    } else {
                        hookInstallFailed = true
                    }
                    return
                }
                // codexOnly: skip Claude hook install entirely.
                completeAndDismiss()
            case .peluInstalled, .providerMissing:
                completeAndDismiss()
            }
        } else {
            completeAndDismiss()
        }
    }

    private func completeAndDismiss() {
        onboardingCompleted = true
        dismissWindow(id: PeluMacApp.onboardingWindowID)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Image("PeluLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
            Text("歡迎使用 Pelu")
                .font(.title2.weight(.semibold))
            Text("把這台 Mac 的 Claude Code / Codex 用量，即時同步到你的 iPhone。\n\n資料只儲存在你自己的 iCloud — Pelu 開發者完全看不到。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
    }

    private var iCloudStep: some View {
        VStack(spacing: 18) {
            Image(systemName: iCloudIcon)
                .font(.system(size: 56))
                .foregroundStyle(iCloudColor)
            Text(stepIcloudTitle)
                .font(.title3.weight(.semibold))
            Text(CloudKitAccountChecker.displayMessage(for: iCloudStatus))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .lineSpacing(4)

            if iCloudStatus != .available {
                Button("重新檢查") {
                    Task { iCloudStatus = await CloudKitAccountChecker().status() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var iCloudIcon: String {
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

    private var stepIcloudTitle: String {
        switch iCloudStatus {
        case .available: return "iCloud 已連線"
        case .noAccount: return "請登入 iCloud"
        case .restricted: return "iCloud 被限制"
        default: return "檢查 iCloud 中…"
        }
    }

    private var providersStep: some View {
        VStack(spacing: 16) {
            Text("偵測本機 AI 工具")
                .font(.title3.weight(.semibold))

            if let d = detection {
                providerRow(name: "Claude Code", installed: d.claudeInstalled)
                providerRow(name: "Codex", installed: d.codexInstalled)
                providerRow(name: "Python 3", installed: d.python3Available)

                if !d.hasAnyProvider {
                    Text("Pelu 需要至少一個 AI CLI 才能運作。請先安裝 [Claude Code](https://claude.com/code) 或 Codex，再回來。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                } else if !d.python3Available {
                    Text("找不到系統 `/usr/bin/python3`。請執行 `xcode-select --install` 或安裝 Command Line Tools。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
            } else {
                ProgressView()
            }
        }
    }

    private func providerRow(name: String, installed: Bool) -> some View {
        HStack {
            Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(installed ? .green : .secondary)
            Text(name)
            Spacer()
            Text(installed ? "已偵測" : "未偵測")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 36)
    }

    private var hookStep: some View {
        VStack(spacing: 16) {
            Text("安裝 Claude Code hook")
                .font(.title3.weight(.semibold))

            if let det = detection {
                switch det.claudeHookState {
                case .providerMissing:
                    Text("你沒有安裝 Claude Code，跳過這一步即可使用 Codex 部分。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                case .peluInstalled:
                    Label("Hook 已安裝，無需動作", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .unconfigured:
                    Text("Pelu 會在 `~/.claude/settings.json` 加入一段 statusLine 設定，用來讀取 Claude Code 每次 session 的 token 用量。原檔會自動備份成 `settings.json.pelu-bak`。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .lineSpacing(4)
                case .conflict(let existing):
                    VStack(spacing: 14) {
                        Text("偵測到 `~/.claude/settings.json` 已有 statusLine 設定：")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(existing)
                            .font(.caption.monospaced())
                            .padding(8)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Picker("處理方式", selection: $conflictDecision) {
                            ForEach(ConflictDecision.allCases, id: \.self) { choice in
                                Text(choice.label).tag(choice)
                            }
                        }
                        .pickerStyle(.radioGroup)
                    }
                    .padding(.horizontal, 24)
                }
            }

            if hookInstallFailed {
                Text("Hook 安裝失敗，請檢查 `~/.claude/` 寫入權限後重試。")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
