import Foundation
import Testing
@testable import PeluCore

private let historyNow = Date(timeIntervalSince1970: 1_800_000_000)
private func observation(_ date: Date, percent: Double = 40, reset: Date? = nil) -> UsageSnapshot {
    UsageSnapshot(generatedAt: date, source: .local, metrics: [UsageMetric(provider: .codex, usedPercent: percent, resetDate: reset, dataSource: .officialQuota, measuredAt: date)])
}

@Test func macHistoryDeduplicatesMeasurementsAndRejectsStaleData() {
    var history = MacUsageHistory()
    let snapshot = observation(historyNow)
    history.record(snapshot, now: historyNow)
    history.record(snapshot, now: historyNow.addingTimeInterval(60))
    history.record(observation(historyNow.addingTimeInterval(-2400)), now: historyNow)
    #expect(history.samples.count == 1)
}

@Test func macHistoryBreaksAtResetAndOfflineGap() {
    var history = MacUsageHistory()
    let reset = historyNow.addingTimeInterval(120)
    history.record(observation(historyNow, reset: reset), now: historyNow)
    history.record(observation(historyNow.addingTimeInterval(60), percent: 50, reset: reset), now: historyNow.addingTimeInterval(60))
    let later = historyNow.addingTimeInterval(180)
    history.record(observation(later, percent: 2, reset: later.addingTimeInterval(3600)), now: later)
    let gap = later.addingTimeInterval(2200)
    history.record(observation(gap, percent: 10, reset: later.addingTimeInterval(3600)), now: gap)
    let points = history.points(provider: .codex, secondary: false, since: historyNow)
    #expect(points.map(\.segment) == [0, 0, 1, 2])
}

@Test func macHistoryRetentionAndPersistence() throws {
    var history = MacUsageHistory()
    history.record(observation(historyNow), now: historyNow)
    let later = historyNow.addingTimeInterval(31 * 86400)
    history.record(observation(later), now: later)
    #expect(history.samples.count == 1)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MacUsageHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
    try store.save(history)
    #expect(try store.load() == history)
}

@Test func macHistoryThrottlesUnchangedReadingsButKeepsLineConnected() {
    var history = MacUsageHistory()
    // Unchanged reading polled every 30 s for 10 minutes.
    for step in 0...20 {
        let date = historyNow.addingTimeInterval(Double(step) * 30)
        history.record(observation(date), now: date)
    }
    #expect(history.samples.map(\.date) == [0, 240, 480].map { historyNow.addingTimeInterval($0) })
    #expect(Set(history.points(provider: .codex, secondary: false, since: historyNow).map(\.segment)) == [0])

    // A changed value still waits out the shorter spacing.
    let changedSoon = historyNow.addingTimeInterval(510)
    let recordedSoon = history.record(observation(changedSoon, percent: 45), now: changedSoon)
    #expect(!recordedSoon)
    let changedLater = historyNow.addingTimeInterval(540)
    let recordedLater = history.record(observation(changedLater, percent: 45), now: changedLater)
    #expect(recordedLater)
    #expect(history.samples.count == 4)
}
