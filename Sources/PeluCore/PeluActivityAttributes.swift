#if os(iOS)
import ActivityKit
import Foundation

public struct PeluActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var claudePercent: Double?
        public var claudeWeeklyPercent: Double?
        public var claudeWeeklyResetDate: Date?
        public var claudeResetDate: Date?
        public var codexPercent: Double?
        public var codexWeeklyPercent: Double?
        public var codexWeeklyResetDate: Date?
        public var updatedAt: Date

        public init(
            claudePercent: Double?,
            claudeWeeklyPercent: Double?,
            claudeWeeklyResetDate: Date? = nil,
            claudeResetDate: Date?,
            codexPercent: Double?,
            codexWeeklyPercent: Double?,
            codexWeeklyResetDate: Date? = nil,
            updatedAt: Date = Date()
        ) {
            self.claudePercent = claudePercent
            self.claudeWeeklyPercent = claudeWeeklyPercent
            self.claudeWeeklyResetDate = claudeWeeklyResetDate
            self.claudeResetDate = claudeResetDate
            self.codexPercent = codexPercent
            self.codexWeeklyPercent = codexWeeklyPercent
            self.codexWeeklyResetDate = codexWeeklyResetDate
            self.updatedAt = updatedAt
        }

        public static func from(snapshot: UsageSnapshot) -> ContentState {
            let claude = snapshot.metric(for: .claudeCode)
            let codex = snapshot.metric(for: .codex)
            return ContentState(
                claudePercent: claude?.usedPercent,
                claudeWeeklyPercent: claude?.weeklyPercent,
                claudeWeeklyResetDate: claude?.weeklyResetDate,
                claudeResetDate: claude?.resetDate,
                codexPercent: codex?.usedPercent,
                codexWeeklyPercent: codex?.weeklyPercent,
                codexWeeklyResetDate: codex?.weeklyResetDate,
                updatedAt: snapshot.generatedAt
            )
        }
    }

    public init() {}
}
#endif
