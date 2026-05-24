import Foundation

/// One day of usage data — captures whatever the iPhone fetched from CloudKit
/// before the calendar day rolled over. Stored locally on the iPhone only.
public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    /// Always normalized to start-of-day in the user's local timezone, so equality
    /// and ordering are well-defined regardless of when the snapshot was taken.
    public let date: Date

    /// All Macs the user had on this day. Empty array means the day exists but
    /// no Mac data was available (offline / unpaired / signed out).
    public let macs: [MacSnapshot]

    public var id: Date { date }

    public init(date: Date, macs: [MacSnapshot]) {
        self.date = date
        self.macs = macs
    }
}

/// Rolling 30-day local history. Entries are sorted newest-first so the
/// dashboard / history view can render directly without resorting.
public struct UsageHistory: Codable, Equatable, Sendable {
    public static let retentionDays = 30

    public var entries: [HistoryEntry]

    public init(entries: [HistoryEntry] = []) {
        self.entries = entries
    }

    /// Record (or replace) today's snapshot. Multiple calls in the same day
    /// just overwrite — so the last fetch of each day wins, which is what we
    /// want: it captures the latest known state just before midnight.
    ///
    /// Once midnight crosses, the next call lands on a different `startOfDay`
    /// and creates a new entry — that's effectively the "freeze yesterday,
    /// start today" pattern.
    public mutating func recordSnapshot(
        _ aggregate: AggregateSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let day = calendar.startOfDay(for: now)

        if let idx = entries.firstIndex(where: {
            calendar.isDate($0.date, inSameDayAs: day)
        }) {
            // Don't downgrade an already-populated entry to empty. A fetch
            // can transiently return zero macs (CloudKit hiccup, subscription
            // race, account flip mid-day); without this guard the chart
            // loses today's data the moment that happens.
            if aggregate.macs.isEmpty { return }
            entries[idx] = HistoryEntry(date: day, macs: aggregate.macs)
        } else {
            entries.append(HistoryEntry(date: day, macs: aggregate.macs))
        }

        entries.sort { $0.date > $1.date }
        if entries.count > Self.retentionDays {
            entries = Array(entries.prefix(Self.retentionDays))
        }
    }
}
