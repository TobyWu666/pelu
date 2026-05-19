import Foundation
import Testing
@testable import PeluCore

/// AppGroupStore uses a real App Group identifier in production; under `swift test`
/// the App Group container isn't entitled, but UserDefaults(suiteName:) still works
/// as a normal in-process suite. We exercise the fallback path here.
@Test func appGroupStoreRoundTripsViaUserDefaultsFallback() throws {
    // Unique suite per test run so this never collides with another test.
    let suite = "pelu.tests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    guard let store = AppGroupStore(suiteName: suite) else {
        Issue.record("AppGroupStore should initialize against a regular UserDefaults suite")
        return
    }

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
