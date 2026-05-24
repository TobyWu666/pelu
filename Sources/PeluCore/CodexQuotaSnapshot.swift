import Foundation

/// Direct mirror of `GetAccountRateLimitsResponse` / `AccountRateLimitsUpdatedNotification`
/// from the Codex app-server protocol (v2). Schema dumped via
/// `codex app-server generate-json-schema --out <dir>`.
///
/// Owned by `CodexQuotaProvider`; transformed into `UsageMetric` for the
/// dashboard / CloudKit payload. Kept as a separate type so we don't lose
/// fields the existing `UsageMetric` shape doesn't carry (planType, credits).
public struct CodexQuotaSnapshot: Codable, Equatable, Sendable {
    public let rateLimits: RateLimit
    public let fetchedAt: Date
    public let source: Source

    public enum Source: String, Codable, Sendable {
        /// Live response from `account/rateLimits/read`.
        case appServerRead
        /// Server-initiated `account/rateLimits/updated` notification.
        case appServerNotification
    }

    public struct RateLimit: Codable, Equatable, Sendable {
        public let primary: Window?
        public let secondary: Window?
        public let limitId: String?
        public let limitName: String?
        public let planType: PlanType?
        public let credits: Credits?
        public let rateLimitReachedType: String?

        public init(
            primary: Window?,
            secondary: Window?,
            limitId: String? = nil,
            limitName: String? = nil,
            planType: PlanType? = nil,
            credits: Credits? = nil,
            rateLimitReachedType: String? = nil
        ) {
            self.primary = primary
            self.secondary = secondary
            self.limitId = limitId
            self.limitName = limitName
            self.planType = planType
            self.credits = credits
            self.rateLimitReachedType = rateLimitReachedType
        }
    }

    public struct Window: Codable, Equatable, Sendable {
        public let usedPercent: Int
        public let windowDurationMins: Int?
        /// Unix epoch seconds. nil when the server hasn't computed a reset
        /// boundary yet (rare; observed mid-rollout).
        public let resetsAt: Int64?

        public init(usedPercent: Int, windowDurationMins: Int? = nil, resetsAt: Int64? = nil) {
            self.usedPercent = usedPercent
            self.windowDurationMins = windowDurationMins
            self.resetsAt = resetsAt
        }

        public var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    }

    public struct Credits: Codable, Equatable, Sendable {
        public let hasCredits: Bool
        public let unlimited: Bool
        /// String because the server returns decimal-as-string (e.g. "0",
        /// "12.50"). Avoid Double rounding for currency-shaped values.
        public let balance: String?
    }

    /// ChatGPT plan tier reported by the server. Plus / Pro / Team / etc.
    /// `.unknown` is the schema's escape hatch for future tiers — decode
    /// into it instead of failing the whole snapshot when OpenAI adds one.
    public enum PlanType: String, Codable, Sendable {
        case free, go, plus, pro, prolite, team
        case selfServeBusinessUsageBased = "self_serve_business_usage_based"
        case business
        case enterpriseCbpUsageBased = "enterprise_cbp_usage_based"
        case enterprise, edu, unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = PlanType(rawValue: raw) ?? .unknown
        }
    }

    public init(rateLimits: RateLimit, fetchedAt: Date, source: Source) {
        self.rateLimits = rateLimits
        self.fetchedAt = fetchedAt
        self.source = source
    }

    /// Convert to the existing per-provider metric shape so the rest of Pelu
    /// (CloudKit payload, dashboard, widget) keeps working unchanged. Applies
    /// the same `resetDate < now → 0` correction as `CodexJSONLReader`.
    public func asUsageMetric(now: Date = Date()) -> UsageMetric {
        let primary = rateLimits.primary
        let secondary = rateLimits.secondary

        let primaryPercent: Double? = primary.map { window in
            if let reset = window.resetDate, reset < now { return 0 }
            return Double(window.usedPercent)
        }
        let weeklyPercent: Double? = secondary.map { window in
            if let reset = window.resetDate, reset < now { return 0 }
            return Double(window.usedPercent)
        }

        return UsageMetric(
            provider: .codex,
            usedPercent: primaryPercent,
            weeklyPercent: weeklyPercent,
            resetDate: primary?.resetDate,
            weeklyResetDate: secondary?.resetDate,
            dataSource: .officialQuota,
            measuredAt: fetchedAt
        )
    }
}
