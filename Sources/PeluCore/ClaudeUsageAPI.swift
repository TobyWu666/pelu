import Foundation
#if canImport(Security)
import Security
#endif

/// Parses the response of `GET https://api.anthropic.com/api/oauth/usage`,
/// the endpoint behind Claude Code's `/usage`. Unlike the statusLine hook it
/// reflects usage from every Claude surface (terminal, IDE extensions,
/// desktop, claude.ai), so it is the primary Claude source on the Mac.
public struct ClaudeUsageAPIParser: Sendable {
    public init() {}

    /// `generatedAt` is "now" for reset checks; `fetchedAt` is when the
    /// response arrived and becomes the metric's `measuredAt`.
    public func parse(data: Data, fetchedAt: Date, generatedAt: Date = Date()) throws -> UsageMetric {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParserError.unreadableJSON
        }
        let fiveHour = object["five_hour"] as? [String: Any]
        let sevenDay = object["seven_day"] as? [String: Any]
        let primary = (fiveHour?["utilization"] as? NSNumber)?.doubleValue
        let secondary = (sevenDay?["utilization"] as? NSNumber)?.doubleValue
        guard primary != nil || secondary != nil else { throw ParserError.unreadableJSON }

        let resetDate = Self.date(fiveHour?["resets_at"])
        let weeklyResetDate = Self.date(sevenDay?["resets_at"])
        return UsageMetric(
            provider: .claudeCode,
            usedPercent: primary,
            weeklyPercent: secondary,
            primaryWindowDurationMins: 300,
            secondaryWindowDurationMins: 10080,
            resetDate: resetDate,
            weeklyResetDate: weeklyResetDate,
            dataSource: .officialQuota,
            measuredAt: fetchedAt
        ).effective(at: generatedAt)
    }

    /// Prefer whichever official reading is newer. The API has no session
    /// context or cost, so those stay from the hook when it has them.
    public static func merge(api: UsageMetric?, hook: UsageMetric) -> UsageMetric {
        guard let api, api.usedPercent != nil || api.weeklyPercent != nil else { return hook }
        if hook.usedPercent != nil, let hookAt = hook.measuredAt, let apiAt = api.measuredAt, hookAt > apiAt {
            return hook
        }
        return UsageMetric(
            provider: .claudeCode,
            usedPercent: api.usedPercent,
            weeklyPercent: api.weeklyPercent,
            primaryWindowDurationMins: api.primaryWindowDurationMins,
            secondaryWindowDurationMins: api.secondaryWindowDurationMins,
            contextWindowPercent: hook.contextWindowPercent,
            costTodayUSD: hook.costTodayUSD,
            resetDate: api.resetDate,
            weeklyResetDate: api.weeklyResetDate,
            dataSource: .officialQuota,
            measuredAt: api.measuredAt
        )
    }

    // `resets_at` carries microseconds ("…T11:00:00.256519+00:00") or none.
    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        // Trim sub-millisecond digits for formatters that only take three.
        if let dot = string.firstIndex(of: "."),
           let zone = string[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let fraction = string[string.index(after: dot)..<zone].prefix(3)
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string[..<dot] + "." + fraction + string[zone...])
        }
        return nil
    }
}

#if os(macOS)
/// Polls the Claude usage endpoint with the OAuth token Claude Code keeps in
/// the login Keychain (`Claude Code-credentials`).
///
/// Never refreshes the token itself: refresh tokens rotate, so doing it here
/// could sign Claude Code out. An expired token just waits until Claude Code
/// next runs and refreshes it. If the user denies the Keychain prompt we stop
/// asking until the next launch.
///
/// The endpoint rate-limits aggressively (30–60s polling gets stuck on 429 for
/// hours, which also breaks Claude Code's own `/usage`), so polling follows
/// local Claude activity: transcripts under `~/.claude/projects` are written
/// by every Claude Code surface, terminal and IDE alike.
public final class ClaudeUsageAPIClient: @unchecked Sendable {
    public typealias UpdateHandler = @Sendable () -> Void

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    /// Minimum spacing while transcripts show new Claude activity.
    static let activeInterval: TimeInterval = 300
    /// Spacing when nothing changed locally (usage from claude.ai or other devices).
    static let idleInterval: TimeInterval = 900
    /// Local hours [2, 8) poll this many times less often.
    static let quietHours = 2..<8
    static let quietHoursFactor: Double = 2
    private static let backoffSeconds: [TimeInterval] = [300, 900, 1800, 3600]
    /// Re-reading the Keychain can prompt, so wait longer for Claude Code
    /// to refresh an expired token.
    private static let expiredTokenRetry: TimeInterval = 300

    private let queue = DispatchQueue(label: "org.tobywu.pelu.claude-usage", qos: .utility)
    private let userAgent: String
    private let session: URLSession

    // Owned by `queue`, which may block on a Keychain prompt.
    private var token: (value: String, expiresAt: Date?)?
    private var nextAttemptAt = Date.distantPast
    private var lastAttemptAt: Date?
    private var consecutiveFailures = 0
    private var isInFlight = false
    private var keychainDenied = false
    /// Behind a lock rather than `queue` so readers never wait on a prompt.
    private let latestLock = NSLock()
    private var latest: (data: Data, fetchedAt: Date)?

    public var onUpdate: UpdateHandler?

    public init(clientVersion: String) {
        userAgent = "Pelu/\(clientVersion)"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    /// Latest response parsed against `now`, or nil before the first success.
    public func latestMetric(now: Date = Date()) -> UsageMetric? {
        guard let latest = latestLock.withLock({ latest }) else { return nil }
        return try? ClaudeUsageAPIParser().parse(data: latest.data, fetchedAt: latest.fetchedAt, generatedAt: now)
    }

    /// Cheap to call on every refresh; fetches only when `isDue` says so.
    public func refreshIfDue() {
        queue.async { [weak self] in
            guard let self, !self.keychainDenied, !self.isInFlight else { return }
            let now = Date()
            guard Self.isDue(
                now: now,
                nextAttemptAt: self.nextAttemptAt,
                lastAttemptAt: self.lastAttemptAt,
                lastActivityAt: Self.latestTranscriptActivity()
            ) else { return }
            guard let token = self.currentToken() else {
                self.nextAttemptAt = now.addingTimeInterval(Self.expiredTokenRetry)
                return
            }
            self.isInFlight = true
            self.lastAttemptAt = now
            self.fetch(token: token)
        }
    }

    /// `nextAttemptAt` only carries failure backoff. Past it, fetch once the
    /// active interval has elapsed if Claude ran since the last attempt, else
    /// once the idle interval has; both stretch during quiet hours.
    static func isDue(
        now: Date, nextAttemptAt: Date, lastAttemptAt: Date?, lastActivityAt: Date?,
        calendar: Calendar = .current
    ) -> Bool {
        guard now >= nextAttemptAt else { return false }
        guard let lastAttemptAt else { return true }
        let factor = quietHours.contains(calendar.component(.hour, from: now)) ? quietHoursFactor : 1
        let hasNewActivity = lastActivityAt.map { $0 > lastAttemptAt } ?? false
        let interval = (hasNewActivity ? activeInterval : idleInterval) * factor
        return now.timeIntervalSince(lastAttemptAt) >= interval
    }

    /// Newest mtime among `~/.claude/projects/*/*.jsonl` (a few dozen files).
    private static func latestTranscriptActivity() -> Date? {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        var latest: Date?
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let date = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate else { continue }
                if latest.map({ date > $0 }) ?? true { latest = date }
            }
        }
        return latest
    }

    private func fetch(token: String) {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            self.queue.async {
                self.isInFlight = false
                let now = Date()
                if status == 200, let data,
                   (try? ClaudeUsageAPIParser().parse(data: data, fetchedAt: now, generatedAt: now)) != nil {
                    self.latestLock.withLock { self.latest = (data, now) }
                    self.consecutiveFailures = 0
                    self.nextAttemptAt = .distantPast
                    self.onUpdate?()
                    return
                }
                // 401: Claude Code probably rotated the token; re-read it next time.
                if status == 401 { self.token = nil }
                self.consecutiveFailures += 1
                let delay = Self.backoffSeconds[min(self.consecutiveFailures, Self.backoffSeconds.count) - 1]
                self.nextAttemptAt = now.addingTimeInterval(delay)
                NSLog("Pelu Claude usage API failed (HTTP \(status), \(error?.localizedDescription ?? "-")), retry in \(Int(delay))s")
            }
        }.resume()
    }

    /// Cached token while it is valid; otherwise re-read the Keychain, which
    /// may show the system access prompt (hence its own queue).
    private func currentToken() -> String? {
        let now = Date()
        if let token, token.expiresAt.map({ $0 > now }) ?? true { return token.value }
        token = readCredentials()
        guard let token, token.expiresAt.map({ $0 > now }) ?? true else { return nil }
        return token.value
    }

    private func readCredentials() -> (value: String, expiresAt: Date?)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        var data = item as? Data
        switch status {
        case errSecSuccess:
            break
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            keychainDenied = true
            NSLog("Pelu Claude usage API: Keychain access denied (\(status)); using statusLine hook only")
            return nil
        default:
            // Some installs keep credentials in a file instead of the Keychain.
            data = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json"))
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let value = oauth["accessToken"] as? String, !value.isEmpty else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return (value, expiresAt)
    }
}
#endif // os(macOS)
