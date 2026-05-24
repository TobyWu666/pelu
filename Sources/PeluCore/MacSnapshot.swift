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

    /// Composite snapshot for Dashboard, Widget, and Live Activity. Claude
    /// retains the conservative highest-usage behavior. Codex quota from the
    /// app-server is account-wide, so choosing an older higher number leaves
    /// the UI stuck above a later reset; choose its newest measurement instead.
    public var displaySnapshot: UsageSnapshot? {
        displaySnapshot(at: Date())
    }

    public func displaySnapshot(at now: Date) -> UsageSnapshot? {
        guard !macs.isEmpty else { return nil }

        var metrics: [UsageMetric] = []
        var latestGenerated = Date.distantPast
        var pickedSource: ConnectionSource = .cloud

        for provider in ProviderKind.allCases {
            let candidates: [(metric: UsageMetric, generatedAt: Date, source: ConnectionSource)] =
                macs.compactMap { mac in
                    guard let metric = mac.snapshot.metric(for: provider) else { return nil }
                    return (metric.effective(at: now), mac.snapshot.generatedAt, mac.snapshot.source)
                }
            let winner: (metric: UsageMetric, generatedAt: Date, source: ConnectionSource)?
            if provider == .codex {
                winner = candidates.max(by: {
                    let left = $0.metric.measuredAt ?? $0.generatedAt
                    let right = $1.metric.measuredAt ?? $1.generatedAt
                    return left < right
                })
            } else {
                winner = candidates.max(by: {
                    ($0.metric.usedPercent ?? -1) < ($1.metric.usedPercent ?? -1)
                })
            }
            guard let winner else { continue }

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
