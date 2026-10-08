import Foundation
import Testing
@testable import PeluCore

/// AppGroupStore uses a real App Group identifier in production; under `swift test`
/// the App Group container isn't entitled, so tests inject a temp directory and a
/// regular in-process UserDefaults suite.
@Test func appGroupStoreRoundTripsViaFile() throws {
    let suite = "pelu.tests.\(UUID().uuidString)"
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    let store = AppGroupStore(containerURL: dir, defaults: UserDefaults(suiteName: suite))
    let aggregate = AggregateSnapshot.demo(now: Date(timeIntervalSince1970: 1_800_000_000))
    try store.save(aggregate)

    #expect(try store.loadLatestAggregate() == aggregate)
}

@Test func appGroupStoreRoundTripsViaUserDefaultsFallback() throws {
    // Unique suite per test run so this never collides with another test.
    let suite = "pelu.tests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    let store = AppGroupStore(containerURL: nil, defaults: UserDefaults(suiteName: suite))
    let aggregate = AggregateSnapshot.demo(now: Date(timeIntervalSince1970: 1_800_000_000))
    try store.save(aggregate)

    let loaded = try store.loadLatestAggregate()
    #expect(loaded == aggregate)
}

@Test func appGroupStoreReturnsNilWhenEmpty() throws {
    let suite = "pelu.tests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    guard let store = AppGroupStore(suiteName: suite) else {
        Issue.record("AppGroupStore should initialize against a regular UserDefaults suite")
        return
    }

    let loaded = try store.loadLatestAggregate()
    #expect(loaded == nil)
}
