import Foundation

/// Where a metric's numbers came from. `nil` = legacy snapshot from before
/// the field existed (older CloudKit payload, older Pelu version on the
/// other end). UI should treat nil as "unknown" not "official".
public enum UsageDataSource: String, Codable, Sendable {
    /// `codex app-server` JSON-RPC `account/rateLimits/read`, or Claude
    /// Code's statusLine hook reading the live `~/.claude/usag-status.json`.
    /// Authoritative quota straight from the provider.
    case officialQuota
    /// Tailing local jsonl files for the most recent rate_limits event.
    /// May be stale if the user hasn't done any Codex work recently, and
    /// blind to other Macs / Codex Cloud / IDE extensions on the same
    /// account.
    case localEstimate
}

public struct UsageMetric: Codable, Equatable, Sendable, Identifiable {
    public let provider: ProviderKind
    /// Primary rate-limit usage. Its duration is provider-controlled and may
    /// change over time (for example, Codex moved from 5 hours to 7 days).
    public let usedPercent: Double?
    /// Legacy name for the provider's secondary rate-limit window.
    public let weeklyPercent: Double?
    /// Provider-reported duration for the primary window.
    public let primaryWindowDurationMins: Int?
    /// Provider-reported duration for the secondary window.
    public let secondaryWindowDurationMins: Int?
    /// Context window fill for the current session (Claude Code only).
    public let contextWindowPercent: Double?
    public let costTodayUSD: Decimal?
    /// Reset time for the primary window.
    public let resetDate: Date?
    /// Reset time for the secondary window (legacy property name).
    public let weeklyResetDate: Date?
    public let status: UsageStatus
    public let note: String?
    /// Where these numbers came from. Optional so payloads written by
    /// pre-1.1 Pelu still decode cleanly. UI shows a small "估算" badge
    /// for `.localEstimate`; `.officialQuota` and `nil` render plain.
    public let dataSource: UsageDataSource?
    /// When *this* metric was last measured at the source. Per-metric
    /// (not snapshot-wide) because Codex RPC and Claude statusLine fire
    /// independently — one can be 30s fresh while the other is 2h cold.
    /// Optional for backward compat with pre-1.1 payloads.
    public let measuredAt: Date?
    /// Token totals from Codex JSONL (sum across all active sessions).
    /// Only populated for `.codex`; iOS uses `CodexPricing.estimateUSD` to
    /// derive an API-equivalent spend for the history chart. nil for
    /// Claude (Claude has `cost.total_cost_usd` in `costTodayUSD`) and
    /// for legacy payloads written before v1.0.7.
    public let tokenUsage: CodexTokenUsage?

    public var id: ProviderKind { provider }

    /// A measurement older than this is treated as stale. Longer than the
    /// slowest idle poll (Codex RPC 20 min, Claude usage API 30 min overnight)
    /// so a quiet, healthy source doesn't look disconnected.
    public static let staleAfter: TimeInterval = 2100

    public init(
        provider: ProviderKind,
        usedPercent: Double?,
        weeklyPercent: Double? = nil,
        primaryWindowDurationMins: Int? = nil,
        secondaryWindowDurationMins: Int? = nil,
        contextWindowPercent: Double? = nil,
        costTodayUSD: Decimal? = nil,
        resetDate: Date? = nil,
        weeklyResetDate: Date? = nil,
        status: UsageStatus? = nil,
        note: String? = nil,
        dataSource: UsageDataSource? = nil,
        measuredAt: Date? = nil,
        tokenUsage: CodexTokenUsage? = nil
    ) {
        self.provider = provider
        self.usedPercent = usedPercent
        self.weeklyPercent = weeklyPercent
        self.primaryWindowDurationMins = primaryWindowDurationMins
        self.secondaryWindowDurationMins = secondaryWindowDurationMins
        self.contextWindowPercent = contextWindowPercent
        self.costTodayUSD = costTodayUSD
        self.resetDate = resetDate
        self.weeklyResetDate = weeklyResetDate
        self.status = status ?? UsageStatus.from(percent: usedPercent)
        self.note = note
        self.dataSource = dataSource
        self.measuredAt = measuredAt
        self.tokenUsage = tokenUsage
    }

    /// Values received from CloudKit can legitimately outlive their quota
    /// window when the source Mac is asleep or has not emitted a fresh event.
    /// Project them at render time so every iOS surface reaches zero at reset.
    public func effective(at now: Date = Date()) -> UsageMetric {
        let resolvedPrimary = resetDate.map { $0 <= now } == true ? usedPercent.map { _ in 0 } : usedPercent
        let resolvedWeekly = weeklyResetDate.map { $0 <= now } == true ? weeklyPercent.map { _ in 0 } : weeklyPercent

        guard resolvedPrimary != usedPercent || resolvedWeekly != weeklyPercent else {
            return self
        }

        let status: UsageStatus? = provider == .cursor
            ? UsageStatus.from(percent: [resolvedPrimary, resolvedWeekly].compactMap { $0 }.max())
            : nil
        return UsageMetric(
            provider: provider,
            usedPercent: resolvedPrimary,
            weeklyPercent: resolvedWeekly,
            primaryWindowDurationMins: primaryWindowDurationMins,
            secondaryWindowDurationMins: secondaryWindowDurationMins,
            contextWindowPercent: contextWindowPercent,
            costTodayUSD: costTodayUSD,
            resetDate: resetDate,
            weeklyResetDate: weeklyResetDate,
            status: status,
            note: note,
            dataSource: dataSource,
            measuredAt: measuredAt,
            tokenUsage: tokenUsage
        )
    }

    /// Return a copy with `tokenUsage` replaced. Used by PeluMac to attach
    /// JSONL-derived token sums to a metric whose percentages came from
    /// the Codex RPC path (RPC doesn't expose raw counts).
    public func attachingTokenUsage(_ tokenUsage: CodexTokenUsage?) -> UsageMetric {
        UsageMetric(
            provider: provider,
            usedPercent: usedPercent,
            weeklyPercent: weeklyPercent,
            primaryWindowDurationMins: primaryWindowDurationMins,
            secondaryWindowDurationMins: secondaryWindowDurationMins,
            contextWindowPercent: contextWindowPercent,
            costTodayUSD: costTodayUSD,
            resetDate: resetDate,
            weeklyResetDate: weeklyResetDate,
            status: status,
            note: note,
            dataSource: dataSource,
            measuredAt: measuredAt,
            tokenUsage: tokenUsage
        )
    }

    /// Old CloudKit payloads predate duration metadata. Their primary and
    /// secondary fields represented 5-hour and 7-day windows respectively.
    public var resolvedPrimaryWindowDurationMins: Int {
        primaryWindowDurationMins ?? 5 * 60
    }

    public var resolvedSecondaryWindowDurationMins: Int {
        secondaryWindowDurationMins ?? 7 * 24 * 60
    }

    /// Cursor's two windows are separate quota pools over the same billing
    /// cycle, so they are named by pool rather than by duration.
    public func windowTitle(secondary: Bool, compact: Bool = false) -> String {
        if provider == .cursor { return secondary ? "Auto" : "API" }
        return Self.windowLabel(
            durationMins: secondary ? resolvedSecondaryWindowDurationMins : resolvedPrimaryWindowDurationMins,
            compact: compact
        )
    }

    /// Share of the primary window already elapsed, or nil when the window
    /// has no future reset to measure against.
    public func primaryWindowElapsed(at now: Date = Date()) -> Double? {
        guard let resetDate, resetDate > now, resolvedPrimaryWindowDurationMins > 0 else { return nil }
        let duration = Double(resolvedPrimaryWindowDurationMins) * 60
        return min(1, max(0, 1 - resetDate.timeIntervalSince(now) / duration))
    }

    public var sharesResetDate: Bool {
        resetDate != nil && resetDate == weeklyResetDate
    }

    public static func windowLabel(durationMins: Int, compact: Bool = false) -> String {
        if durationMins == 24 * 60 { return compact ? "日" : "每日" }
        if durationMins % (24 * 60) == 0 {
            let days = durationMins / (24 * 60)
            return compact ? "\(days)日" : "\(days) 日"
        }
        if durationMins % 60 == 0 {
            let hours = durationMins / 60
            return compact ? "\(hours)h" : "\(hours) 小時"
        }
        return compact ? "\(durationMins)m" : "\(durationMins) 分鐘"
    }
}
