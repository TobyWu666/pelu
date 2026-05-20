import PeluCore
import SwiftUI

/// iOS multi-Mac dashboard. Each Mac gets a section with the Mac's name plus its
/// own Claude Code + Codex cards. Single-Mac case looks essentially the same as
/// the legacy single-snapshot dashboard (no extra chrome to clutter).
public struct PeluAggregateDashboardView: View {
    @Environment(\.colorScheme) private var colorScheme

    private let aggregate: AggregateSnapshot
    private let refreshAction: (() async -> Void)?

    public init(aggregate: AggregateSnapshot, refreshAction: (() async -> Void)? = nil) {
        self.aggregate = aggregate
        self.refreshAction = refreshAction
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                greetingHero
                header

                if aggregate.macs.isEmpty {
                    emptyState
                } else {
                    ForEach(aggregate.macs) { mac in
                        macSection(mac)
                    }
                }
            }
            .padding(20)
        }
        .background(PeluTheme.background(for: colorScheme))
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 104)
        }
        .if(refreshAction != nil) { view in
            view.refreshable { await refreshAction?() }
        }
    }

    /// Hero greeting at the top of the dashboard. Refreshes itself every minute
    /// via TimelineView so the time-of-day wording stays accurate even if the
    /// user keeps the app open across a boundary (e.g. 17:59 → 18:00).
    ///
    /// Set in 全字庫正宋體 (TW-Sung) — a free Taiwanese government typeface that
    /// covers full traditional Chinese. Latin glyphs in Pelu's greetings are minimal
    /// (just punctuation / digits), so we don't need a Latin fallback.
    private var greetingHero: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text(Greeting.text(for: context.date, usedPercent: busiestUsedPercent))
                    .font(.custom("TW-Sung-98_1", size: 28, relativeTo: .title))
                    .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subheading)
                    .font(.subheadline)
                    .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    /// Highest 5h used% across all Macs / providers — the "how busy are you
    /// right now" signal that drives the greeting tone.
    private var busiestUsedPercent: Double? {
        let allUsed = aggregate.macs.flatMap { $0.snapshot.metrics.compactMap(\.usedPercent) }
        return allUsed.max()
    }

    private var subheading: String {
        guard let percent = busiestUsedPercent else { return "尚無資料" }
        return "目前最高 5 小時用量 \(Int(percent.rounded()))%"
    }

    private var header: some View {
        HStack {
            if let newest = aggregate.newestGeneratedAt {
                Text("最後更新 \(UpdatedAtFormatter.string(from: newest))")
                    .font(.subheadline)
                    .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
            } else {
                Text("尚未收到資料")
                    .font(.subheadline)
                    .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
            }
            Spacer()
            // Pick the freshest Mac's source for the pill — they're all .cloud in practice.
            StatusPill(source: aggregate.primary?.snapshot.source ?? .demo)
        }
    }

    @ViewBuilder
    private func macSection(_ mac: MacSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
                Text(mac.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
                Spacer()
                Text(UpdatedAtFormatter.string(from: mac.snapshot.generatedAt))
                    .font(.caption2)
                    .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
            }

            ForEach(mac.snapshot.metrics) { metric in
                UsageMetricCard(metric: metric)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("沒有任何 Mac 在上傳")
                .font(.headline)
            Text("到 Mac 開啟 Pelu，並用 menu bar 的「配對 iPhone」按鈕完成配對。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    PeluAggregateDashboardView(aggregate: .demo())
}

#Preview("Two Macs") {
    PeluAggregateDashboardView(aggregate: AggregateSnapshot(macs: [
        MacSnapshot(macId: "a", label: "Toby's MacBook Pro", snapshot: .demo()),
        MacSnapshot(macId: "b", label: "Studio", snapshot: .demo())
    ]))
}
