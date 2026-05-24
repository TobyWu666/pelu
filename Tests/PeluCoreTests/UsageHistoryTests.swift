import Foundation
import Testing
@testable import PeluCore

@Test func recordingTwiceOnSameDayOverwritesNotAppends() {
    var history = UsageHistory()
    let now = Date(timeIntervalSince1970: 1_800_000_000) // some Tuesday

    history.recordSnapshot(AggregateSnapshot.demo(now: now), now: now)
    history.recordSnapshot(AggregateSnapshot.demo(now: now.addingTimeInterval(3600)), now: now)

    #expect(history.entries.count == 1)
}

@Test func crossingMidnightCreatesNewEntry() {
    var history = UsageHistory()
    let calendar = Calendar(identifier: .gregorian)

    // Day 1: 23:50
    var components = DateComponents()
    components.year = 2026; components.month = 5; components.day = 20
    components.hour = 23; components.minute = 50; components.timeZone = .current
    let lateNight = calendar.date(from: components)!

    // Day 2: 00:10 (next calendar day)
    components.day = 21; components.hour = 0; components.minute = 10
    let nextMorning = calendar.date(from: components)!

    history.recordSnapshot(AggregateSnapshot.demo(), now: lateNight, calendar: calendar)
    history.recordSnapshot(AggregateSnapshot.demo(), now: nextMorning, calendar: calendar)

    #expect(history.entries.count == 2)
    // Newest first
    #expect(history.entries[0].date > history.entries[1].date)
}

@Test func emptyAggregateDoesNotOverwritePopulatedDay() {
    var history = UsageHistory()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    history.recordSnapshot(AggregateSnapshot.demo(now: now), now: now)
    let populated = history.entries.first?.macs ?? []
    #expect(!populated.isEmpty)

    // Simulate a CloudKit refresh that came back empty — common during
    // subscription registration races or temporary account hiccups.
    history.recordSnapshot(AggregateSnapshot(macs: []), now: now)

    #expect(history.entries.count == 1)
    #expect(history.entries[0].macs.count == populated.count)
}

@Test func historyKeepsOnly30Days() {
    var history = UsageHistory()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let calendar = Calendar(identifier: .gregorian)

    // 40 distinct days
    for offset in 0..<40 {
        let day = calendar.date(byAdding: .day, value: offset, to: base)!
        history.recordSnapshot(AggregateSnapshot.demo(), now: day, calendar: calendar)
    }

    #expect(history.entries.count == 30)
    // Entries are sorted newest-first, so [0] should be the most recent.
    let newest = history.entries[0].date
    let oldest = history.entries[29].date
    #expect(newest > oldest)
}
