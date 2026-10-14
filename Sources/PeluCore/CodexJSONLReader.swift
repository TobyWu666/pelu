import Darwin
import Foundation

public struct CodexJSONLSnapshot: Sendable {
    public let metric: UsageMetric
    public let tokenUsage: CodexTokenUsage?
    public let latestTokenCountFileURL: URL?
    public let activeFileURLs: [URL]
    /// Only the most recently modified files need immediate notifications;
    /// the periodic refresh still accounts for every active session.
    public let watchedFileURLs: [URL]
}

/// Reads Codex quota estimates and cumulative session totals without loading
/// conversation bodies into memory. Own this reader on one serial queue.
public final class CodexJSONLReader {
    struct Limits {
        var readChunkBytes = 64 * 1024
        var maximumLineBytes = 1024 * 1024
        var maximumCachedFiles = 1024
        var maximumWatchedFiles = 128
    }

    struct ReadStatistics {
        /// Bytes passed through the line scanner; validation reads are separate.
        var bytesRead = 0
        var validationBytesRead = 0
        var maximumBufferedLineBytes = 0
        var oversizedLinesSkipped = 0
    }

    private let codexDir: URL
    private let now: () -> Date
    private let limits: Limits
    private var cache: [String: CachedFile] = [:]
    private(set) var lastReadStatistics = ReadStatistics()
    var cachedFileCount: Int { cache.count }

    public convenience init(
        codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        now: @escaping () -> Date = Date.init
    ) {
        self.init(codexDirectory: codexDirectory, now: now, limits: Limits())
    }

    init(codexDirectory: URL, now: @escaping () -> Date, limits: Limits) {
        precondition(limits.readChunkBytes > 0 && limits.maximumLineBytes > 0)
        precondition(limits.maximumCachedFiles > 0 && limits.maximumWatchedFiles > 0)
        codexDir = codexDirectory
        self.now = now
        self.limits = limits
    }

    /// Scan once for both quota and tokens. Unchanged files reuse compact
    /// decoded results; growing files resume at the last complete line.
    public func readSnapshot(withinHours: Double = 24) -> CodexJSONLSnapshot {
        lastReadStatistics = ReadStatistics()
        let date = now()
        let files = candidateFiles(at: date)
        // Keep a bounded cache of the newest files, without capping the sum.
        let retainedPaths = Set(files.prefix(limits.maximumCachedFiles).map { $0.url.path })
        cache = cache.filter { retainedPaths.contains($0.key) }
        let cutoff = date.addingTimeInterval(-withinHours * 3600)
        var activeFiles: [URL] = []
        var newest: TokenCountMatch?
        var newestFile: URL?
        var total = CodexTokenUsage.zero
        var anyContribution = false

        for file in files {
            let isActive = file.stamp.modifiedAt >= cutoff
            if isActive { activeFiles.append(file.url) }
            guard let match = latestMatch(in: file, retain: retainedPaths.contains(file.url.path)) else { continue }
            if newest == nil || match.timestamp > newest!.timestamp {
                newest = match
                newestFile = file.url
            }
            if isActive, let usage = match.tokens, !usage.isEmpty {
                total = total.adding(usage)
                anyContribution = true
            }
        }

        return CodexJSONLSnapshot(
            metric: metric(from: newest, at: date),
            tokenUsage: anyContribution ? total : nil,
            latestTokenCountFileURL: newestFile,
            activeFileURLs: activeFiles,
            watchedFileURLs: Array(activeFiles.prefix(limits.maximumWatchedFiles))
        )
    }

    public func readLatestMetric() -> UsageMetric { readSnapshot().metric }
    public func latestTokenCountFileURL() -> URL? { readSnapshot().latestTokenCountFileURL }
    public func recentlyActiveJSONLFiles(withinHours: Double = 24) -> [URL] {
        readSnapshot(withinHours: withinHours).activeFileURLs
    }
    public func summedTokenUsage(withinHours: Double = 24) -> CodexTokenUsage? {
        readSnapshot(withinHours: withinHours).tokenUsage
    }

    public func currentSessionsDirectory(now: Date = Date()) -> URL {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        return codexDir.appendingPathComponent(String(format: "sessions/%d/%02d/%02d", components.year!, components.month!, components.day!))
    }

    private struct FileStamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: UInt64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init?(_ value: stat) {
            guard value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { return nil }
            device = value.st_dev
            inode = value.st_ino
            size = UInt64(value.st_size)
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }

        var modifiedAt: Date {
            Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
        }

        static func read(at url: URL) -> FileStamp? {
            var value = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return fstatat(AT_FDCWD, path, &value, 0)
            }
            return result == 0 ? FileStamp(value) : nil
        }

        static func read(from handle: FileHandle) -> FileStamp? {
            var value = stat()
            return fstat(handle.fileDescriptor, &value) == 0 ? FileStamp(value) : nil
        }
    }

    private struct Candidate {
        let url: URL
        let stamp: FileStamp
    }

    private struct RateWindow {
        let percent: Double?
        let reset: Date?
        let durationMinutes: Int?

        init(_ object: [String: Any]?) {
            percent = object?["used_percent"] as? Double
            reset = (object?["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            durationMinutes = ["window_duration_mins", "window_minutes", "windowDurationMins"]
                .compactMap { (object?[$0] as? NSNumber)?.intValue }.first
        }

        func percent(at now: Date) -> Double? {
            guard let percent else { return nil }
            return reset.map { $0 < now } == true ? 0 : percent
        }
    }

    private struct TokenCountMatch {
        let timestamp: Date
        let usesFileTimestamp: Bool
        let tokens: CodexTokenUsage?
        let primary: RateWindow
        let secondary: RateWindow
    }

    private struct CachedFile {
        var stamp: FileStamp
        var resumeOffset: UInt64 = 0
        var discardingLine = false
        var committed: TokenCountMatch?
        var visible: TokenCountMatch?
        var hasFileTimestamp = false
        var boundaryChecksum: UInt64?
    }

    private func candidateFiles(at date: Date) -> [Candidate] {
        let calendar = Calendar.current
        let earliest = calendar.date(byAdding: .day, value: -8, to: date) ?? date
        var files: [Candidate] = []
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { continue }
            let directory = currentSessionsDirectory(now: day)
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "jsonl" {
                if let stamp = FileStamp.read(at: url) { files.append(Candidate(url: url, stamp: stamp)) }
            }
        }
        let archived = codexDir.appendingPathComponent("archived_sessions")
        let urls = (try? FileManager.default.contentsOfDirectory(at: archived, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "jsonl" {
            if let stamp = FileStamp.read(at: url), stamp.modifiedAt >= earliest {
                files.append(Candidate(url: url, stamp: stamp))
            }
        }
        return files.sorted {
            if $0.stamp.modifiedAt != $1.stamp.modifiedAt { return $0.stamp.modifiedAt > $1.stamp.modifiedAt }
            return $0.url.path < $1.url.path
        }
    }

    private func latestMatch(in file: Candidate, retain: Bool) -> TokenCountMatch? {
        let path = file.url.path
        if let cached = cache[path], cached.stamp == file.stamp { return cached.visible }
        do {
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            guard let stamp = FileStamp.read(from: handle) else { return nil }
            var state = CachedFile(stamp: stamp)
            if let previous = cache[path], previous.stamp.device == stamp.device,
               previous.stamp.inode == stamp.inode, stamp.size > previous.stamp.size,
               !previous.hasFileTimestamp,
               previous.boundaryChecksum == (try boundaryChecksum(handle: handle, size: previous.stamp.size)) {
                state = previous
                state.stamp = stamp
            }
            try scan(handle: handle, state: &state)
            if retain {
                state.boundaryChecksum = try boundaryChecksum(handle: handle, size: stamp.size)
                cache[path] = state
            }
            return state.visible
        } catch {
            cache.removeValue(forKey: path)
            return nil
        }
    }

    /// Size growth alone cannot distinguish an append from an in-place rewrite.
    /// Check at most 4 KiB of the old boundaries; cache only the checksum,
    /// never those conversation bytes. This is a change detector, not a
    /// cryptographic integrity check. Codex normally writes append-only logs.
    private func boundaryChecksum(handle: FileHandle, size: UInt64) throws -> UInt64 {
        let count = Int(min(size, 2048))
        var checksum: UInt64 = 14695981039346656037
        guard count > 0 else { return checksum }
        let offsets: [UInt64] = size > UInt64(count) ? [0, size - UInt64(count)] : [0]
        for offset in offsets {
            try handle.seek(toOffset: offset)
            let bytes = try autoreleasepool { try handle.read(upToCount: count) ?? Data() }
            guard bytes.count == count else { throw POSIXError(.EIO) }
            lastReadStatistics.validationBytesRead += bytes.count
            for byte in bytes { checksum = (checksum ^ UInt64(byte)) &* 1099511628211 }
        }
        return checksum
    }

    private func scan(handle: FileHandle, state: inout CachedFile) throws {
        try handle.seek(toOffset: state.resumeOffset)
        var position = state.resumeOffset
        var lineStart = position
        var line = Data()
        // Read only the size observed at open, even if a writer keeps appending.
        while position < state.stamp.size {
            let count = Int(min(UInt64(limits.readChunkBytes), state.stamp.size - position))
            let chunk = try autoreleasepool { try handle.read(upToCount: count) ?? Data() }
            guard !chunk.isEmpty else { break }
            lastReadStatistics.bytesRead += chunk.count
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                let newline = chunk[cursor...].firstIndex(of: 10)
                let end = newline ?? chunk.endIndex
                let fragmentCount = end - cursor
                if !state.discardingLine {
                    if line.count + fragmentCount > limits.maximumLineBytes {
                        line.removeAll(keepingCapacity: true)
                        state.discardingLine = true
                        lastReadStatistics.oversizedLinesSkipped += 1
                    } else {
                        line.append(contentsOf: chunk[cursor..<end])
                        lastReadStatistics.maximumBufferedLineBytes = max(lastReadStatistics.maximumBufferedLineBytes, line.count)
                    }
                }
                position += UInt64(fragmentCount)
                if newline != nil {
                    if !state.discardingLine { accept(line, in: &state) }
                    line.removeAll(keepingCapacity: true)
                    state.discardingLine = false
                    position += 1
                    lineStart = position
                    cursor = end + 1
                } else {
                    cursor = end
                }
            }
        }
        state.visible = state.committed
        if state.discardingLine || line.isEmpty {
            state.resumeOffset = position
        } else {
            // Keep only an offset, not a partial conversation body in the cache.
            // A complete JSON object at EOF is visible but reread on the next append.
            state.resumeOffset = lineStart
            if let match = parse(line, modifiedAt: state.stamp.modifiedAt) {
                state.hasFileTimestamp = state.hasFileTimestamp || match.usesFileTimestamp
                if state.visible == nil || match.timestamp >= state.visible!.timestamp { state.visible = match }
            }
        }
    }

    private func accept(_ line: Data, in state: inout CachedFile) {
        guard let match = parse(line, modifiedAt: state.stamp.modifiedAt) else { return }
        state.hasFileTimestamp = state.hasFileTimestamp || match.usesFileTimestamp
        if state.committed == nil || match.timestamp >= state.committed!.timestamp { state.committed = match }
    }

    private static let tokenCountMarker = Data("\"token_count\"".utf8)

    private func parse(_ line: Data, modifiedAt: Date) -> TokenCountMatch? {
        guard line.range(of: Self.tokenCountMarker) != nil else { return nil }
        // Foundation's temporary JSON objects must not accumulate until the
        // end of an entire session scan (or a burst of queued refreshes).
        return autoreleasepool {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count" else { return nil }
            let timestamp = (object["timestamp"] as? String).flatMap(Self.parseTimestamp)
            let info = payload["info"] as? [String: Any]
            let totals = info?["total_token_usage"] as? [String: Any]
            let tokens = totals.map {
                CodexTokenUsage(inputTokens: Self.integer($0["input_tokens"]),
                                cachedInputTokens: Self.integer($0["cached_input_tokens"]),
                                outputTokens: Self.integer($0["output_tokens"]))
            }
            let rateLimits = payload["rate_limits"] as? [String: Any]
            return TokenCountMatch(timestamp: timestamp ?? modifiedAt, usesFileTimestamp: timestamp == nil,
                                   tokens: tokens, primary: RateWindow(rateLimits?["primary"] as? [String: Any]),
                                   secondary: RateWindow(rateLimits?["secondary"] as? [String: Any]))
        }
    }

    private static func integer(_ value: Any?) -> Int {
        if let integer = value as? Int { return integer }
        guard let double = value as? Double, double.isFinite,
              double >= Double(Int.min), double < Double(Int.max) else { return 0 }
        return Int(double)
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plainFormatter = ISO8601DateFormatter()

    private func metric(from match: TokenCountMatch?, at date: Date) -> UsageMetric {
        guard let match else { return UsageMetric(provider: .codex, usedPercent: nil, note: "今日無 Codex 使用紀錄") }
        return UsageMetric(provider: .codex, usedPercent: match.primary.percent(at: date),
                           weeklyPercent: match.secondary.percent(at: date),
                           primaryWindowDurationMins: match.primary.durationMinutes,
                           secondaryWindowDurationMins: match.secondary.durationMinutes,
                           resetDate: match.primary.reset, weeklyResetDate: match.secondary.reset,
                           dataSource: .localEstimate, measuredAt: match.timestamp)
    }
}
