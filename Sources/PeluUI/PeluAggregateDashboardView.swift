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

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let newest = aggregate.newestGeneratedAt {
                    Text("最後更新 \(UpdatedAtFormatter.string(from: newest))")
                        .font(.subheadline)
                        .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
                } else {
                    Text("尚未收到資料")
                        .font(.subheadline)
                        .foregroundStyle(PeluTheme.tertiaryText(for: colorScheme))
                }
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
