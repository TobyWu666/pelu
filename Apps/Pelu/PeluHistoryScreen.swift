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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PeluTheme.background(for: colorScheme))
            .scrollContentBackground(.hidden)
            .navigationTitle("用量歷史")
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

    /// Per-day cost expressed as the *delta* from the previous recorded day,
    /// per (Mac × provider). Claude Code's `cost.total_cost_usd` is session-
    /// cumulative — a session that started yesterday still reports yesterday's
    /// spending in today's snapshot, so summing the raw value double-counts.
    /// Computing the day-over-day delta strips that out.
    ///
    /// When the cost number *drops* between recorded days (a new session
    /// started), we treat the current day's full value as that day's spend.
    /// We can't recover any earlier sessions that finished within the same
    /// day — that nuance is gone by the time we snapshot.
    private var dailyTotals: [DailyTotal] {
        let sorted = history.entries.sorted { $0.date < $1.date }
        var prevByKey: [String: Decimal] = [:]
        var result: [DailyTotal] = []

        for entry in sorted {
            var dayTotal: Decimal = 0
            for mac in entry.macs {
                for metric in mac.snapshot.metrics {
                    guard let cur = metric.costTodayUSD else { continue }
                    let key = "\(mac.macId)|\(metric.provider.rawValue)"
                    let prev = prevByKey[key] ?? 0
                    // Cost decreased → session reset → today's value is the
                    // new session's running total. Cost grew or stayed flat →
                    // delta is the additional spend since last record.
                    let delta: Decimal = cur < prev ? cur : (cur - prev)
                    dayTotal += delta
                    prevByKey[key] = cur
                }
            }
            if dayTotal > 0 {
                result.append(DailyTotal(date: entry.date, costUSD: dayTotal))
            }
        }
        return result
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
