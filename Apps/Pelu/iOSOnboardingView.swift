import PeluCore
import PeluUI
import SwiftUI

/// 3-step first-launch onboarding for iOS.
/// 1. Welcome
/// 2. Status branching — iCloud OK + has data → go straight in; iCloud OK + no data → wait for Mac; iCloud problem → instructions
/// 3. Optional notifications + Live Activity opt-in
struct iOSOnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("pelu.onboardingCompleted") private var onboardingCompleted = false
    @AppStorage("pelu.notify.lowQuota") private var lowQuotaEnabled = false
    @AppStorage("pelu.notify.reset") private var resetEnabled = false
    @AppStorage("pelu.notify.weeklyReset") private var weeklyResetEnabled = false
    @AppStorage("pelu.liveActivityEnabled") private var liveActivityEnabled = false

    @State private var step: Step = .welcome
    @State private var iCloudStatus: CloudKitAccountChecker.Result = .unknown(underlying: "checking")
    @State private var hasMacData = false

    enum Step: Int { case welcome = 0, status, optional }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                content
                Spacer()
                progressDots
                primaryButton
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 32)
        }
        .task {
            iCloudStatus = await CloudKitAccountChecker().status()
            await checkMacData()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:  welcomeStep
        case .status:   statusStep
        case .optional: optionalStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Image("PeluLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
            Text("歡迎使用 Pelu")
                .font(.title.weight(.bold))
            Text("在這支 iPhone 上即時看到你 Mac 上的 Claude Code 與 Codex 用量。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Text("資料只儲存在你自己的 iCloud，Pelu 開發者完全看不到。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var statusStep: some View {
        switch iCloudStatus {
        case .available where hasMacData:
            // Successful state — show confirmation, advance available.
            VStack(spacing: 18) {
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("已連線到你的 iCloud")
                    .font(.title3.weight(.semibold))
                Text("已偵測到 Mac 上傳的資料，準備完成。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .available:
            // No Mac data yet — show waiting state with instruction.
            VStack(spacing: 18) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)
                Text("等待 Mac 端資料")
                    .font(.title3.weight(.semibold))
                Text("請在你的 Mac 開啟 Pelu。你的 Mac 跟這支 iPhone 必須登入同一個 iCloud 帳號。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                Button("重新檢查") {
                    Task { await checkMacData() }
                }
                .buttonStyle(.bordered)
            }
        case .noAccount, .restricted:
            VStack(spacing: 18) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                Text(iCloudStatus == .noAccount ? "請登入 iCloud" : "iCloud 被限制")
                    .font(.title3.weight(.semibold))
                Text(CloudKitAccountChecker.displayMessage(for: iCloudStatus))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                Button("前往設定") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
        default:
            VStack(spacing: 16) {
                ProgressView()
                Text("檢查 iCloud 狀態中…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var optionalStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.badge")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
            Text("加值功能")
                .font(.title2.weight(.semibold))

            VStack(spacing: 12) {
                Toggle(isOn: $lowQuotaEnabled) {
                    VStack(alignment: .leading) {
                        Text("低額度警告")
                            .font(.callout.weight(.semibold))
                        Text("已使用 > 90% 時提醒")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $resetEnabled) {
                    VStack(alignment: .leading) {
                        Text("短期額度重置提醒")
                            .font(.callout.weight(.semibold))
                        Text("5 小時或每日等短期視窗重置時提醒")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $weeklyResetEnabled) {
                    VStack(alignment: .leading) {
                        Text("每週重置提醒")
                            .font(.callout.weight(.semibold))
                        Text("7 天用量重置時提醒")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $liveActivityEnabled) {
                    VStack(alignment: .leading) {
                        Text("動態島 / 鎖屏即時顯示")
                            .font(.callout.weight(.semibold))
                        Text("用量出現在鎖屏與動態島")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Text("這些都可以之後在「設定」內調整。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(i == step.rawValue ? PeluTheme.primaryText(for: colorScheme) : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        Button(action: advance) {
            Text(primaryButtonTitle)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(canAdvance ? PeluTheme.primaryText(for: colorScheme).opacity(0.9) : .secondary.opacity(0.3))
                .foregroundStyle(canAdvance ? Color(.systemBackground) : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!canAdvance)
    }

    private var primaryButtonTitle: String {
        switch step {
        case .welcome:  return "開始"
        case .status:   return hasMacData ? "下一步" : (iCloudStatus == .available ? "再等一下" : "等待 iCloud")
        case .optional: return "進入 Pelu"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .welcome:  return true
        case .status:   return iCloudStatus == .available && hasMacData
        case .optional: return true
        }
    }

    private func advance() {
        switch step {
        case .welcome:
            step = .status
        case .status:
            step = .optional
        case .optional:
            onboardingCompleted = true
        }
    }

    private func checkMacData() async {
        guard iCloudStatus == .available else { return }
        do {
            let syncer = CloudKitSyncer(
                bundleVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            )
            let aggregate = try await syncer.fetchAllMacs()
            hasMacData = !aggregate.macs.isEmpty
        } catch {
            hasMacData = false
        }
    }
}
