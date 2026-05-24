import PeluCore
import SwiftUI

// MARK: - PeluProgressBar

private struct PeluProgressBar: View {
    let value: Double            // 0 … 1
    var tint: Color = .accentColor
    /// When supplied, renders a 1pt sky-blue line under the main bar showing
    /// how far through the current cycle we are. Same visual language as the
    /// weekly bar's cycle indicator.
    var cycleElapsed: Double? = nil

    var body: some View {
        VStack(spacing: cycleGap) {
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

            if let cycleElapsed {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(PeluTheme.sky)
                            .frame(
                                width: geo.size.width * min(max(cycleElapsed, 0), 1),
                                height: cycleLineHeight
                            )
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: cycleLineHeight)
            }
        }
    }

    private var mainBarHeight: CGFloat { 10 }
    private var cycleLineHeight: CGFloat { 1 }
    private var cycleGap: CGFloat { 3 }
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
                .frame(width: 44, alignment: .trailing)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
    }

    @ViewBuilder
    private func barContent(width: CGFloat) -> some View {
        let usageWidth = width * min(max(percent / 100, 0), 1)

        VStack(spacing: cycleLineGap) {
            plainUsageBar(width: usageWidth)
            // Hair-thin solid blue line under the usage bar, length tracks
            // how far through the 7-day cycle we are. Subtle, doesn't compete
            // with the main bar. Same treatment on iOS and macOS.
            if let outerProgress {
                let elapsedWidth = width * min(max(outerProgress, 0), 1)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(PeluTheme.sky)
                        .frame(width: elapsedWidth, height: cycleLineHeight)
                    Spacer(minLength: 0)
                }
            }
        }
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
        outerProgress == nil
            ? secondaryBarHeight
            : secondaryBarHeight + cycleLineGap + cycleLineHeight
    }

    private var cycleLineHeight: CGFloat { 1 }
    private var cycleLineGap: CGFloat { 3 }

    private var secondaryBarHeight: CGFloat { 6 }
}

// MARK: - UsageMetricCard

struct UsageMetricCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let metric: UsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
            }

            // Wrap the progress bars + reset countdown text in a TimelineView
            // so the cycle indicators (5h + weekly) and "剩 X 小時 Y 分" labels
            // tick down locally — no fetch / silent push needed. Cadence is
            // 1 minute, which matches ResetTimeFormatter's granularity.
            TimelineView(.periodic(from: Date(), by: 60)) { context in
                let now = context.date

                VStack(spacing: 10) {
                    PeluProgressBar(
                        value: PercentFormatter.progress(from: metric.usedPercent),
                        tint: metric.status.tintColor,
                        cycleElapsed: fiveHourElapsedProgress(now: now)
                    )

                    if let weekly = metric.weeklyPercent {
                        SecondaryBar(
                            label: "Weekly",
                            percent: weekly,
                            colorScheme: colorScheme,
                            outerProgress: weeklyElapsedProgress(now: now)
                        )
                    }
                }

                HStack(alignment: .top) {
                    Label(metric.status.label, systemImage: "circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(metric.status.tintColor, metric.status.tintColor)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        if let d = metric.resetDate {
                            Text("5hr \(ResetTimeFormatter.string(from: d, now: now))")
                        }
                        if let d = metric.weeklyResetDate {
                            Text("7日 \(ResetTimeFormatter.string(from: d, now: now))")
                        }
                        if metric.resetDate == nil && metric.weeklyResetDate == nil {
                            Text("重置時間未定")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(PeluTheme.surface(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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

    private func fiveHourElapsedProgress(now: Date = Date()) -> Double? {
        guard let resetDate = metric.resetDate else { return nil }
        let windowDuration: TimeInterval = 5 * 60 * 60
        let startDate = resetDate.addingTimeInterval(-windowDuration)
        return clampedProgress(now.timeIntervalSince(startDate) / windowDuration)
    }

    private func weeklyElapsedProgress(now: Date = Date()) -> Double {
        if let resetDate = metric.weeklyResetDate {
            let weekDuration: TimeInterval = 7 * 24 * 60 * 60
            let startDate = resetDate.addingTimeInterval(-weekDuration)
            return clampedProgress(now.timeIntervalSince(startDate) / weekDuration)
        }

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
