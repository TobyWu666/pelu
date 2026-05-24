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

    /// Composite snapshot: each provider's metric comes from whichever Mac
    /// reports the highest 5h `usedPercent` for that provider. Dashboard,
    /// Widget, and Live Activity all render this so the user sees a single
    /// "worst case" number per provider regardless of how many Macs they own.
    /// Claude and Codex are picked independently — different Macs can win.
    public var displaySnapshot: UsageSnapshot? {
        guard !macs.isEmpty else { return nil }

        var metrics: [UsageMetric] = []
        var latestGenerated = Date.distantPast
        var pickedSource: ConnectionSource = .cloud

        for provider in ProviderKind.allCases {
            let candidates: [(metric: UsageMetric, generatedAt: Date, source: ConnectionSource)] =
                macs.compactMap { mac in
                    guard let metric = mac.snapshot.metric(for: provider) else { return nil }
                    return (metric, mac.snapshot.generatedAt, mac.snapshot.source)
                }
            guard let winner = candidates.max(by: {
                ($0.metric.usedPercent ?? -1) < ($1.metric.usedPercent ?? -1)
            }) else { continue }

            metrics.append(winner.metric)
            latestGenerated = max(latestGenerated, winner.generatedAt)
            if winner.source != .demo { pickedSource = winner.source }
        }

        guard !metrics.isEmpty else { return nil }
        return UsageSnapshot(
            generatedAt: latestGenerated == .distantPast
                ? (newestGeneratedAt ?? Date())
                : latestGenerated,
            source: pickedSource,
            metrics: metrics
        )
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
