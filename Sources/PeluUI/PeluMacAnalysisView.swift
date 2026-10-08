#if os(macOS)
import Charts
import PeluCore
import SwiftUI

public struct PeluMacAnalysisView: View {
    private let snapshot: UsageSnapshot
    private let history: MacUsageHistory
    private let historyError: String?
    @State private var provider = ProviderKind.codex
    @State private var days = 1
    @State private var secondary = false
    @State private var selectedDate: Date?

    public init(snapshot: UsageSnapshot, history: MacUsageHistory, historyError: String? = nil) {
        self.snapshot = snapshot
        self.history = history
        self.historyError = historyError
    }

    public var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            content(now: context.date)
        }
        .frame(minWidth: 700, minHeight: 600)
        .background(.background)
    }

    private func content(now: Date) -> some View {
        let metric = snapshot.metric(for: provider)?.effective(at: now)
        let start = now.addingTimeInterval(-Double(days) * 86400)
        let points = history.points(provider: provider, secondary: secondary, since: start)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("用量分析").font(.system(size: 28, weight: .semibold))
                        Text("掌握額度變化與本機使用概況").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("服務", selection: $provider) {
                        Text("Claude Code").tag(ProviderKind.claudeCode)
                        Text("Codex").tag(ProviderKind.codex)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                }
                HStack(spacing: 16) {
                    summary("目前已用", value: PercentFormatter.string(from: secondary ? metric?.weeklyPercent : metric?.usedPercent))
                    summary("額度重置", value: (secondary ? metric?.weeklyResetDate : metric?.resetDate).map { ResetTimeFormatter.string(from: $0, now: now) } ?? "尚無資料")
                    summary("最近測量", value: metric?.measuredAt.map { UpdatedAtFormatter.relativeString(from: $0, now: now) } ?? "尚無資料")
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("配額使用趨勢").font(.headline)
                        Spacer()
                        Picker("歷史範圍", selection: $days) {
                            Text("24 小時").tag(1)
                            Text("7 天").tag(7)
                            Text("30 天").tag(30)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 230)
                    }
                    Picker("額度週期", selection: $secondary) {
                        Text("主要週期" + (metric.map { " · " + UsageMetric.windowLabel(durationMins: $0.resolvedPrimaryWindowDurationMins) } ?? "")).tag(false)
                        Text("次要週期" + (metric.map { " · " + UsageMetric.windowLabel(durationMins: $0.resolvedSecondaryWindowDurationMins) } ?? "")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    if points.isEmpty {
                        ContentUnavailableView("尚無歷史資料", systemImage: "chart.xyaxis.line", description: Text("Pelu 開啟後會自動記錄新測量。資料會保留在這台 Mac，最多 30 天。"))
                            .frame(height: 240)
                    } else {
                        Chart {
                            ForEach(points) { point in
                                LineMark(x: .value("時間", point.date), y: .value("已用 %", point.percent), series: .value("區段", point.segment))
                                    .foregroundStyle(PeluTheme.teal)
                                    .interpolationMethod(.linear)
                                // Dots only help on sparse ranges; on dense ones they hide the line.
                                if points.count <= 300 {
                                    PointMark(x: .value("時間", point.date), y: .value("已用 %", point.percent))
                                        .foregroundStyle(PeluTheme.teal)
                                        .symbolSize(12)
                                }
                            }
                            if let selectedDate, let point = points.min(by: { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }) {
                                RuleMark(x: .value("選取時間", point.date))
                                    .foregroundStyle(.secondary)
                                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                        Text("\(point.date.formatted(date: .abbreviated, time: .shortened)) · \(PercentFormatter.string(from: point.percent))")
                                            .font(.caption.monospacedDigit())
                                            .padding(6)
                                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                    }
                            }
                        }
                        .chartYScale(domain: 0...100)
                        .chartXScale(domain: start...now)
                        .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                            AxisGridLine()
                            AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%") } }
                        } }
                        .chartXSelection(value: $selectedDate)
                        .chartOverlay { proxy in
                            GeometryReader { geometry in
                                Color.clear
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active(let location):
                                            if let frame = proxy.plotFrame {
                                                selectedDate = proxy.value(atX: location.x - geometry[frame].minX)
                                            }
                                        case .ended: selectedDate = nil
                                        }
                                    }
                            }
                        }
                        .frame(height: 240)
                        .padding(.top, 20)
                        .onContinuousHover { phase in
                            if case .ended = phase { selectedDate = nil }
                        }
                    }
                    Text("\(points.count) 筆測量 · 重置、來源切換或超過 5 分鐘未更新時斷線；數值為當時額度使用比例。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let historyError {
                        Label(historyError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(20)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                if provider == .codex {
                    tokenPanel(metric?.tokenUsage)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("工作階段").font(.headline)
                        LabeledContent("Context 已用", value: PercentFormatter.string(from: metric?.contextWindowPercent))
                        Text("此值反映來源回報的目前工作階段，不代表帳號配額。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(28)
        }
        .onChange(of: provider) { _, _ in selectedDate = nil }
        .onChange(of: days) { _, _ in selectedDate = nil }
        .onChange(of: secondary) { _, _ in selectedDate = nil }
    }

    private func summary(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private func tokenPanel(_ usage: CodexTokenUsage?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Token 組成").font(.headline)
            if let usage, !usage.isEmpty {
                let parts = [TokenPart(name: "未快取輸入", count: usage.inputTokens - usage.cachedInputTokens), TokenPart(name: "快取輸入", count: usage.cachedInputTokens), TokenPart(name: "輸出", count: usage.outputTokens)]
                Chart(parts) { part in
                    BarMark(x: .value("Token", part.count), y: .value("組成", "Token"))
                        .foregroundStyle(by: .value("類型", part.name))
                }
                .chartForegroundStyleScale(["未快取輸入": PeluTheme.teal, "快取輸入": PeluTheme.sky, "輸出": PeluTheme.amber])
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let count = value.as(Int.self) {
                                Text(count.formatted(.number.notation(.compactName)))
                            }
                        }
                    }
                }
                .frame(height: 85)
                HStack {
                    ForEach(parts) { part in
                        LabeledContent(part.name, value: part.count.formatted())
                        if part.name != "輸出" { Divider() }
                    }
                }
                .font(.caption.monospacedDigit())
            } else {
                Text("尚無可用的 Token 紀錄").foregroundStyle(.secondary)
            }
            Text("統計最近 24 小時有更新的本機工作階段累計 Token，並非今日新增量；快取輸入已從一般輸入中扣除。此區不隨上方配額時間範圍切換。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct TokenPart: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}
#endif
