import CloudKit
import Foundation
import Testing
@testable import PeluCore

private let summary = """
{"billingCycleStart":"2026-10-08T07:41:06.000Z","billingCycleEnd":"2026-11-08T07:41:06.000Z","membershipType":"pro","limitType":"user","isUnlimited":false,"autoModelSelectedDisplayMessage":"You've used 1% of your included total usage","namedModelSelectedDisplayMessage":"You've used 10% of your included API usage","individualUsage":{"plan":{"enabled":true,"used":560,"limit":2000,"remaining":1440,"autoPercentUsed":0.23555555555555557,"apiPercentUsed":10.088888888888889,"totalPercentUsed":1.1313131313131313},"onDemand":{"enabled":false,"used":0,"limit":null,"remaining":null}},"teamUsage":{}}
"""

@Test func cursorSummaryMapsPoolsToBillingCycle() throws {
    let fetchedAt = Date(timeIntervalSince1970: 1_791_600_000) // 2026-10-10
    let metric = try CursorUsageParser().parse(data: Data(summary.utf8), fetchedAt: fetchedAt, generatedAt: fetchedAt)

    #expect(metric.provider == .cursor)
    #expect(abs((metric.usedPercent ?? 0) - 10.0889) < 0.001)
    #expect(abs((metric.weeklyPercent ?? 0) - 0.2356) < 0.001)
    #expect(metric.primaryWindowDurationMins == 31 * 24 * 60)
    #expect(metric.sharesResetDate)
    #expect(metric.windowTitle(secondary: false) == "API")
    #expect(metric.windowTitle(secondary: true) == "Auto")
    #expect(metric.dataSource == .officialQuota)
    #expect(metric.measuredAt == fetchedAt)
}

@Test func cursorStatusFollowsFullerPool() throws {
    let json = summary
        .replacingOccurrences(of: "\"autoPercentUsed\":0.23555555555555557", with: "\"autoPercentUsed\":92")
    let now = Date(timeIntervalSince1970: 1_791_600_000)
    let metric = try CursorUsageParser().parse(data: Data(json.utf8), fetchedAt: now, generatedAt: now)
    #expect(metric.status == .warning)
}

@Test func primaryWindowElapsedTracksTimeToReset() throws {
    let now = Date(timeIntervalSince1970: 1_791_600_000)
    let metric = try CursorUsageParser().parse(data: Data(summary.utf8), fetchedAt: now, generatedAt: now)
    let reset = try #require(metric.resetDate)
    let quarterLeft = reset.addingTimeInterval(-Double(31 * 24 * 60 * 60) / 4)

    #expect(abs((metric.primaryWindowElapsed(at: quarterLeft) ?? 0) - 0.75) < 0.0001)
    #expect(metric.primaryWindowElapsed(at: reset.addingTimeInterval(1)) == nil)
    #expect(UsageMetric(provider: .codex, usedPercent: 10).primaryWindowElapsed(at: now) == nil)
}

@Test func cursorFallsBackToDashboardMessagesWithoutPlan() throws {
    let json = """
    {"billingCycleStart":"2026-10-08T07:41:06.000Z","billingCycleEnd":"2026-11-08T07:41:06.000Z","isUnlimited":false,
     "autoModelSelectedDisplayMessage":"You've used 42% of your included total usage",
     "namedModelSelectedDisplayMessage":"You've used 7.5% of your included API usage","teamUsage":{}}
    """
    let now = Date(timeIntervalSince1970: 1_791_600_000)
    let metric = try CursorUsageParser().parse(data: Data(json.utf8), fetchedAt: now, generatedAt: now)
    #expect(metric.usedPercent == 7.5)
    #expect(metric.weeklyPercent == 42)
}

@Test func cursorZeroesAfterBillingCycleEnds() throws {
    let after = Date(timeIntervalSince1970: 1_794_200_000) // past 2026-11-08
    let metric = try CursorUsageParser().parse(data: Data(summary.utf8), fetchedAt: after.addingTimeInterval(-86400 * 3), generatedAt: after)
    #expect(metric.usedPercent == 0)
    #expect(metric.weeklyPercent == 0)
    #expect(metric.status == .normal)
}

#if os(macOS)
@Test func cursorCookieUsesSubjectWithoutProviderPrefix() throws {
    func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
    let jwt = "\(b64(#"{"alg":"HS256"}"#)).\(b64(#"{"sub":"auth0|user_ABC","exp":1796620741}"#)).sig"
    let token = try #require(CursorUsageClient.makeToken(jwt: jwt))
    #expect(token.cookie == "WorkosCursorSessionToken=user_ABC%3A%3A\(jwt)")
    #expect(token.expiresAt == Date(timeIntervalSince1970: 1_796_620_741))
}
#endif

private func cursorMac() -> MacSnapshot {
    let now = Date(timeIntervalSince1970: 1_791_600_000)
    return MacSnapshot(macId: "m", label: "Mac", snapshot: UsageSnapshot(
        generatedAt: now,
        source: .local,
        metrics: [
            UsageMetric(provider: .claudeCode, usedPercent: 37),
            UsageMetric(provider: .codex, usedPercent: 10),
            UsageMetric(provider: .cursor, usedPercent: 12, weeklyPercent: 3, measuredAt: now),
        ]
    ))
}

@Test func cursorTravelsOutsideLegacyPayload() throws {
    let record = try MacSnapshotRecord.makeRecord(from: cursorMac(), bundleVersion: "test")

    // iOS 1.1 decodes `payload` as a strict array; it must stay readable.
    let payload = try #require(record["payload"] as? Data)
    let legacy = try JSONDecoder.peluAPI.decode([UsageMetric].self, from: payload)
    #expect(legacy.map(\.provider) == [.claudeCode, .codex])

    let decoded = try MacSnapshotRecord.decode(record)
    #expect(decoded.snapshot.metrics.map(\.provider) == [.claudeCode, .codex, .cursor])
    #expect(decoded.snapshot.metric(for: .cursor)?.usedPercent == 12)
}

@Test func recordWithoutExtraMetricsOmitsTheField() throws {
    let record = try MacSnapshotRecord.makeRecord(from: cursorMac(), bundleVersion: "test", includeExtraMetrics: false)
    #expect(record["extraMetrics"] == nil)
    #expect(try MacSnapshotRecord.decode(record).snapshot.metrics.count == 2)
}

@Test func recordDecodeSkipsUnknownProviders() throws {
    let record = try MacSnapshotRecord.makeRecord(from: cursorMac(), bundleVersion: "test")
    var json = try #require(JSONSerialization.jsonObject(with: record["payload"] as! Data) as? [[String: Any]])
    var future = json[0]
    future["provider"] = "some_future_tool"
    json.insert(future, at: 0)
    record["payload"] = try JSONSerialization.data(withJSONObject: json) as NSData

    let decoded = try MacSnapshotRecord.decode(record)
    #expect(decoded.snapshot.metrics.map(\.provider) == [.claudeCode, .codex, .cursor])
}

@Test func aggregateUsesNewestAccountWideCursorMeasurement() {
    let old = Date(timeIntervalSince1970: 1_791_600_000)
    let new = old.addingTimeInterval(600)
    let aggregate = AggregateSnapshot(macs: [
        MacSnapshot(macId: "a", label: "A", snapshot: UsageSnapshot(generatedAt: old, source: .cloud, metrics: [
            UsageMetric(provider: .cursor, usedPercent: 80, measuredAt: old),
        ])),
        MacSnapshot(macId: "b", label: "B", snapshot: UsageSnapshot(generatedAt: new, source: .cloud, metrics: [
            UsageMetric(provider: .cursor, usedPercent: 5, measuredAt: new),
        ])),
    ])
    #expect(aggregate.displaySnapshot(at: new)?.metric(for: .cursor)?.usedPercent == 5)
}
