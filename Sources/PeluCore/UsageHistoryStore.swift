import Foundation

/// Persistent local history store. Lives in the App Group container so the
/// iOS app + (future) widget can both read; currently only the iOS app writes.
///
/// Separate file from AppGroupStore's "latest snapshot" so they evolve
/// independently and a corruption in one doesn't break the other.
public struct UsageHistoryStore {
    public static let groupIdentifier = AppGroupStore.groupIdentifier

    private let fileURL: URL?

    public init?(suiteName: String = AppGroupStore.groupIdentifier) {
        let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)
        guard containerURL != nil else { return nil }
        self.fileURL = containerURL?.appendingPathComponent("usage-history.json")
    }

    public func load() throws -> UsageHistory {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else {
            return UsageHistory()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.peluAPI.decode(UsageHistory.self, from: data)
    }

    public func save(_ history: UsageHistory) throws {
        guard let url = fileURL else { return }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.peluAPI.encode(history)
        try data.write(to: url, options: [.atomic])
    }

    /// Convenience: load → record → save. Returns the resulting history so
    /// callers can update UI state synchronously without a second load.
    @discardableResult
    public func record(_ aggregate: AggregateSnapshot) throws -> UsageHistory {
        var history = (try? load()) ?? UsageHistory()
        history.recordSnapshot(aggregate)
        try save(history)
        return history
    }
}
