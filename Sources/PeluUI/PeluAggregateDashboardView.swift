import PeluCore
import SwiftUI

/// iOS dashboard. Renders one Claude card + one Codex card built from
/// `AggregateSnapshot.displaySnapshot` — Claude shows the highest reported
/// use while account-wide Codex quota shows its newest measurement.
/// Disconnect (>5 min stale) is surfaced via the StatusPill turning red.
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
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    greetingHero
                    header
                }

                TimelineView(.everyMinute) { context in
                    if let display = aggregate.displaySnapshot(at: context.date) {
                        VStack(spacing: 12) {
                            ForEach(display.metrics) { metric in
                                UsageMetricCard(metric: metric)
                            }
                        }
                    } else {
                        emptyState
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
    /// Set in 思源宋體 (Source Han Serif TC Bold) — Adobe / Google OFL serif
    /// with full traditional Chinese coverage. Bold weight reads strong as a
    /// hero without needing extra weight modifiers.
    private var greetingHero: some View {
        TimelineView(.everyMinute) { context in
            Text(Greeting.text(for: context.date, usedPercent: busiestUsedPercent(at: context.date)))
                .font(.custom("SourceHanSerifTC-Bold", size: 26, relativeTo: .title))
                .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }
    }

    /// Highest displayed primary-window usage. Use the same composite metrics as the
    /// cards, so a stale Codex record cannot contradict a newer reset below.
    private func busiestUsedPercent(at now: Date) -> Double? {
        aggregate.displaySnapshot(at: now)?.metrics.compactMap(\.usedPercent).max()
    }

    /// 5 分鐘沒新資料就視為斷線。TimelineView 每分鐘 tick 一次，所以即使
    /// CloudKit silent push 沒回來，UI 也會自動切到斷線狀態。
    private static let disconnectThreshold: TimeInterval = 5 * 60

    private var header: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let newest = aggregate.newestGeneratedAt
            let disconnected: Bool = {
                guard let newest else { return !aggregate.macs.isEmpty }
                return now.timeIntervalSince(newest) > Self.disconnectThreshold
            }()

            HStack {
                Group {
                    if let newest {
                        let busiest = busiestUsedPercent(at: now).map { "最高 \(Int($0.rounded()))% · " } ?? ""
                        if disconnected {
                            Text("\(busiest)\(UpdatedAtFormatter.relativeString(from: newest, now: now))更新")
                                .foregroundStyle(Color.red)
                        } else {
                            Text("\(busiest)\(UpdatedAtFormatter.string(from: newest, now: now)) 更新")
                        }
                    } else {
                        Text("尚未收到資料")
                    }
                }
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
                Spacer()
                StatusPill(
                    source: aggregate.displaySnapshot(at: now)?.source ?? .demo,
                    isDisconnected: disconnected
                )
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
