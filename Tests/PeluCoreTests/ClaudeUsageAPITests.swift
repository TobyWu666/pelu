import Foundation
import Testing
@testable import PeluCore

private let usageResponse = """
{
  "five_hour": { "utilization": 13.0, "resets_at": "2026-10-08T11:00:00.256519+00:00" },
  "seven_day": { "utilization": 9.0, "resets_at": "2026-10-09T17:00:00.256539+00:00" },
  "seven_day_opus": null,
  "iguana_necktie": { "utilization": 0.0, "resets_at": "2026-11-05T07:59:00+00:00" }
}
""".data(using: .utf8)!

@Test func claudeUsageAPIParsesOAuthUsageResponse() throws {
    let fetchedAt = Date(timeIntervalSince1970: 1791449600)  // 2026-10-08 06:53Z
    let metric = try ClaudeUsageAPIParser().parse(data: usageResponse, fetchedAt: fetchedAt, generatedAt: fetchedAt)

    #expect(metric.provider == .claudeCode)
    #expect(metric.usedPercent == 13)
    #expect(metric.weeklyPercent == 9)
    #expect(metric.dataSource == .officialQuota)
    #expect(metric.measuredAt == fetchedAt)
    #expect(metric.resolvedPrimaryWindowDurationMins == 300)
    #expect(abs(metric.resetDate!.timeIntervalSince1970 - 1791457200.256) < 0.01)
    #expect(abs(metric.weeklyResetDate!.timeIntervalSince1970 - 1791565200.256) < 0.01)
}

@Test func claudeUsageAPIZeroesWindowAfterReset() throws {
    let fetchedAt = Date(timeIntervalSince1970: 1791449600)
    let afterFiveHourReset = Date(timeIntervalSince1970: 1791457300)
    let metric = try ClaudeUsageAPIParser().parse(data: usageResponse, fetchedAt: fetchedAt, generatedAt: afterFiveHourReset)

    #expect(metric.usedPercent == 0)
    #expect(metric.weeklyPercent == 9)
}

@Test func claudeUsageMergePrefersNewerReadingAndKeepsHookContext() throws {
    let apiAt = Date(timeIntervalSince1970: 1791449600)
    let api = try ClaudeUsageAPIParser().parse(data: usageResponse, fetchedAt: apiAt, generatedAt: apiAt)
    let staleHook = UsageMetric(
        provider: .claudeCode, usedPercent: 5, weeklyPercent: 7, contextWindowPercent: 9,
        costTodayUSD: 1.4, dataSource: .officialQuota, measuredAt: apiAt.addingTimeInterval(-2 * 86400)
    )
    let merged = ClaudeUsageAPIParser.merge(api: api, hook: staleHook)
    #expect(merged.usedPercent == 13)
    #expect(merged.contextWindowPercent == 9)
    #expect(merged.measuredAt == apiAt)

    let freshHook = UsageMetric(
        provider: .claudeCode, usedPercent: 14, weeklyPercent: 9,
        dataSource: .officialQuota, measuredAt: apiAt.addingTimeInterval(30)
    )
    #expect(ClaudeUsageAPIParser.merge(api: api, hook: freshHook).usedPercent == 14)
    #expect(ClaudeUsageAPIParser.merge(api: nil, hook: staleHook).usedPercent == 5)
}

#if os(macOS)
@Test func claudeUsagePollingFollowsLocalActivity() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
    let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12))!
    let due = { (start: Date, now: TimeInterval, next: TimeInterval, last: TimeInterval?, activity: TimeInterval?) in
        ClaudeUsageAPIClient.isDue(
            now: start + now, nextAttemptAt: start + next,
            lastAttemptAt: last.map { start + $0 }, lastActivityAt: activity.map { start + $0 },
            calendar: calendar
        )
    }
    #expect(due(noon, 0, -1, nil, nil))              // first launch
    #expect(!due(noon, 200, -1, 0, 100))             // activity, but inside 5 min
    #expect(due(noon, 300, -1, 0, 100))              // activity since last fetch → 5 min
    #expect(!due(noon, 600, -1, 0, -10))             // idle → wait for 15 min
    #expect(due(noon, 900, -1, 0, -10))
    #expect(!due(noon, 1000, 1800, 0, 500))          // failure backoff wins over activity

    let night = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 3))!
    #expect(!due(night, 300, -1, 0, 100))            // quiet hours: 10 min when active
    #expect(due(night, 600, -1, 0, 100))
    #expect(!due(night, 900, -1, 0, -10))            // quiet hours: 30 min when idle
    #expect(due(night, 1800, -1, 0, -10))
}
#endif
