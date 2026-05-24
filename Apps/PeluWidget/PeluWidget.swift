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

// MARK: - Views

struct WeeklyCycleBar: View {
    let weeklyPercent: Double
    let weeklyResetDate: Date?
    var height: CGFloat = 5
    var innerHeight: CGFloat = 3

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let elapsedWidth = width * weeklyElapsedProgress
            let usageWidth = width * PercentFormatter.progress(from: weeklyPercent)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(PeluTheme.sky.opacity(colorScheme == .dark ? 0.10 : 0.08))
                    .frame(height: height)
                Capsule()
                    .fill(PeluTheme.sky.opacity(colorScheme == .dark ? 0.34 : 0.24))
                    .frame(width: elapsedWidth, height: height)
                Capsule()
                    .strokeBorder(PeluTheme.sky.opacity(colorScheme == .dark ? 0.32 : 0.22), lineWidth: 1)
                    .frame(height: height)

                Capsule()
                    .fill(.secondary.opacity(colorScheme == .dark ? 0.22 : 0.12))
                    .frame(height: innerHeight)
                Capsule()
                    .fill(.secondary.opacity(colorScheme == .dark ? 0.65 : 0.48))
                    .frame(width: usageWidth, height: innerHeight)
            }
            .frame(height: height)
        }
        .frame(height: height)
    }

    private var weeklyElapsedProgress: Double {
        if let weeklyResetDate {
            let weekDuration: TimeInterval = 7 * 24 * 60 * 60
            let startDate = weeklyResetDate.addingTimeInterval(-weekDuration)
            return clamped(Date().timeIntervalSince(startDate) / weekDuration)
        }

        let now = Date()
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: now) else {
            return 0
        }
        return clamped(now.timeIntervalSince(week.start) / week.duration)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private struct ProviderRow: View {
    let metric: UsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                Image(metric.provider.assetName)
                    .resizable()
                    .scaledToFit()
                    .padding(metric.provider == .codex ? 3 : 0)
                    .frame(width: 16, height: 16)

                Text(metric.provider.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(PercentFormatter.string(from: metric.usedPercent))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule()
                        .fill(metric.status.tintColor)
                        .frame(width: geo.size.width * PercentFormatter.progress(from: metric.usedPercent))
                }
            }
            .frame(height: 5)

            if let weekly = metric.weeklyPercent {
                HStack(spacing: 4) {
                    Text("Weekly")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    WeeklyCycleBar(
                        weeklyPercent: weekly,
                        weeklyResetDate: metric.weeklyResetDate
                    )
                    Text(PercentFormatter.string(from: weekly))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 36, alignment: .trailing)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }
}

private struct SmallWidgetView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image("PeluLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                Text("Pelu")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                Spacer()
                Circle()
                    .fill(snapshot.source == .demo ? Color.secondary : Color.green)
                    .frame(width: 6, height: 6)
            }

            VStack(spacing: 8) {
                ForEach(snapshot.metrics) { metric in
                    ProviderRow(metric: metric)
                }
            }

            Spacer(minLength: 0)

            Text(UpdatedAtFormatter.string(from: snapshot.generatedAt))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
    }
}

private struct MediumWidgetView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image("PeluLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                Text("Pelu")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(UpdatedAtFormatter.string(from: snapshot.generatedAt))
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Circle()
                    .fill(snapshot.source == .demo ? Color.secondary : Color.green)
                    .frame(width: 5, height: 5)
            }

            // Provider rows — 滿版單欄
            VStack(spacing: 8) {
                ForEach(snapshot.metrics) { metric in
                    MediumProviderRow(metric: metric)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

private struct MediumProviderRow: View {
    let metric: UsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 6) {
                Image(metric.provider.assetName)
                    .resizable()
                    .scaledToFit()
                    .padding(metric.provider == .codex ? 2 : 0)
                    .frame(width: 14, height: 14)
                Text(metric.provider.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(PercentFormatter.string(from: metric.usedPercent))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(metric.status.tintColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule()
                        .fill(metric.status.tintColor)
                        .frame(width: geo.size.width * PercentFormatter.progress(from: metric.usedPercent))
                }
            }
            .frame(height: 5)

            HStack(spacing: 6) {
                if let weekly = metric.weeklyPercent {
                    Text("Weekly")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    WeeklyCycleBar(
                        weeklyPercent: weekly,
                        weeklyResetDate: metric.weeklyResetDate
                    )
                    Text(PercentFormatter.string(from: weekly))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 38, alignment: .trailing)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if metric.weeklyPercent != nil && metric.resetDate != nil {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if let reset = metric.resetDate {
                    Text(ResetTimeFormatter.string(from: reset))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
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
