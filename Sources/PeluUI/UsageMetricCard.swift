import PeluCore
import SwiftUI

// MARK: - QuotaGauge

/// Usage capsule with a short tick marking how far the window has run —
/// the same language as the Mac panel's gauge.
private struct QuotaGauge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let percent: Double?
    let elapsed: Double?
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                if let percent, percent > 0 {
                    Capsule()
                        .fill(UsageStatus.from(percent: percent).tintColor)
                        .frame(width: max(height, width * PercentFormatter.progress(from: percent)))
                }
                if let elapsed {
                    Capsule()
                        .fill(.primary.opacity(0.75))
                        .frame(width: 2, height: height + 6)
                        .offset(x: min(max(0, width * elapsed - 1), max(0, width - 2)))
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
        }
        .frame(height: height + 6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: percent)
        .accessibilityElement(children: .ignore)
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

// MARK: - QuotaRing

/// Outer ring is quota used, inner sky ring is how far the window has run,
/// the percentage sits in the middle — the Mac panel's dual ring, scaled down.
private struct QuotaRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let percent: Double?
    let elapsed: Double?
    let prominent: Bool

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 6)
            if let percent, percent.isFinite, percent > 0 {
                Circle()
                    .trim(from: 0, to: PercentFormatter.progress(from: percent))
                    .stroke(UsageStatus.from(percent: percent).tintColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Group {
                Circle()
                    .stroke(.primary.opacity(0.06), style: StrokeStyle(lineWidth: 3, dash: elapsed == nil ? [2, 4] : []))
                if let elapsed {
                    Circle()
                        .trim(from: 0, to: min(1, max(0, elapsed)))
                        .stroke(PeluTheme.sky, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .padding(9)
            let weight: Font.Weight = prominent ? .semibold : .medium
            (Text(percent.map { "\(Int($0.rounded()))" } ?? "--")
                .font(.system(size: prominent ? 18 : 16, weight: weight, design: .rounded))
             + Text("%")
                .font(.system(size: prominent ? 11 : 10, weight: weight, design: .rounded)))
                .monospacedDigit()
                .foregroundStyle(prominent ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 12)
        }
        .padding(3)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: percent)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("已用 \(PercentFormatter.string(from: percent))，" + (elapsed.map { "週期已過 \(Int($0 * 100))%" } ?? "週期進度未定"))
    }
}

// MARK: - UsageMetricCard

public enum UsageCardStyle: String, CaseIterable, Sendable {
    case bars
    case rings

    public static let storageKey = "pelu.ios.cardStyle"

    public var label: String {
        switch self {
        case .bars: "條狀"
        case .rings: "圓圈"
        }
    }
}

struct UsageMetricCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UsageCardStyle.storageKey) private var style: UsageCardStyle = .bars

    let metric: UsageMetric

    var body: some View {
        // A CloudKit value may remain cached after its source window resets.
        // Re-project the whole card every minute so it reaches 0% without
        // waiting for a new upload.
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            let current = metric.effective(at: context.date)
            Group {
                switch style {
                case .bars: barsCard(metric: current, now: context.date)
                case .rings: ringsCard(metric: current, now: context.date)
                }
            }
            .padding(16)
            .background(PeluTheme.surface(for: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(PeluTheme.border(for: colorScheme), lineWidth: 1)
            }
        }
    }

    // MARK: Rings

    private func ringsCard(metric: UsageMetric, now: Date) -> some View {
        let stale = stalenessText(measuredAt: metric.measuredAt, now: now)
        let sharedReset = metric.sharesResetDate && metric.weeklyPercent != nil && stale == nil

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                providerIcon(side: 26)
                Text(metric.provider.displayName)
                    .font(.headline)
                    .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Group {
                    if let stale {
                        staleLabel(stale, estimate: metric.dataSource == .localEstimate)
                    } else if sharedReset {
                        Text(resetText(metric.resetDate, now: now))
                    }
                }
                .font(.caption)
                .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
                .lineLimit(1)
            }

            HStack(spacing: 12) {
                ringColumn(
                    title: metric.windowTitle(secondary: false),
                    percent: metric.usedPercent,
                    elapsed: elapsed(reset: metric.resetDate, durationMins: metric.resolvedPrimaryWindowDurationMins, now: now),
                    reset: sharedReset ? nil : .some(metric.resetDate),
                    prominent: true,
                    now: now
                )
                if let weekly = metric.weeklyPercent {
                    ringColumn(
                        title: metric.windowTitle(secondary: true),
                        percent: weekly,
                        elapsed: elapsed(reset: metric.weeklyResetDate, durationMins: metric.resolvedSecondaryWindowDurationMins, now: now),
                        reset: sharedReset ? nil : .some(metric.weeklyResetDate),
                        prominent: false,
                        now: now
                    )
                }
            }

            if metric.usedPercent == nil, let note = metric.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
            }
        }
    }

    /// `reset` is nil when the card header already shows a shared reset.
    private func ringColumn(title: String, percent: Double?, elapsed: Double?, reset: Date??, prominent: Bool, now: Date) -> some View {
        HStack(spacing: 10) {
            QuotaRing(percent: percent, elapsed: elapsed, prominent: prominent)
                .frame(width: 70, height: 70)
                .accessibilityLabel("\(title) 配額")
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PeluTheme.secondaryText(for: colorScheme))
                if let reset {
                    Text(reset.flatMap { ResetTimeFormatter.remaining(until: $0, now: now) }.map { "\($0)後" }
                         ?? (reset == nil ? "重置時間未定" : "已重置"))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Bars

    private func barsCard(metric: UsageMetric, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                providerIcon(side: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric.provider.displayName)
                        .font(.headline)
                        .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
                        .lineLimit(1)
                    detailLine(metric: metric, now: now)
                }
                Spacer(minLength: 8)
                Text(PercentFormatter.string(from: metric.usedPercent))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
                    .accessibilityLabel("\(metric.windowTitle(secondary: false)) 已用 \(PercentFormatter.string(from: metric.usedPercent))")
            }

            QuotaGauge(
                percent: metric.usedPercent,
                elapsed: elapsed(reset: metric.resetDate, durationMins: metric.resolvedPrimaryWindowDurationMins, now: now),
                height: 8
            )
            .padding(.top, 14)

            if let weekly = metric.weeklyPercent {
                secondaryRow(metric: metric, percent: weekly, now: now)
                    .padding(.top, 12)
            }
        }
    }

    /// One quiet line under the name: what the big number measures and when
    /// it resets. Stale data takes the line over in amber instead.
    @ViewBuilder
    private func detailLine(metric: UsageMetric, now: Date) -> some View {
        Group {
            if let staleText = stalenessText(measuredAt: metric.measuredAt, now: now) {
                staleLabel(staleText, estimate: metric.dataSource == .localEstimate)
            } else if metric.usedPercent == nil, let note = metric.note {
                Text(note)
            } else {
                Text("\(metric.windowTitle(secondary: false)) · \(resetText(metric.resetDate, now: now))")
            }
        }
        .font(.caption)
        .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private func secondaryRow(metric: UsageMetric, percent: Double, now: Date) -> some View {
        HStack(spacing: 10) {
            Text(metric.windowTitle(secondary: true, compact: true))
                .font(.caption.weight(.medium))
                .foregroundStyle(PeluTheme.secondaryText(for: colorScheme))
                .frame(width: 34, alignment: .leading)
            QuotaGauge(
                percent: percent,
                elapsed: elapsed(reset: metric.weeklyResetDate, durationMins: metric.resolvedSecondaryWindowDurationMins, now: now),
                height: 5
            )
            Text(PercentFormatter.string(from: percent))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PeluTheme.secondaryText(for: colorScheme))
                .frame(minWidth: 38, alignment: .trailing)
            // Fixed column (even when the reset is shared and shown above) so
            // the bars line up from card to card.
            Group {
                if !metric.sharesResetDate, let reset = metric.weeklyResetDate {
                    Text(ResetTimeFormatter.remaining(until: reset, now: now).map { "\($0)後" } ?? "已重置")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 84, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func resetText(_ date: Date?, now: Date) -> String {
        guard let date else { return "重置時間未定" }
        return ResetTimeFormatter.remaining(until: date, now: now).map { "\($0)後重置" } ?? "已重置"
    }

    private func elapsed(reset: Date?, durationMins: Int, now: Date) -> Double? {
        guard let reset, durationMins > 0, reset > now else { return nil }
        return min(1, max(0, 1 - reset.timeIntervalSince(now) / (Double(durationMins) * 60)))
    }

    /// "更新於 X 分鐘前" once the measurement passes `UsageMetric.staleAfter`;
    /// fresh values stay silent.
    private func stalenessText(measuredAt: Date?, now: Date) -> String? {
        guard let measuredAt, now.timeIntervalSince(measuredAt) >= UsageMetric.staleAfter else { return nil }
        let minutes = Int(now.timeIntervalSince(measuredAt) / 60)
        let hours = minutes / 60
        if hours >= 1 {
            return hours >= 24 ? "更新於 \(hours / 24) 天前" : "更新於 \(hours) 小時前"
        }
        return "更新於 \(minutes) 分鐘前"
    }

    private func staleLabel(_ text: String, estimate: Bool) -> some View {
        HStack(spacing: 5) {
            if estimate {
                Text("估算")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(PeluTheme.amber.opacity(0.18)))
            }
            Text(text)
        }
        .foregroundStyle(PeluTheme.amber)
    }

    @ViewBuilder
    private func providerIcon(side: CGFloat) -> some View {
        #if os(iOS)
        if metric.provider == .claudeCode {
            AnimatedGIFView(name: "ClaudeGIF", size: CGSize(width: side, height: side))
                .frame(width: side, height: side)
                .fixedSize()
                .clipped()
        } else {
            Image(metric.provider.assetName)
                .resizable()
                .scaledToFit()
                .frame(width: side, height: side)
        }
        #else
        Image(metric.provider.assetName)
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
        #endif
    }
}
