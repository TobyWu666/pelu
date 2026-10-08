import Foundation
import Testing
@testable import PeluCore

@Test func usageSnapshotRoundTripsThroughAPIJSON() throws {
    let snapshot = UsageSnapshot.demo(now: Date(timeIntervalSince1970: 1_800_000_000))

    let data = try JSONEncoder.peluAPI.encode(snapshot)
    let decoded = try JSONDecoder.peluAPI.decode(UsageSnapshot.self, from: data)

    #expect(decoded == snapshot)
}

@Test func usageStatusFollowsThresholds() {
    #expect(UsageStatus.from(percent: nil) == .unknown)
    #expect(UsageStatus.from(percent: 12) == .normal)
    #expect(UsageStatus.from(percent: 72) == .caution)
    #expect(UsageStatus.from(percent: 91) == .warning)
}

@Test func usageMetricProjectsExpiredWindowsToZero() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let metric = UsageMetric(
        provider: .codex,
        usedPercent: 91,
        weeklyPercent: 76,
        resetDate: now,
        weeklyResetDate: now.addingTimeInterval(-1)
    )

    let effective = metric.effective(at: now)
    #expect(effective.usedPercent == 0)
    #expect(effective.weeklyPercent == 0)
    #expect(effective.status == .normal)
}

@Test func aggregateUsesNewestAccountWideCodexMeasurement() {
    let oldTime = Date(timeIntervalSince1970: 1_800_000_000)
    let newTime = oldTime.addingTimeInterval(600)
    let aggregate = AggregateSnapshot(macs: [
        MacSnapshot(
            macId: "old",
            label: "Old Mac",
            snapshot: UsageSnapshot(
                generatedAt: oldTime,
                source: .cloud,
                metrics: [
                    UsageMetric(
                        provider: .codex,
                        usedPercent: 95,
                        dataSource: .officialQuota,
                        measuredAt: oldTime
                    )
                ]
            )
        ),
        MacSnapshot(
            macId: "new",
            label: "New Mac",
            snapshot: UsageSnapshot(
                generatedAt: newTime,
                source: .cloud,
                metrics: [
                    UsageMetric(
                        provider: .codex,
                        usedPercent: 8,
                        dataSource: .officialQuota,
                        measuredAt: newTime
                    )
                ]
            )
        ),
    ])

    #expect(aggregate.displaySnapshot?.metric(for: .codex)?.usedPercent == 8)
}

@Test func aggregateKeepsHighestClaudeMeasurement() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let aggregate = AggregateSnapshot(macs: [
        MacSnapshot(
            macId: "higher",
            label: "Higher Mac",
            snapshot: UsageSnapshot(
                generatedAt: now,
                source: .cloud,
                metrics: [UsageMetric(provider: .claudeCode, usedPercent: 85)]
            )
        ),
        MacSnapshot(
            macId: "newer-lower",
            label: "Newer Lower Mac",
            snapshot: UsageSnapshot(
                generatedAt: now.addingTimeInterval(600),
                source: .cloud,
                metrics: [UsageMetric(provider: .claudeCode, usedPercent: 10)]
            )
        ),
    ])

    #expect(aggregate.displaySnapshot?.metric(for: .claudeCode)?.usedPercent == 85)
}

@Test func aggregateDropsExpiredHighClaudeMeasurementAtDisplayTime() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let aggregate = AggregateSnapshot(macs: [
        MacSnapshot(
            macId: "expired",
            label: "Expired Mac",
            snapshot: UsageSnapshot(
                generatedAt: now.addingTimeInterval(-60),
                source: .cloud,
                metrics: [
                    UsageMetric(
                        provider: .claudeCode,
                        usedPercent: 95,
                        resetDate: now.addingTimeInterval(-1)
                    )
                ]
            )
        ),
        MacSnapshot(
            macId: "active",
            label: "Active Mac",
            snapshot: UsageSnapshot(
                generatedAt: now,
                source: .cloud,
                metrics: [
                    UsageMetric(
                        provider: .claudeCode,
                        usedPercent: 12,
                        resetDate: now.addingTimeInterval(3600)
                    )
                ]
            )
        ),
    ])

    #expect(aggregate.displaySnapshot(at: now)?.metric(for: .claudeCode)?.usedPercent == 12)
}

@Test func codexQuotaSnapshotMarksOfficialAndZeroesExpiredWindow() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = CodexQuotaSnapshot(
        rateLimits: .init(
            primary: .init(usedPercent: 73, windowDurationMins: 10_080, resetsAt: Int64(now.addingTimeInterval(-1).timeIntervalSince1970)),
            secondary: .init(usedPercent: 19, windowDurationMins: 1_440, resetsAt: Int64(now.addingTimeInterval(3600).timeIntervalSince1970))
        ),
        fetchedAt: now.addingTimeInterval(-30),
        source: .appServerRead
    )

    let metric = snapshot.asUsageMetric(now: now)
    #expect(metric.usedPercent == 0)
    #expect(metric.weeklyPercent == 19)
    #expect(metric.primaryWindowDurationMins == 10_080)
    #expect(metric.secondaryWindowDurationMins == 1_440)
    #expect(metric.dataSource == .officialQuota)
    #expect(metric.measuredAt == now.addingTimeInterval(-30))
}
