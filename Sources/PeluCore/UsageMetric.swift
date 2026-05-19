import Foundation

public struct UsageMetric: Codable, Equatable, Sendable, Identifiable {
    public let provider: ProviderKind
    /// Primary rate-limit usage — 5-hour window for Claude Code and Codex.
    public let usedPercent: Double?
    /// 7-day (weekly) rate-limit usage, shown as a secondary bar.
    public let weeklyPercent: Double?
    /// Context window fill for the current session (Claude Code only).
    public let contextWindowPercent: Double?
    public let costTodayUSD: Decimal?
    /// Reset time for the 5-hour window.
    public let resetDate: Date?
    /// Reset time for the 7-day window.
    public let weeklyResetDate: Date?
    public let status: UsageStatus
    public let note: String?

    public var id: ProviderKind { provider }

    public init(
        provider: ProviderKind,
        usedPercent: Double?,
        weeklyPercent: Double? = nil,
        contextWindowPercent: Double? = nil,
        costTodayUSD: Decimal? = nil,
        resetDate: Date? = nil,
        weeklyResetDate: Date? = nil,
        status: UsageStatus? = nil,
        note: String? = nil
    ) {
        self.provider = provider
        self.usedPercent = usedPercent
        self.weeklyPercent = weeklyPercent
        self.contextWindowPercent = contextWindowPercent
        self.costTodayUSD = costTodayUSD
        self.resetDate = resetDate
        self.weeklyResetDate = weeklyResetDate
        self.status = status ?? UsageStatus.from(percent: usedPercent)
        self.note = note
    }
}
