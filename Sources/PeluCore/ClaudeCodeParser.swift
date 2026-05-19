import Foundation

public struct ClaudeCodeParser: Sendable {
    public init() {}

    /// Parses `~/.claude/usag-status.json` written by Claude Code's statusLine hook.
    public func parse(data: Data, generatedAt: Date = Date()) throws -> UsageMetric {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParserError.unreadableJSON
        }

        // Real schema (Claude Code 2.x): nested rate_limits / context_window / cost
        let rateLimits = object["rate_limits"] as? [String: Any]
        let fiveHour = rateLimits?["five_hour"] as? [String: Any]
        let contextWindowObj = object["context_window"] as? [String: Any]
        let costObj = object["cost"] as? [String: Any]

        let sevenDay = rateLimits?["seven_day"] as? [String: Any]

        let fiveHourPercent = fiveHour?["used_percentage"] as? Double
        let weeklyPercent = sevenDay?["used_percentage"] as? Double
        let resetDate: Date? = (fiveHour?["resets_at"] as? Double).map {
            Date(timeIntervalSince1970: $0)
        }
        let weeklyResetDate: Date? = (sevenDay?["resets_at"] as? Double).map {
            Date(timeIntervalSince1970: $0)
        }
        let contextWindowPercent = contextWindowObj?["used_percentage"] as? Double
        let cost: Decimal? = (costObj?["total_cost_usd"] as? Double).map { Decimal($0) }

        // Fallback: loose key scan for older or unknown schema variants.
        // Try the rate_limits.five_hour subtree first (handles type drift like String "2.5%"
        // where the direct `as? Double` cast fails), then fall back to the whole object.
        let percentKeys: Set<String> = [
            "percent", "percentage", "usedpercentage", "usagepercent",
            "usedpercent", "limitpercent",
        ]
        let usedPercent: Double? = fiveHourPercent
            ?? (fiveHour.flatMap { LooseUsageValueReader.firstDouble(in: $0, matching: percentKeys) })
            ?? LooseUsageValueReader.firstDouble(in: object, matching: percentKeys)
        let weeklyPercentResolved: Double? = weeklyPercent
            ?? (sevenDay.flatMap { LooseUsageValueReader.firstDouble(in: $0, matching: percentKeys) })
        let costFallback: Decimal? = cost ?? LooseUsageValueReader.firstDecimal(
            in: object,
            matching: ["cost", "costtoday", "costtodayusd", "totalcost", "totalcostusd", "todaycostusd"]
        )
        let resetFallback: Date? = resetDate ?? LooseUsageValueReader.firstDate(
            in: object,
            matching: ["reset", "resetat", "resetdate", "resetsat", "resettime"]
        )

        return UsageMetric(
            provider: .claudeCode,
            usedPercent: usedPercent,
            weeklyPercent: weeklyPercentResolved,
            contextWindowPercent: contextWindowPercent,
            costTodayUSD: costFallback,
            resetDate: resetFallback,
            weeklyResetDate: weeklyResetDate,
            note: usedPercent == nil ? "Claude status JSON 尚未包含可辨識百分比" : nil
        )
    }
}
