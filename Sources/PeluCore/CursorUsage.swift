import Foundation
#if os(macOS)
import SQLite3
#endif

/// Parses `GET https://cursor.com/api/usage-summary`, the undocumented
/// endpoint behind cursor.com/dashboard. Cursor splits a plan's included
/// usage into two pools over one billing cycle: named / API models
/// (`apiPercentUsed`) and Auto + Composer (`autoPercentUsed`). Either can run
/// out on its own, so both are kept and status follows the fuller one.
public struct CursorUsageParser: Sendable {
    public init() {}

    public func parse(data: Data, fetchedAt: Date, generatedAt: Date = Date()) throws -> UsageMetric {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let start = Self.date(object["billingCycleStart"]),
              let end = Self.date(object["billingCycleEnd"]), end > start
        else { throw ParserError.unreadableJSON }

        let cycleMins = Int((end.timeIntervalSince(start) / 60).rounded())
        if (object["isUnlimited"] as? Bool) == true {
            return UsageMetric(
                provider: .cursor,
                usedPercent: nil,
                primaryWindowDurationMins: cycleMins,
                secondaryWindowDurationMins: cycleMins,
                resetDate: end,
                weeklyResetDate: end,
                note: "目前方案不限用量",
                dataSource: .officialQuota,
                measuredAt: fetchedAt
            )
        }

        let plan = (object["individualUsage"] as? [String: Any])?["plan"] as? [String: Any]
        // Team seats may omit `plan`; the dashboard messages carry the same numbers.
        let api = (plan?["apiPercentUsed"] as? NSNumber)?.doubleValue
            ?? Self.percent(in: object["namedModelSelectedDisplayMessage"])
        let auto = (plan?["autoPercentUsed"] as? NSNumber)?.doubleValue
            ?? Self.percent(in: object["autoModelSelectedDisplayMessage"])
        guard api != nil || auto != nil else { throw ParserError.unreadableJSON }

        return UsageMetric(
            provider: .cursor,
            usedPercent: api,
            weeklyPercent: auto,
            primaryWindowDurationMins: cycleMins,
            secondaryWindowDurationMins: cycleMins,
            resetDate: end,
            weeklyResetDate: end,
            status: UsageStatus.from(percent: [api, auto].compactMap { $0 }.max()),
            dataSource: .officialQuota,
            measuredAt: fetchedAt
        ).effective(at: generatedAt)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// "You've used 10% of your included API usage" → 10.
    private static func percent(in value: Any?) -> Double? {
        guard let string = value as? String,
              let range = string.range(of: #"\d+(\.\d+)?(?=%)"#, options: .regularExpression)
        else { return nil }
        return Double(string[range])
    }
}

#if os(macOS)
/// Polls Cursor's usage summary with the session token the Cursor app keeps
/// in its own state database. Never signs in or refreshes on Cursor's behalf:
/// an expired token waits until Cursor next runs and writes a new one.
public final class CursorUsageClient: @unchecked Sendable {
    public typealias UpdateHandler = @Sendable () -> Void

    private static let endpoint = URL(string: "https://cursor.com/api/usage-summary")!
    private static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    /// Spacing while Cursor is writing its state (the app is open and in use).
    static let activeInterval: TimeInterval = 300
    static let idleInterval: TimeInterval = 900
    private static let backoffSeconds: [TimeInterval] = [300, 900, 1800, 3600]

    private let queue = DispatchQueue(label: "org.tobywu.pelu.cursor-usage", qos: .utility)
    private let userAgent: String
    private let session: URLSession

    // Owned by `queue`.
    private var token: Token?
    private var nextAttemptAt = Date.distantPast
    private var lastAttemptAt: Date?
    private var consecutiveFailures = 0
    private var isInFlight = false
    private let stateLock = NSLock()
    private var latest: (data: Data, fetchedAt: Date)?
    private var problem: String?

    public var onUpdate: UpdateHandler?

    public init(clientVersion: String) {
        userAgent = "Pelu/\(clientVersion)"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    /// Cursor has been installed and signed in on this Mac at some point.
    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.databaseURL.path)
    }

    /// Latest reading, or a placeholder whose note explains what is missing.
    public func currentMetric(now: Date = Date()) -> UsageMetric {
        let (latest, problem) = stateLock.withLock { (latest, problem) }
        if let latest, let metric = try? CursorUsageParser().parse(data: latest.data, fetchedAt: latest.fetchedAt, generatedAt: now) {
            return metric
        }
        return UsageMetric(provider: .cursor, usedPercent: nil, note: problem ?? "正在讀取 Cursor 用量")
    }

    public func refreshIfDue() {
        queue.async { [weak self] in
            guard let self, !self.isInFlight, self.isAvailable else { return }
            let now = Date()
            guard ClaudeUsageAPIClient.isDue(
                now: now,
                nextAttemptAt: self.nextAttemptAt,
                lastAttemptAt: self.lastAttemptAt,
                lastActivityAt: Self.latestStateWrite(),
                activeInterval: Self.activeInterval,
                idleInterval: Self.idleInterval
            ) else { return }
            guard let token = self.currentToken(now: now) else {
                self.nextAttemptAt = now.addingTimeInterval(Self.backoffSeconds[0])
                self.onUpdate?()
                return
            }
            self.isInFlight = true
            self.lastAttemptAt = now
            self.fetch(token: token)
        }
    }

    private static func latestStateWrite() -> Date? {
        let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
        return [databaseURL, wal]
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    private func fetch(token: Token) {
        var request = URLRequest(url: Self.endpoint)
        request.setValue(token.cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            self.queue.async {
                self.isInFlight = false
                let now = Date()
                if status == 200, let data,
                   (try? CursorUsageParser().parse(data: data, fetchedAt: now, generatedAt: now)) != nil {
                    self.stateLock.withLock {
                        self.latest = (data, now)
                        self.problem = nil
                    }
                    self.consecutiveFailures = 0
                    self.nextAttemptAt = .distantPast
                    self.onUpdate?()
                    return
                }
                // Cursor probably signed out or rotated its session; re-read it next time.
                if status == 401 || status == 403 { self.token = nil }
                self.consecutiveFailures += 1
                let delay = Self.backoffSeconds[min(self.consecutiveFailures, Self.backoffSeconds.count) - 1]
                self.nextAttemptAt = now.addingTimeInterval(delay)
                self.setProblem(status == 401 || status == 403 ? "Cursor 登入已失效，請開啟 Cursor 重新登入" : "暫時讀不到 Cursor 用量")
                NSLog("Pelu Cursor usage failed (HTTP \(status), \(error?.localizedDescription ?? "-")), retry in \(Int(delay))s")
            }
        }.resume()
    }

    private func setProblem(_ message: String) {
        stateLock.withLock { problem = message }
    }

    private func currentToken(now: Date) -> Token? {
        if let token, token.expiresAt.map({ $0 > now }) ?? true { return token }
        token = Self.readToken()
        guard let token else {
            setProblem("請先在 Cursor 登入")
            return nil
        }
        guard token.expiresAt.map({ $0 > now }) ?? true else {
            setProblem("Cursor 登入已過期，請開啟 Cursor")
            return nil
        }
        return token
    }

    struct Token {
        let cookie: String
        let expiresAt: Date?
    }

    /// The dashboard authenticates with `WorkosCursorSessionToken=<user>::<jwt>`,
    /// where `<user>` is the JWT subject after its `provider|` prefix.
    static func makeToken(jwt: String) -> Token? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = claims["sub"] as? String,
              let user = subject.split(separator: "|").last, !user.isEmpty
        else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let value = "\(user)::\(jwt)".addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let expiresAt = (claims["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return Token(cookie: "WorkosCursorSessionToken=\(value)", expiresAt: expiresAt)
    }

    private static func readToken() -> Token? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0)
        else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        guard let jwt = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !jwt.isEmpty
        else { return nil }
        return makeToken(jwt: jwt)
    }
}
#endif // os(macOS)
