import PeluCore
import SwiftUI

// MARK: - PeluProgressBar

private struct PeluProgressBar: View {
    let value: Double   // 0 … 1
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.15))
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
                    .animation(.easeOut(duration: 0.3), value: value)
            }
        }
        .frame(height: mainBarHeight)
    }

    private var mainBarHeight: CGFloat {
        #if os(iOS)
        return 10
        #else
        return 10
        #endif
    }
}

// MARK: - SecondaryBar

private struct SecondaryBar: View {
    let label: String
    let percent: Double
    let colorScheme: ColorScheme
    var outerProgress: Double? = nil
    var usageTint: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 46, alignment: .leading)
            GeometryReader { geo in
                barContent(width: geo.size.width)
            }
            .frame(height: barContainerHeight)
            Text(PercentFormatter.string(from: percent))
                .frame(width: 34, alignment: .trailing)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
    }

    @ViewBuilder
    private func barContent(width: CGFloat) -> some View {
        let usageWidth = width * min(max(percent / 100, 0), 1)
        let resolvedUsageTint = usageTint ?? .secondary

        #if os(iOS)
        if let outerProgress {
            let elapsedWidth = width * min(max(outerProgress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(PeluTheme.sky.opacity(colorScheme == .dark ? 0.10 : 0.08))
                    .frame(height: outerBarHeight)
                Capsule()
                    .fill(PeluTheme.sky.opacity(colorScheme == .dark ? 0.34 : 0.24))
                    .frame(width: elapsedWidth, height: outerBarHeight)
                Capsule()
                    .strokeBorder(PeluTheme.sky.opacity(colorScheme == .dark ? 0.32 : 0.22), lineWidth: 1)
                    .frame(height: outerBarHeight)

                Capsule()
                    .fill(PeluTheme.primaryText(for: colorScheme).opacity(colorScheme == .dark ? 0.14 : 0.08))
                    .frame(height: secondaryBarHeight)
                Capsule()
                    .fill(resolvedUsageTint.opacity(colorScheme == .dark ? 0.82 : 0.72))
                    .frame(width: usageWidth, height: secondaryBarHeight)
            }
        } else {
            plainUsageBar(width: usageWidth)
        }
        #else
        plainUsageBar(width: usageWidth)
        #endif
    }

    private func plainUsageBar(width: CGFloat) -> some View {
        let resolvedUsageTint = usageTint ?? .secondary

        return ZStack(alignment: .leading) {
            Capsule().fill(.secondary.opacity(0.12))
            Capsule()
                .fill(resolvedUsageTint.opacity(usageTint == nil ? 0.55 : 0.70))
                .frame(width: width)
        }
        .frame(height: secondaryBarHeight)
    }

    private var barContainerHeight: CGFloat {
        #if os(iOS)
        return outerProgress == nil ? secondaryBarHeight : outerBarHeight
        #else
        return secondaryBarHeight
        #endif
    }

    private var outerBarHeight: CGFloat {
        10
    }

    private var secondaryBarHeight: CGFloat {
        #if os(iOS)
        return 6
        #else
        return 6
        #endif
    }
}

// MARK: - UsageMetricCard

struct UsageMetricCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let metric: UsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                #if os(macOS)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .center, spacing: 8) {
                        providerIcon
                        providerTitle
                    }

                    Text(metric.note ?? metric.status.label)
                        .font(.callout)
                        .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
                }
                #else
                HStack(alignment: .center, spacing: 10) {
                    providerIcon

                    VStack(alignment: .leading, spacing: 3) {
                        providerTitle

                        Text(metric.note ?? metric.status.label)
                            .font(.caption)
                            .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
                            .lineLimit(1)
                    }
                }
                #endif

                Spacer()

                Text(PercentFormatter.string(from: metric.usedPercent))
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
            }

            VStack(spacing: 10) {
                PeluProgressBar(
                    value: PercentFormatter.progress(from: metric.usedPercent),
                    tint: metric.status.tintColor
                )

                if let weekly = metric.weeklyPercent {
                    SecondaryBar(
                        label: "Weekly",
                        percent: weekly,
                        colorScheme: colorScheme,
                        outerProgress: weeklyElapsedProgress
                    )
                }

                #if os(macOS)
                if let ctx = metric.contextWindowPercent {
                    SecondaryBar(
                        label: "Context",
                        percent: ctx,
                        colorScheme: colorScheme
                    )
                }
                #endif
            }

            HStack(alignment: .top) {
                Label(metric.status.label, systemImage: "circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(metric.status.tintColor, metric.status.tintColor)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if let d = metric.resetDate {
                        Text("5hr \(ResetTimeFormatter.string(from: d))")
                    }
                    if let d = metric.weeklyResetDate {
                        Text("7日 \(ResetTimeFormatter.string(from: d))")
                    }
                    if metric.resetDate == nil && metric.weeklyResetDate == nil {
                        Text("重置時間未定")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
        }
        .padding(16)
        .background(PeluTheme.surface(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(PeluTheme.border(for: colorScheme), lineWidth: 1)
        }
    }

    private var providerTitle: some View {
        Text(metric.provider.displayName)
            .font(providerTitleFont)
            .foregroundStyle(PeluTheme.secondaryText(for: colorScheme))
            .lineLimit(1)
            .minimumScaleFactor(0.68)
    }

    private var providerTitleFont: Font {
        #if os(macOS)
        return .title3.weight(.semibold)
        #else
        return .headline
        #endif
    }

    private var weeklyElapsedProgress: Double {
        if let resetDate = metric.weeklyResetDate {
            let weekDuration: TimeInterval = 7 * 24 * 60 * 60
            let startDate = resetDate.addingTimeInterval(-weekDuration)
            return clampedProgress(Date().timeIntervalSince(startDate) / weekDuration)
        }

        let now = Date()
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: now) else {
            return 0
        }
        return clampedProgress(now.timeIntervalSince(week.start) / week.duration)
    }

    private func clampedProgress(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    @ViewBuilder
    private var providerIcon: some View {
        #if os(iOS)
        if metric.provider == .claudeCode {
            AnimatedGIFView(name: "ClaudeGIF", size: CGSize(width: 44, height: 44))
                .frame(width: 44, height: 44)
                .fixedSize()
                .clipped()
        } else {
            Image(metric.provider.assetName)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
        }
        #else
        Image(metric.provider.assetName)
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
        #endif
    }
}
