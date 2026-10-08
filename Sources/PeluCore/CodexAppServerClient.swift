// Mac-only — relies on `Foundation.Process` / `Pipe` / `FileHandle`-as-stream,
// which iOS doesn't ship. The Codex quota provider that uses this client is
// also Mac-only; iOS reads the CloudKit payload PeluMac writes.
#if os(macOS)
import Foundation
import AppKit

/// Thin JSON-RPC 2.0 client over stdio against `codex app-server`.
///
/// The protocol is line-delimited JSON (one message per line, both ways) —
/// verified during the Phase 1 spike against `codex-cli 0.131.0-alpha.9`.
/// We only model the slice Pelu needs: `initialize` + `account/rateLimits/read`
/// requests, `account/rateLimits/updated` notifications. Everything else is
/// dropped on the floor.
///
/// Lifecycle: explicit `start()` spawns the child process and runs the
/// initialize handshake; `stop()` closes stdin and waits up to 2 s before
/// terminating. `CodexQuotaProvider` replaces this client if reads fail.
public actor CodexAppServerClient {
    public struct ClientInfo: Sendable {
        public let name: String
        public let version: String
        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    public enum ClientError: Error, Sendable {
        case binaryNotFound
        case processFailedToStart(reason: String)
        case notInitialized
        case processExited(code: Int32?)
        case rpcError(code: Int, message: String)
        case decodeFailure(String)
        case timeout
    }

    /// Where notifications go. Set once before `start()`; the actor invokes it
    /// on a detached task per notification to avoid back-pressuring the read
    /// loop. Pass `nil` to ignore notifications entirely.
    public typealias NotificationHandler = @Sendable (String, Data) async -> Void

    private let clientInfo: ClientInfo
    private let binaryURL: URL
    private let notificationHandler: NotificationHandler?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var nextRequestId: Int = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]

    public init(
        clientInfo: ClientInfo,
        binaryURL: URL,
        notificationHandler: NotificationHandler? = nil
    ) {
        self.clientInfo = clientInfo
        self.binaryURL = binaryURL
        self.notificationHandler = notificationHandler
    }

    // MARK: - Binary discovery

    /// Locate the `codex` binary. Preference order:
    ///  1. ChatGPT/Codex desktop app's bundled binary (see `bundledBinary(in:)`)
    ///  2. Per-user ChatGPT/Codex desktop app install
    ///  3. NSWorkspace lookup by bundle id (handles non-standard install dirs)
    ///  4. Common CLI paths (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.volta/bin`)
    ///
    /// Returns `nil` when none exist — callers should fall back to the
    /// jsonl reader and surface a "Codex CLI not detected" hint to the user.
    public static func locateBinary() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let appBundles = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/Codex.app"),
            home.appendingPathComponent("Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/Codex.app"),
        ]
        for app in appBundles {
            if let url = bundledBinary(in: app, fileManager: fm) { return url }
        }

        #if canImport(AppKit)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
           let url = bundledBinary(in: appURL, fileManager: fm) {
            return url
        }
        #endif

        let cliPaths = [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent(".volta/bin/codex"),
        ]
        for url in cliPaths where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    /// ChatGPT.app (formerly Codex.app, same `com.openai.codex` bundle id)
    /// ships the CLI as a nested `CodexCLI.app`; older Codex.app builds put
    /// it directly in Resources. Prefer the real Mach-O over the
    /// `codex-cli/bin/codex` shell wrapper.
    static func bundledBinary(in app: URL, fileManager fm: FileManager = .default) -> URL? {
        let candidates = [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex-cli/bin/codex",
            "Contents/Resources/codex",
        ]
        for path in candidates {
            let url = app.appendingPathComponent(path)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - Lifecycle

    public func start() async throws {
        if process?.isRunning == true { return }
        try spawnProcess()
        _ = try await initializeHandshake()
    }

    public func stop() async {
        readTask?.cancel()
        readTask = nil
        try? stdinHandle?.close()
        stdinHandle = nil

        if let proc = process, proc.isRunning {
            // Give it 2s to exit cleanly after stdin close, then SIGTERM.
            let deadline = Date().addingTimeInterval(2)
            while proc.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if proc.isRunning { proc.terminate() }
        }
        process = nil

        for id in Array(pending.keys) {
            resolvePending(id: id, with: .failure(ClientError.processExited(code: nil)))
        }
    }

    // MARK: - Public RPC

    /// Send `account/rateLimits/read`. Empty params, returns the raw v2
    /// `GetAccountRateLimitsResponse` decoded into our snapshot.
    public func readRateLimits() async throws -> CodexQuotaSnapshot {
        let data = try await sendRequest(method: "account/rateLimits/read", params: [:] as [String: String])
        let response = try Self.decoder.decode(GetAccountRateLimitsResponse.self, from: data)
        return CodexQuotaSnapshot(
            rateLimits: response.rateLimits,
            fetchedAt: Date(),
            source: .appServerRead
        )
    }

    // MARK: - Internals

    private func spawnProcess() throws {
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["app-server"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            throw ClientError.processFailedToStart(reason: String(describing: error))
        }

        process = proc
        stdinHandle = stdin.fileHandleForWriting

        readTask = Task { [weak self] in
            await self?.runReadLoop(handle: stdout.fileHandleForReading)
        }

        // Drain stderr so the OS pipe buffer can't fill up and stall the child.
        // Surface contents via NSLog so we can debug stuck initialize / spawn.
        Task.detached {
            let h = stderr.fileHandleForReading
            while !Task.isCancelled {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                if let text = String(data: chunk, encoding: .utf8) {
                    NSLog("Pelu Codex stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        }
    }

    private func initializeHandshake() async throws -> Data {
        struct InitParams: Encodable {
            struct ClientInfo: Encodable { let name: String; let version: String }
            let clientInfo: ClientInfo
        }
        let params = InitParams(clientInfo: .init(name: clientInfo.name, version: clientInfo.version))
        return try await sendRequest(method: "initialize", params: params)
    }

    /// Per-request timeout. Plan §13 recommends 10s; we keep that as default.
    /// A hung peer (network stall, child stuck) would otherwise wedge the
    /// continuation forever and back-pressure every later request behind it.
    private static let defaultRequestTimeout: TimeInterval = 10

    private func sendRequest<P: Encodable>(
        method: String,
        params: P,
        timeout: TimeInterval = CodexAppServerClient.defaultRequestTimeout
    ) async throws -> Data {
        guard let stdin = stdinHandle else { throw ClientError.notInitialized }
        nextRequestId += 1
        let id = nextRequestId

        let envelope = RequestEnvelope(id: id, method: method, params: params)
        let payload = try Self.encoder.encode(envelope)

        // Schedule timeout in parallel with stdin write. resolvePending() is
        // a no-op for the loser, so whichever path completes second drops
        // cleanly.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.resolvePending(id: id, with: .failure(ClientError.timeout))
        }

        do {
            let response = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                pending[id] = cont
                do {
                    try stdin.write(contentsOf: payload + Data([0x0A]))  // newline-terminated
                } catch {
                    pending.removeValue(forKey: id)
                    cont.resume(throwing: ClientError.processExited(code: nil))
                }
            }
            timeoutTask.cancel()
            return response
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    /// Single funnel for resolving a pending request. Idempotent — the second
    /// caller (e.g. timeout firing after a late response arrived) sees an
    /// empty entry and bails. dispatch() and the timeout Task both come
    /// through here.
    private func resolvePending(id: Int, with result: Result<Data, Error>) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        switch result {
        case .success(let data): cont.resume(returning: data)
        case .failure(let error): cont.resume(throwing: error)
        }
    }

    /// Reads stdout off-actor so the sync `availableData` calls don't pin the
    /// actor's executor. If this were actor-isolated, the very first read
    /// would block the actor in a syscall and the matching `sendRequest`
    /// continuation could never re-enter to resume — classic deadlock that
    /// looks like "spawn succeeded but initialize never replies".
    nonisolated private func runReadLoop(handle: FileHandle) async {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk = handle.availableData
            if chunk.isEmpty {
                // Empty read = EOF = child closed stdout = process gone.
                await handleStdoutEOF()
                return
            }
            buffer.append(chunk)

            // Split on newlines; keep partial trailing fragment in buffer.
            while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newlineIdx]
                buffer.removeSubrange(buffer.startIndex...newlineIdx)
                guard !lineData.isEmpty else { continue }
                await dispatch(messageData: Data(lineData))
            }
        }
    }

    private func handleStdoutEOF() {
        // The child closed stdout, but Foundation considers the task "still
        // running" until it has fully reaped — reading terminationStatus in
        // that window throws NSInvalidArgumentException which surfaces as
        // SIGABRT. Skip the exit code if the task hasn't actually exited yet;
        // callers already handle a nil code.
        let exitCode: Int32?
        if let proc = process, !proc.isRunning {
            exitCode = proc.terminationStatus
        } else {
            exitCode = nil
        }
        for id in Array(pending.keys) {
            resolvePending(id: id, with: .failure(ClientError.processExited(code: exitCode)))
        }
    }

    private func dispatch(messageData: Data) async {
        // Peek at top-level fields to decide response vs notification without
        // forcing a full Codable round-trip of every message shape.
        guard let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
            return
        }

        if let id = obj["id"] as? Int {
            if let error = obj["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? -1
                let message = error["message"] as? String ?? "unknown"
                resolvePending(id: id, with: .failure(ClientError.rpcError(code: code, message: message)))
                return
            }
            // Re-encode just the `result` field so the caller can decode its
            // own response type from it.
            let resultData: Data
            if let result = obj["result"] {
                resultData = (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
            } else {
                resultData = Data("{}".utf8)
            }
            resolvePending(id: id, with: .success(resultData))
            return
        }

        if let method = obj["method"] as? String, obj["id"] == nil {
            guard let handler = notificationHandler else { return }
            let paramsData: Data
            if let params = obj["params"] {
                paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
            } else {
                paramsData = Data()
            }
            Task.detached { await handler(method, paramsData) }
        }
    }

    // MARK: - Codable helpers

    private struct GetAccountRateLimitsResponse: Decodable {
        let rateLimits: CodexQuotaSnapshot.RateLimit
    }

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()
}

private struct RequestEnvelope<E: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: E
}

#endif // os(macOS)
