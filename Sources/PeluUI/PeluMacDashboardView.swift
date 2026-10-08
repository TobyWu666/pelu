#if os(macOS)
import AppKit
import PeluCore
import SwiftUI

/// A single saved selection makes an empty panel impossible.
public enum MacPanelProviders: String {
    case all, claude, codex

    public func includes(_ provider: ProviderKind) -> Bool {
        self == .all || (provider == .claudeCode ? self == .claude : self == .codex)
    }

    public func setting(_ provider: ProviderKind, visible: Bool) -> Self {
        if visible {
            return includes(provider) ? self : .all
        }
        guard self == .all else { return self }
        return provider == .claudeCode ? .codex : .claude
    }
}

/// Compact native menu-bar surface. History belongs in a separate, larger view.
public struct PeluMacDashboardView: View {
    @AppStorage("pelu.mac.panelProviders") private var panelProviders = MacPanelProviders.all
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let snapshot: UsageSnapshot
    private let refreshAction: () -> Void
    private let analysisAction: (() -> Void)?

    public init(snapshot: UsageSnapshot, refreshAction: @escaping () -> Void, analysisAction: (() -> Void)? = nil) {
        self.snapshot = snapshot
        self.refreshAction = refreshAction
        self.analysisAction = analysisAction
    }

    public var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            VStack(alignment: .leading, spacing: 18) {
                header
                VStack(spacing: 12) {
                    ForEach(visibleMetrics) { metric in
                        MacQuotaCard(metric: metric.effective(at: context.date), now: context.date)
                    }
                }
                if let analysisAction {
                    Button(action: analysisAction) {
                        HStack {
                            Label("用量分析", systemImage: "chart.xyaxis.line")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PeluTheme.brandTeal(for: colorScheme))
                }
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text("最後更新 \(UpdatedAtFormatter.string(from: snapshot.generatedAt))")
                    Spacer(minLength: 28)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            .padding(20)
        }
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                MenuBarGlass()
                    .overlay((colorScheme == .dark ? Color.black : Color.white).opacity(0.06))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.14 : 0.45), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }

    private var visibleMetrics: [UsageMetric] {
        [ProviderKind.claudeCode, .codex]
            .filter { panelProviders.includes($0) }
            .map { snapshot.metric(for: $0) ?? UsageMetric(provider: $0, usedPercent: nil, note: "尚無使用資料") }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image("PeluLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 25, height: 25)
            Text("Pelu")
                .font(.system(size: 17, weight: .semibold))
            Text("用量概覽")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: refreshAction) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("重新整理用量")
            .help("重新整理用量")
        }
    }
}

private struct MacQuotaCard: View {
    @AppStorage("pelu.mac.quotaDisplayStyle") private var displayStyle = "rings"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let metric: UsageMetric
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 8) {
                Image(metric.provider.assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 23, height: 23)
                Text(metric.provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(metric.status.tintColor).frame(width: 5, height: 5)
                    Text(metric.status.label)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10, weight: .medium))
            }

            if displayStyle == "bars" {
                quotaRow(
                    percent: metric.usedPercent,
                    duration: metric.resolvedPrimaryWindowDurationMins,
                    reset: metric.resetDate,
                    prominent: true
                )

                if metric.weeklyPercent != nil {
                    Divider().opacity(0.5)
                    quotaRow(
                        percent: metric.weeklyPercent,
                        duration: metric.resolvedSecondaryWindowDurationMins,
                        reset: metric.weeklyResetDate,
                        prominent: false
                    )
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ringColumn(percent: metric.usedPercent, duration: metric.resolvedPrimaryWindowDurationMins, reset: metric.resetDate)
                    if metric.weeklyPercent != nil {
                        ringColumn(percent: metric.weeklyPercent, duration: metric.resolvedSecondaryWindowDurationMins, reset: metric.weeklyResetDate)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if let note = metric.note, metric.usedPercent == nil {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if displayStyle == "bars" || metric.dataSource == .localEstimate {
                HStack(spacing: 5) {
                    if displayStyle == "bars", metric.resetDate != nil || metric.weeklyResetDate != nil {
                        Image(systemName: "line.diagonal")
                        Text("刻度表示週期已過時間")
                    }
                    Spacer(minLength: 4)
                    if metric.dataSource == .localEstimate {
                        Text("本機估算")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            if let measuredAt = metric.measuredAt, now.timeIntervalSince(measuredAt) >= UsageMetric.staleAfter {
                Label("資料更新於 \(UpdatedAtFormatter.string(from: measuredAt))", systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(reduceTransparency
                      ? Color(nsColor: .controlBackgroundColor)
                      : (colorScheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.32)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.5), lineWidth: 0.5)
        }
    }

    private func ringColumn(percent: Double?, duration: Int, reset: Date?) -> some View {
        let progress = elapsed(reset: reset, duration: duration)
        return VStack(spacing: 9) {
            Text(UsageMetric.windowLabel(durationMins: duration))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            MacQuotaRings(percent: percent, elapsed: progress)
                .frame(width: 114, height: 114)
                .padding(.vertical, 3)
            Text(reset.map { ResetTimeFormatter.string(from: $0, now: now) } ?? "重置時間未定")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func quotaRow(percent: Double?, duration: Int, reset: Date?, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(UsageMetric.windowLabel(durationMins: duration))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("已用")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(PercentFormatter.string(from: percent))
                    .font(.system(size: prominent ? 29 : 20, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            MacQuotaGauge(percent: percent, elapsed: elapsed(reset: reset, duration: duration))
            HStack {
                Text(percent.map { "剩餘 \(PercentFormatter.string(from: max(0, 100 - $0)))" } ?? "尚無資料")
                Spacer()
                Text(reset.map { ResetTimeFormatter.string(from: $0, now: now) } ?? "重置時間未定")
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func elapsed(reset: Date?, duration: Int) -> Double? {
        guard let reset, duration > 0 else { return nil }
        // Once a reset passes, wait for the next source window before showing a marker.
        guard reset > now else { return nil }
        return min(1, max(0, 1 - reset.timeIntervalSince(now) / (Double(duration) * 60)))
    }
}

private struct MacQuotaRings: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let percent: Double?
    let elapsed: Double?

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 8)
            if let percent, percent.isFinite {
                Circle()
                    .trim(from: 0, to: min(1, max(0, percent / 100)))
                    .stroke(UsageStatus.from(percent: percent).tintColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Circle()
                .stroke(.primary.opacity(0.06), style: StrokeStyle(lineWidth: 4, dash: elapsed == nil ? [2, 4] : []))
                .padding(13)
            if let elapsed {
                Circle()
                    .trim(from: 0, to: min(1, max(0, elapsed)))
                    .stroke(PeluTheme.sky, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(13)
            }
            VStack(spacing: 2) {
                Text(PercentFormatter.string(from: percent))
                    .font(.system(size: 23, weight: .semibold)).monospacedDigit()
                Text("已用").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: percent)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: elapsed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("雙環配額")
        .accessibilityValue("已用 \(PercentFormatter.string(from: percent))，" + (elapsed.map { "週期已過 \(Int($0 * 100))%" } ?? "週期進度未定"))
    }
}

private struct MacQuotaGauge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let percent: Double?
    let elapsed: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                if let percent {
                    Capsule()
                        .fill(UsageStatus.from(percent: percent).tintColor)
                        .frame(width: geometry.size.width * min(1, max(0, percent / 100)))
                }
                if let elapsed {
                    Capsule()
                        .fill(.primary.opacity(0.8))
                        .frame(width: 2, height: 13)
                        .offset(x: min(max(0, geometry.size.width * elapsed - 1), max(0, geometry.size.width - 2)))
                }
            }
            .frame(height: 7)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 13)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: percent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("配額用量")
        .accessibilityValue(accessibleValue)
    }

    private var accessibleValue: String {
        var value = percent.map { "已用 \(PercentFormatter.string(from: $0))" } ?? "尚無資料"
        if let elapsed {
            value += "，週期已過 \(Int(elapsed * 100))%"
        }
        return value
    }
}

/// Behind-window blending lets the desktop show through the menu-bar NSPanel.
private struct MenuBarGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = TransparentEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    private final class TransparentEffectView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
        }
    }
}

#Preview("Glass · Light") {
    PeluMacDashboardView(snapshot: .demo(), refreshAction: {})
        .frame(width: 392)
        .preferredColorScheme(.light)
}

#Preview("Glass · Dark") {
    PeluMacDashboardView(snapshot: .demo(), refreshAction: {})
        .frame(width: 392)
        .preferredColorScheme(.dark)
}
#endif
