import Charts
import PeluCore
import PeluUI
import SwiftUI

/// Casual "how much AI compute have I racked up" overview.
/// One hero stat + a bar chart, no per-row clutter.
struct PeluHistoryScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var history = UsageHistory()
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if dailyTotals.isEmpty {
                    emptyState
                } else {
                    content
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

    // MARK: - Derived data

    private struct DailyTotal: Identifiable {
        let date: Date
        let costUSD: Decimal
        var id: Date { date }
        var costDouble: Double { NSDecimalNumber(decimal: costUSD).doubleValue }
    }

    private var dailyTotals: [DailyTotal] {
        // Ascending by date so the chart reads left-to-right oldest → newest.
        history.entries
            .compactMap { entry in
                let total = entry.macs.reduce(into: Decimal(0)) { sum, mac in
                    for metric in mac.snapshot.metrics {
                        if let cost = metric.costTodayUSD { sum += cost }
                    }
                }
                guard total > 0 else { return nil }
                return DailyTotal(date: entry.date, costUSD: total)
            }
            .sorted { $0.date < $1.date }
    }

    private var totalCost: Decimal {
        dailyTotals.reduce(Decimal(0)) { $0 + $1.costUSD }
    }

    private var averageDaily: Decimal {
        guard !dailyTotals.isEmpty else { return 0 }
        return totalCost / Decimal(dailyTotals.count)
    }

    private var peakCost: Decimal {
        dailyTotals.map(\.costUSD).max() ?? 0
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(spacing: 24) {
                heroBlock
                chartBlock
                footerNote
            }
            .padding(20)
        }
    }

    private var heroBlock: some View {
        VStack(spacing: 6) {
            Text(formatCost(totalCost))
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
            Text("最近 \(dailyTotals.count) 天估算")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 24) {
                statTile(label: "平均每天", value: formatCost(averageDaily))
                statTile(label: "最高一天", value: formatCost(peakCost))
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func statTile(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var chartBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("每日花費")
                .font(.headline)
            Chart(dailyTotals) { day in
                BarMark(
                    x: .value("日期", day.date, unit: .day),
                    y: .value("花費", day.costDouble)
                )
                .foregroundStyle(PeluTheme.primaryText(for: colorScheme).opacity(0.85))
                .cornerRadius(3)
            }
            .frame(height: 200)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: chartStride)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day(.defaultDigits))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text("$\(Int(amount))")
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    /// Pick a sensible x-axis stride so labels don't overlap on a small screen.
    private var chartStride: Int {
        switch dailyTotals.count {
        case ..<8:   return 1
        case ..<15:  return 2
        case ..<22:  return 3
        default:     return 5
        }
    }

    private var footerNote: some View {
        Text("數字依 API 定價推算「運算等值花費」。Pro / Max / Team 訂閱用戶的月費是固定的，這裡只是讓你看見自己實際消耗的運算量。")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("還沒有花費紀錄")
                .font(.title3.weight(.semibold))
            Text("每天的 AI 花費會在這支 iPhone 同步資料時自動記錄。先在 Mac 跑一陣子 Claude Code，明天回來看你花了多少。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .lineSpacing(4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatCost(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "$\(value)"
    }
}

#Preview {
    PeluHistoryScreen()
}
