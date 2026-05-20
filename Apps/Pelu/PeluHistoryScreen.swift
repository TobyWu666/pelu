import PeluCore
import PeluUI
import SwiftUI

/// Local history view — shows up to the last 30 days of recorded usage.
/// Data is captured from each cloud fetch (see UsageSurfaceUpdater).
struct PeluHistoryScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var history = UsageHistory()
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if history.entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("歷史")
            .task { await load() }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let store = UsageHistoryStore() else { return }
        history = (try? store.load()) ?? UsageHistory()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("還沒有歷史紀錄")
                .font(.title3.weight(.semibold))
            Text("每天的用量會在這支 iPhone 同步資料時自動記錄。先在 Mac 跑一陣子 Claude Code 或 Codex，明天回來看。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .lineSpacing(4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(history.entries) { entry in
                Section(header: headerView(for: entry.date)) {
                    if entry.macs.isEmpty {
                        Text("無資料")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entry.macs) { mac in
                            macBlock(mac)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func headerView(for date: Date) -> some View {
        HStack {
            Text(date, format: .dateTime.month().day())
                .font(.headline)
            Text(date, format: .dateTime.weekday(.wide))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func macBlock(_ mac: MacSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Mac label only when there's more than one — single Mac users
            // don't need to see their own machine name on every row.
            if history.entries.contains(where: { $0.macs.count > 1 }) {
                Text(mac.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(mac.snapshot.metrics) { metric in
                metricRow(metric)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func metricRow(_ metric: UsageMetric) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(metric.provider.assetName)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
            Text(metric.provider.displayName)
                .font(.callout.weight(.medium))
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let used = metric.usedPercent {
                    Text("5h \(Int(used.rounded()))%")
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
                HStack(spacing: 8) {
                    if let weekly = metric.weeklyPercent {
                        Text("週 \(Int(weekly.rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if let cost = metric.costTodayUSD {
                        Text("$\(formattedCost(cost))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func formattedCost(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        formatter.numberStyle = .decimal
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }
}

#Preview {
    PeluHistoryScreen()
}
