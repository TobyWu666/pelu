import PeluCore
import PeluUI
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct PeluEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

struct PeluProvider: TimelineProvider {
    func placeholder(in context: Context) -> PeluEntry {
        PeluEntry(date: Date(), snapshot: .demo())
    }

    func getSnapshot(in context: Context, completion: @escaping (PeluEntry) -> Void) {
        let now = Date()
        completion(PeluEntry(date: now, snapshot: cachedSnapshot(at: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PeluEntry>) -> Void) {
        // Refresh relative labels periodically and insert exact reset-time
        // entries so a cached CloudKit percentage drops to zero on schedule.
        let now = Date()
        let aggregate = cachedAggregate()
        let calendar = Calendar.current
        let reload = calendar.date(byAdding: .minute, value: 90, to: now) ?? now
        var dates: Set<Date> = []
        for offset in 0..<6 {
            let date = calendar.date(byAdding: .minute, value: offset * 15, to: now) ?? now
            dates.insert(date)
        }
        if let aggregate {
            let resetDates = aggregate.macs.flatMap { mac in
                mac.snapshot.metrics.flatMap { [$0.resetDate, $0.weeklyResetDate] }
            }
            for date in resetDates.compactMap({ $0 }) where date > now && date <= reload {
                dates.insert(date)
            }
        }
        let entries = dates.sorted().map { date in
            PeluEntry(date: date, snapshot: cachedSnapshot(at: date, aggregate: aggregate))
        }
        completion(Timeline(entries: entries, policy: .after(reload)))
    }

    private func cachedAggregate() -> AggregateSnapshot? {
        guard let store = AppGroupStore() else { return nil }
        return try? store.loadLatestAggregate()
    }

    private func cachedSnapshot(at now: Date, aggregate: AggregateSnapshot? = nil) -> UsageSnapshot {
        // Widget mirrors dashboard composition via displaySnapshot: Claude is
        // conservative (highest usage), Codex uses the newest account quota.
        if let aggregate = aggregate ?? cachedAggregate(),
           let display = aggregate.displaySnapshot(at: now) {
            return display
        }
        return .demo(now: now)
    }
}

// MARK: - Shared building blocks

/// 單層用量條：底色 = tint × 低 alpha，前景 = tint 實色。沒有「週期已過時間」
/// 的疊加層 — 那個概念在歷史 / Dashboard 顯示，widget / Live Activity
/// 空間太小放不下，留下來只會看起來雜亂。module-internal 讓 LiveActivity
/// 也能共用。
struct UsageBar: View {
    let percent: Double?
    let tint: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.14))
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * PercentFormatter.progress(from: percent))
            }
        }
        .frame(height: height)
    }
}

/// 環形進度 — 小 widget 用，比細條更耐看。`.round` lineCap 讓尾端不會
/// 有銳角；`-90°` 旋轉讓 0% 從 12 點鐘方向開始繞。內文字體比例綁定環的
/// 直徑（size / 3），讓 ring 放大時數字也跟著放大。
private struct UsageRing: View {
    let percent: Double?
    let tint: Color
    var lineWidth: CGFloat = 7
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: PercentFormatter.progress(from: percent))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text(PercentFormatter.string(from: percent))
                .font(.system(size: size / 3.2, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .padding(.horizontal, lineWidth + 2)
        }
        .frame(width: size, height: size)
    }
}

private extension ProviderKind {
    /// Widget 用的短名稱 — `displayName` 的 "Claude Code" 在 widget header
    /// 太長會吃掉百分比的空間。
    var widgetShortName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex:      "Codex"
        }
    }
}

// MARK: - Small widget

/// 小 widget：只顯示一個 provider 的大圓環。挑選邏輯：兩者都有 usedPercent
/// 時取較高的（worst-case glance），否則挑有資料的那個，最後 fallback
/// 到 metrics.first 保證至少能渲染。
private struct SmallWidgetView: View {
    let snapshot: UsageSnapshot

    private var primary: UsageMetric {
        let withData = snapshot.metrics.filter { $0.usedPercent != nil }
        if let top = withData.max(by: { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }) {
            return top
        }
        return snapshot.metrics.first
            ?? UsageMetric(provider: .claudeCode, usedPercent: nil)
    }

    var body: some View {
        let metric = primary
        VStack(spacing: 12) {
            Text(metric.provider.widgetShortName)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            UsageRing(
                percent: metric.usedPercent,
                tint: metric.status.tintColor,
                lineWidth: 9,
                size: 92
            )

            if let reset = metric.resetDate {
                Text(ResetTimeFormatter.string(from: reset, now: Date()))
                    .font(.system(size: 11, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

// MARK: - Medium widget

/// 中 widget：兩欄獨立卡片（左 Claude / 右 Codex），各卡有大百分比、條、
/// 主要視窗重置倒數、次要視窗用量（小字 + 細條）。卡片用 thinMaterial + status tint
/// 邊框做視覺區隔，不靠 divider。
private struct MediumWidgetView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image("PeluSimpleLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text("Pelu")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(UpdatedAtFormatter.string(from: snapshot.generatedAt))
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                ForEach(snapshot.metrics) { metric in
                    MediumProviderCard(metric: metric)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct MediumProviderCard: View {
    let metric: UsageMetric
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(metric.provider.assetName)
                    .resizable()
                    .scaledToFit()
                    .padding(metric.provider == .codex ? 2 : 0)
                    .frame(width: 14, height: 14)
                Text(metric.provider.widgetShortName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            // 主用量 % — 字級拉到最大，與卡片標題、底部 meta 形成
            // 「icon + name → big % → meta」三層視覺階級。
            Text(PercentFormatter.string(from: metric.usedPercent))
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(metric.status.tintColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.top, 2)

            UsageBar(percent: metric.usedPercent, tint: metric.status.tintColor, height: 5)
                .padding(.top, 2)

            Spacer(minLength: 2)

            VStack(alignment: .leading, spacing: 4) {
                if let reset = metric.resetDate {
                    Text(ResetTimeFormatter.string(from: reset, now: Date()))
                        .font(.system(size: 10, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let weekly = metric.weeklyPercent {
                    weeklyRow(weekly: weekly)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(metric.status.tintColor.opacity(0.18), lineWidth: 0.5)
        )
    }

    /// 次要視窗用量小列：左字 + 細條 + 右百分比。比主條更扁、tint 淡化，視覺
    /// 從屬於主要視窗用量。
    private func weeklyRow(weekly: Double) -> some View {
        HStack(spacing: 6) {
            Text(UsageMetric.windowLabel(durationMins: metric.resolvedSecondaryWindowDurationMins, compact: true))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            UsageBar(percent: weekly, tint: metric.status.tintColor.opacity(0.55), height: 3)
            Text(PercentFormatter.string(from: weekly))
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .trailing)
                .lineLimit(1)
        }
    }

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.04)
            : Color.black.opacity(0.03)
    }
}

// MARK: - Widget

struct PeluWidgetEntryView: View {
    let entry: PeluEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium:
            MediumWidgetView(snapshot: entry.snapshot)
        default:
            SmallWidgetView(snapshot: entry.snapshot)
        }
    }
}

struct PeluWidget: Widget {
    let kind = "PeluWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PeluProvider()) { entry in
            PeluWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(.systemBackground)
                }
        }
        .configurationDisplayName("Pelu")
        .description("Claude Code 與 Codex 用量")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
