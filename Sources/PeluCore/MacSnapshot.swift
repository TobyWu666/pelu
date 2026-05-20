import Foundation

/// One Mac's latest reading. Persisted to CloudKit as a `MacSnapshot` record
/// keyed by `mac-{macId}`; iPhone fetches and groups them into `AggregateSnapshot`.
public struct MacSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let macId: String
    public let label: String
    public let snapshot: UsageSnapshot

    public var id: String { macId }

    public init(macId: String, label: String, snapshot: UsageSnapshot) {
        self.macId = macId
        self.label = label
        self.snapshot = snapshot
    }
}

/// What the iPhone aggregates after fetching all `MacSnapshot` records from
/// CloudKit. The order is stable (alphabetical by label), so the first entry
/// is the "primary" Mac rendered in Widget / Live Activity.
public struct AggregateSnapshot: Codable, Equatable, Sendable {
    public let macs: [MacSnapshot]

    public init(macs: [MacSnapshot]) {
        self.macs = macs
    }

    public var primary: MacSnapshot? { macs.first }

    /// Most recent generatedAt across all Macs — used for the dashboard's
    /// "last updated" timestamp.
    public var newestGeneratedAt: Date? {
        macs.map(\.snapshot.generatedAt).max()
    }

    public static func demo(now: Date = Date()) -> AggregateSnapshot {
        AggregateSnapshot(macs: [
            MacSnapshot(
                macId: "demo-mac",
                label: "Demo Mac",
                snapshot: .demo(now: now)
            )
        ])
    }
}
