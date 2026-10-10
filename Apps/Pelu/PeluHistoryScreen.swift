import Charts
import PeluCore
import PeluUI
import SwiftUI

/// Casual "how much AI compute have I racked up" overview.
/// One hero stat + a bar chart, no per-row clutter.
struct PeluHistoryScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
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
            .navigationTitle("歷史")
            .task { await initialLoad() }
            .onChange(of: scenePhase) { _, phase in
                // 回到前景就抓最新一筆，免得切回 app 看到的是昨天的數字。
                if phase == .active {
                    Task { await refreshFromCloud() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .peluUsageDidUpdate)) { _ in
                // Dashboard 的 5 分鐘 timer / silent push / 手動 refresh 跑完都會 post，
                // 即使歷史頁是背景 tab 也能保持資料新鮮。
                reloadLocal()
            }
        }
    }

    @MainActor
    private func initialLoad() async {
        reloadLocal()
        isLoading = false
        await refreshFromCloud()
    }

    /// 主動拉一次 CloudKit。fetch 成功時 UsageSurfaceUpdater 會 post
    /// `.peluUsageDidUpdate`，由上面的 onReceive 重讀本地檔；失敗就靜默忽略，
    /// 既有顯示的數字不會被清掉。
    @MainActor
    private func refreshFromCloud() async {
        _ = try? await UsageSurfaceUpdater.fetchFromCloud(updateLiveActivity: false)
    }

    private func reloadLocal() {
        guard let store = UsageHistoryStore() else { return }
        history = (try? store.load()) ?? UsageHistory()
    }

    // MARK: - Derived data

    private struct DailyTotal: Identifiable {
        let date: Date
        let claudeUSD: Decimal
        let codexUSD: Decimal
        var id: Date { date }
        var totalUSD: Decimal { claudeUSD + codexUSD }
    }

    /// Per-day cost expressed as the *delta* from the previous recorded day,
    /// per (Mac × provider). Claude Code's `cost.total_cost_usd` is session-
    /// cumulative — a session that started yesterday still reports yesterday's
    /// spending in today's snapshot, so summing the raw value double-counts.
    /// Computing the day-over-day delta strips that out.
    ///
    /// Codex 走相同邏輯，但「累積值」是把 `tokenUsage` 丟進
    /// `CodexPricing.estimateUSD` 算出來的等值美金 — RPC 不給 token 數，
    /// 所以這條路徑只有 PeluMac v1.0.7+ 寫入的 snapshot 才會有 Codex 花費。
    ///
    /// 多 Mac 註記：dashboard / widget / Live Activity 走 displaySnapshot
    /// （per-provider 取最高），歷史頁刻意走完整 aggregate.macs，因為花費
    /// 是真實金額、跨 Mac 應該加總，不能因為「首頁只顯示最高那台」而漏記
    /// 其他 Mac 的開銷。刪除某台 Mac 後當天 entry 會在下次 fetch 被覆寫
    /// 成不含該 Mac 的版本，過去的 entry 不動（歷史是過去事實）。
    ///
    /// When the cost number *drops* between recorded days (a new session
    /// started), we treat the current day's full value as that day's spend.
    /// We can't recover any earlier sessions that finished within the same
    /// day — that nuance is gone by the time we snapshot.
    private var dailyTotals: [DailyTotal] {
        let sorted = history.entries.sorted { $0.date < $1.date }
        var prevByKey: [String: Decimal] = [:]
        var result: [DailyTotal] = []
        let today = Calendar.current.startOfDay(for: Date())

        for entry in sorted {
            var claudeDay: Decimal = 0
            var codexDay: Decimal = 0
            var observed: Set<ProviderKind> = []
            for mac in entry.macs {
                for metric in mac.snapshot.metrics {
                    guard let cur = cumulativeUSD(for: metric) else { continue }
                    observed.insert(metric.provider)
                    let key = "\(mac.macId)|\(metric.provider.rawValue)"
                    let prev = prevByKey[key] ?? 0
                    // Cost decreased → session reset → today's value is the
                    // new session's running total. Cost grew → delta is the
                    // additional spend since last record. Equal → either no
                    // new work or stale data; the per-day fallback below
                    // catches the "today" case where we'd rather show the
                    // running cumulative than a misleading $0.
                    let delta: Decimal = cur < prev ? cur : (cur - prev)
                    switch metric.provider {
                    case .claudeCode: claudeDay += delta
                    case .codex:      codexDay += delta
                    case .cursor:     break
                    }
                    prevByKey[key] = cur
                }
            }

            let isToday = Calendar.current.isDate(entry.date, inSameDayAs: today)

            // Fallback for today: when the delta math collapses to 0 but the
            // current snapshot still has a positive cumulative, show that.
            // Better to display the active session's running cost than to
            // pretend today had no spend. Applied per-provider so a fresh
            // Codex session doesn't get shadowed by a stable Claude line.
            if isToday {
                if claudeDay == 0 && observed.contains(.claudeCode) {
                    claudeDay = entry.macs.reduce(Decimal(0)) { acc, mac in
                        acc + mac.snapshot.metrics
                            .filter { $0.provider == .claudeCode }
                            .reduce(Decimal(0)) { inner, m in inner + (m.costTodayUSD ?? 0) }
                    }
                }
                if codexDay == 0 && observed.contains(.codex) {
                    codexDay = entry.macs.reduce(Decimal(0)) { acc, mac in
                        acc + mac.snapshot.metrics
                            .filter { $0.provider == .codex }
                            .reduce(Decimal(0)) { inner, m in
                                inner + (m.tokenUsage.map(CodexPricing.estimateUSD(for:)) ?? 0)
                            }
                    }
                }
            }

            // Keep today on the chart even when it sums to 0 so the bar
            // doesn't silently disappear — users read missing bars as "Pelu
            // is broken" instead of "no spend yet".
            if (claudeDay + codexDay) > 0 || isToday {
                result.append(DailyTotal(date: entry.date, claudeUSD: claudeDay, codexUSD: codexDay))
            }
        }
        return result
    }

    /// Unified running-cumulative USD for the delta math. Claude reads
    /// directly from `cost.total_cost_usd`; Codex derives from
    /// `tokenUsage` (sum across active sessions) via `CodexPricing`.
    private func cumulativeUSD(for metric: UsageMetric) -> Decimal? {
        switch metric.provider {
        case .claudeCode:
            return metric.costTodayUSD
        case .codex:
            guard let tokens = metric.tokenUsage else { return nil }
            return CodexPricing.estimateUSD(for: tokens)
        case .cursor:
            return nil
        }
    }

    private var totalClaude: Decimal { dailyTotals.reduce(Decimal(0)) { $0 + $1.claudeUSD } }
    private var totalCodex: Decimal { dailyTotals.reduce(Decimal(0)) { $0 + $1.codexUSD } }
    private var totalCost: Decimal { totalClaude + totalCodex }

    private var averageDaily: Decimal {
        guard !dailyTotals.isEmpty else { return 0 }
        return totalCost / Decimal(dailyTotals.count)
    }

    private var peakCost: Decimal {
        dailyTotals.map(\.totalUSD).max() ?? 0
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
        .refreshable { await refreshFromCloud() }
    }

    private var heroBlock: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(formatCost(totalCost))
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Text("最近 \(dailyTotals.count) 天估算")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                providerBreakdown
            }

            Divider().opacity(0.4)

            HStack(spacing: 0) {
                statTile(label: "平均每天", value: formatCost(averageDaily))
                statTile(label: "最高一天", value: formatCost(peakCost))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    /// 兩列右靠的分項表 — `Grid` 讓 label 欄與數值欄各自對齊，避免
    /// "≈$0.00" 與 "$338.05" 寬度不同時左緣參差不齊。
    private var providerBreakdown: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                providerLabel("Claude", color: claudeColor)
                Text(formatCost(totalClaude))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
                    .gridColumnAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            GridRow {
                providerLabel("Codex", color: codexColor)
                Text("≈\(formatCost(totalCodex))")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PeluTheme.primaryText(for: colorScheme))
                    .gridColumnAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private func providerLabel(_ name: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statTile(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Chart palette. Kept as computed properties so the chip dots, bar
    /// segments, and legend swatches stay in lockstep.
    private var claudeColor: Color { PeluTheme.brandTeal(for: colorScheme) }
    private var codexColor: Color { PeluTheme.amber }

    private var chartBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("每日花費")
                .font(.headline)
            Chart {
                ForEach(dailyTotals) { day in
                    BarMark(
                        x: .value("日期", day.date, unit: .day),
                        y: .value("花費", NSDecimalNumber(decimal: day.claudeUSD).doubleValue)
                    )
                    .foregroundStyle(by: .value("provider", "Claude"))
                    .cornerRadius(3)

                    BarMark(
                        x: .value("日期", day.date, unit: .day),
                        y: .value("花費", NSDecimalNumber(decimal: day.codexUSD).doubleValue)
                    )
                    .foregroundStyle(by: .value("provider", "Codex"))
                    .cornerRadius(3)
                }
            }
            .chartForegroundStyleScale([
                "Claude": claudeColor,
                "Codex": codexColor,
            ])
            .chartLegend(.hidden)  // chips above cover the same info
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude 讀官方 `cost.total_cost_usd`；Codex 以 gpt-5-codex API 定價估算（input $1.25/M、cached $0.125/M、output $10/M，含 reasoning）。")
            Text("Plus / Pro / Team 訂閱月費固定，數字僅反映實際消耗的運算量。")
        }
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
            Text("每天的 AI 花費會在這支 iPhone 同步資料時自動記錄。先在 Mac 跑一陣子 Claude Code 或 Codex，明天回來看你花了多少。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .lineSpacing(4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 統一的金額格式 — 用 "$" 而非 locale-dependent 的 "US$"，與 hero / chart
    /// 軸的 "$N" 風格一致。`numberStyle = .currency` 在 zh-TW 會給 "US$"，
    /// hero chip 會被擠到斷行，所以這裡用 decimal style 手動補前綴。
    private func formatCost(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        let body = formatter.string(from: value as NSDecimalNumber) ?? String(describing: value)
        return "$\(body)"
    }
}

#Preview {
    PeluHistoryScreen()
}
