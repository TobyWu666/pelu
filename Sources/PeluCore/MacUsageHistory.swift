import Foundation

/// One quota reading, trimmed to what the analysis chart needs so 30 days of
/// samples stay small on disk.
public struct MacUsageSample: Codable, Equatable, Sendable {
    public let date: Date
    public let provider: ProviderKind
    public let usedPercent: Double?
    public let weeklyPercent: Double?
    public let resetDate: Date?
    public let weeklyResetDate: Date?
    public let primaryWindowDurationMins: Int
    public let secondaryWindowDurationMins: Int
    public let dataSource: UsageDataSource?

    init(date: Date, metric: UsageMetric) {
        self.date = date
        self.provider = metric.provider
        self.usedPercent = metric.usedPercent
        self.weeklyPercent = metric.weeklyPercent
        self.resetDate = metric.resetDate
        self.weeklyResetDate = metric.weeklyResetDate
        self.primaryWindowDurationMins = metric.resolvedPrimaryWindowDurationMins
        self.secondaryWindowDurationMins = metric.resolvedSecondaryWindowDurationMins
        self.dataSource = metric.dataSource
    }

    func hasSameReading(as other: MacUsageSample) -> Bool {
        usedPercent == other.usedPercent && weeklyPercent == other.weeklyPercent &&
            resetDate == other.resetDate && weeklyResetDate == other.weeklyResetDate &&
            primaryWindowDurationMins == other.primaryWindowDurationMins &&
            secondaryWindowDurationMins == other.secondaryWindowDurationMins &&
            dataSource == other.dataSource
    }
}

/// Source observations, not refresh ticks. Kept separate from iOS daily snapshots.
public struct MacUsageHistory: Codable, Equatable, Sendable {
    public static let retention: TimeInterval = 30 * 86400
    /// Readings older than this are stale, and a longer gap breaks the chart line.
    public static let gapThreshold: TimeInterval = 300
    /// Minimum spacing between samples whose values changed.
    static let changedSpacing: TimeInterval = 60
    /// Spacing for unchanged values; below `gapThreshold` so flat runs stay connected.
    static let unchangedSpacing: TimeInterval = 240

    public private(set) var samples: [MacUsageSample] = []
    public init() {}

    /// Returns whether `samples` changed (new reading or expired ones dropped).
    @discardableResult
    public mutating func record(_ snapshot: UsageSnapshot, now: Date = Date()) -> Bool {
        let countBefore = samples.count
        samples.removeAll { $0.date < now.addingTimeInterval(-Self.retention) }
        var changed = samples.count != countBefore
        guard snapshot.source != .demo else { return changed }
        for metric in snapshot.metrics {
            guard let date = metric.measuredAt,
                  date <= now.addingTimeInterval(5), now.timeIntervalSince(date) < Self.gapThreshold,
                  metric.usedPercent != nil || metric.weeklyPercent != nil else { continue }
            let sample = MacUsageSample(date: date, metric: metric)
            if let latest = samples.last(where: { $0.provider == metric.provider }) {
                let spacing = sample.hasSameReading(as: latest) ? Self.unchangedSpacing : Self.changedSpacing
                guard date.timeIntervalSince(latest.date) >= spacing else { continue }
            }
            if let last = samples.last, last.date > date {
                samples.insert(sample, at: samples.firstIndex { $0.date > date } ?? samples.endIndex)
            } else {
                samples.append(sample)
            }
            changed = true
        }
        return changed
    }

    /// Never connect across missing intervals, source switches, or quota resets.
    public func points(provider: ProviderKind, secondary: Bool, since: Date) -> [MacUsagePoint] {
        var result: [MacUsagePoint] = []
        var previous: MacUsageSample?
        var segment = 0
        for sample in samples where sample.provider == provider && sample.date >= since {
            let percent = secondary ? sample.weeklyPercent : sample.usedPercent
            let reset = secondary ? sample.weeklyResetDate : sample.resetDate
            guard let percent, percent.isFinite, reset.map({ $0 > sample.date }) ?? true else {
                previous = nil
                segment += 1
                continue
            }
            if let previous {
                let oldReset = secondary ? previous.weeklyResetDate : previous.resetDate
                let oldPercent = secondary ? previous.weeklyPercent : previous.usedPercent
                let duration = secondary ? sample.secondaryWindowDurationMins : sample.primaryWindowDurationMins
                let oldDuration = secondary ? previous.secondaryWindowDurationMins : previous.primaryWindowDurationMins
                if sample.date.timeIntervalSince(previous.date) > Self.gapThreshold || reset != oldReset ||
                    sample.dataSource != previous.dataSource || duration != oldDuration || percent < (oldPercent ?? percent) {
                    segment += 1
                }
            }
            result.append(MacUsagePoint(date: sample.date, percent: min(100, max(0, percent)), segment: segment))
            previous = sample
        }
        return result
    }
}

public struct MacUsagePoint: Identifiable, Sendable {
    public let date: Date
    public let percent: Double
    public let segment: Int
    /// Samples are unique per provider and date, and points come from one provider.
    public var id: Date { date }
}

public struct MacUsageHistoryStore: Sendable {
    public let fileURL: URL
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pelu/mac-usage-history.json")
    }
    public func load() throws -> MacUsageHistory {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return MacUsageHistory() }
        return try JSONDecoder().decode(MacUsageHistory.self, from: Data(contentsOf: fileURL))
    }
    public func save(_ history: MacUsageHistory) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(history).write(to: fileURL, options: .atomic)
    }
}
