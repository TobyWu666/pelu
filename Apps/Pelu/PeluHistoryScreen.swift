import PeluCore
import PeluUI
import SwiftUI

/// Casual "how much have I spent on AI" overview. Numbers are inherently rough
/// — Claude Code's `cost.total_cost_usd` is session-scoped, not strictly daily —
/// so the UI explicitly frames everything as **estimates**.
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
                } else if dailyTotals.isEmpty {
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

    // MARK: - Derived data

    private struct DailyTotal: Identifiable {
        let date: Date
        let costUSD: Decimal
        var id: Date { date }
    }

    /// One number per day across all Macs / providers. Days with no cost data
    /// are skipped — they'd just clutter the list.
    private var dailyTotals: [DailyTotal] {
        history.entries.compactMap { entry in
            let total = entry.macs.reduce(into: Decimal(0)) { sum, mac in
                for metric in mac.snapshot.metrics {
                    if let cost = metric.costTodayUSD { sum += cost }
                }
            }
            guard total > 0 else { return nil }
            return DailyTotal(date: entry.date, costUSD: total)
        }
    }

    private var totalCost: Decimal {
        dailyTotals.reduce(Decimal(0)) { $0 + $1.costUSD }
    }

    private var averageDaily: Decimal {
        guard !dailyTotals.isEmpty else { return 0 }
        return totalCost / Decimal(dailyTotals.count)
    }

    // MARK: - List + hero

    private var list: some View {
        List {
            heroSection
            daysSection
        }
        .listStyle(.insetGrouped)
    }

    private var heroSection: some View {
        Section {
            VStack(spacing: 8) {
                Text(formatCost(totalCost, fractionDigits: 2))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
                Text("最近 \(dailyTotals.count) 天估算")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.caption2)
                    Text("平均每天 \(formatCost(averageDaily, fractionDigits: 2))")
                        .font(.caption)
                }
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } footer: {
            Text("數字根據 Claude Code 與 Codex 在 session 內的累計 cost 估算，僅供參考。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var daysSection: some View {
        Section("每天") {
            ForEach(dailyTotals) { day in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day.date, format: .dateTime.month().day())
                            .font(.body.weight(.semibold))
                        Text(day.date, format: .dateTime.weekday(.wide))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatCost(day.costUSD, fractionDigits: 2))
                        .font(.body.monospacedDigit().weight(.medium))
                    Text(emoji(for: day.costUSD))
                        .font(.title3)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "creditcard.and.123")
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

    // MARK: - Helpers

    private func formatCost(_ value: Decimal, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = fractionDigits
        formatter.minimumFractionDigits = fractionDigits
        return formatter.string(from: value as NSDecimalNumber) ?? "$\(value)"
    }

    /// Casual visual indicator. Brackets chosen by feel — adjust if user
    /// feedback says "$5 isn't 🔥 in my world".
    private func emoji(for cost: Decimal) -> String {
        switch cost {
        case ..<1:    return "☕"   // 輕鬆一天
        case 1..<5:   return "💪"   // 標準輸出
        case 5..<15:  return "🔥"   // 認真工作
        case 15..<30: return "🚀"   // 全力以赴
        default:      return "🤯"   // 燒錢日
        }
    }
}

#Preview {
    PeluHistoryScreen()
}
