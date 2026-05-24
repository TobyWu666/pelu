import Foundation

public struct UsageSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let generatedAt: Date
    public let source: ConnectionSource
    public let metrics: [UsageMetric]

    public init(
        id: UUID = UUID(),
        generatedAt: Date,
        source: ConnectionSource,
        metrics: [UsageMetric]
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.source = source
        self.metrics = metrics
    }

    // CloudKit (and legacy Worker payloads) don't carry our internal `id` field —
    // it's a SwiftUI Identifiable helper, not part of the wire format. On decode,
    // mint a fresh UUID if missing; forward-compat with future versions that may
    // include `id` is preserved by trying to decode it first.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.source = try container.decodeIfPresent(ConnectionSource.self, forKey: .source) ?? .cloud
        self.metrics = try container.decode([UsageMetric].self, forKey: .metrics)
    }

    private enum CodingKeys: String, CodingKey {
        case id, generatedAt, source, metrics
    }

    public func metric(for provider: ProviderKind) -> UsageMetric? {
        metrics.first { $0.provider == provider }
    }

    public func effective(at now: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            id: id,
            generatedAt: generatedAt,
            source: source,
            metrics: metrics.map { $0.effective(at: now) }
        )
    }

    public static func demo(now: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: now,
            source: .demo,
            metrics: [
                UsageMetric(
                    provider: .claudeCode,
                    usedPercent: 37,
                    weeklyPercent: 21,
                    contextWindowPercent: 4,
                    costTodayUSD: Decimal(string: "4.28"),
                    resetDate: Calendar.current.date(byAdding: .hour, value: 6, to: now)
                ),
                UsageMetric(
                    provider: .codex,
                    usedPercent: 10,
                    weeklyPercent: 23,
                    costTodayUSD: Decimal(string: "1.12"),
                    resetDate: Calendar.current.date(byAdding: .hour, value: 9, to: now)
                ),
            ]
        )
    }
}
