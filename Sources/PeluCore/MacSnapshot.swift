import Foundation

/// One Mac's latest reading. The Worker stores these in KV keyed by `macId`
/// and returns an `AggregateSnapshot` to the iPhone.
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

/// What the iPhone receives from `GET /usage`. The order is stable
/// (alphabetical by label), so the first entry is the "primary" Mac
/// rendered in widgets / Live Activity.
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
