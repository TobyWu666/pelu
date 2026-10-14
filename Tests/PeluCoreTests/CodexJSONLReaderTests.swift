import Foundation
import XCTest
@testable import PeluCore

final class CodexJSONLReaderTests: XCTestCase {
    func testStreamingSkipsLargeMessagesAndKeepsLatestTotals() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.event(input: 100)
        let last = try fixture.event(input: 200)
        let largeMessage = Data(("{\"type\":\"response_item\",\"text\":\"" + String(repeating: "x", count: 50_000) + "\"}\n").utf8)
        try fixture.write(first + largeMessage + Data("not JSON\n".utf8) + last)
        let reader = fixture.reader(limits: .init(readChunkBytes: 37, maximumLineBytes: 512))

        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 200)
        XCTAssertLessThanOrEqual(reader.lastReadStatistics.maximumBufferedLineBytes, 512)
        XCTAssertEqual(reader.lastReadStatistics.oversizedLinesSkipped, 1)
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 200)
        XCTAssertEqual(reader.lastReadStatistics.bytesRead, 0, "Unchanged sessions must not be reparsed")
    }

    func testAppendReadsOnlyTailAndCompletesPartialJSON() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let next = try fixture.event(input: 500)
        let split = next.count / 2
        let url = try fixture.write(try fixture.event(input: 100) + next.prefix(split))
        let reader = fixture.reader()
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 100)

        try fixture.append(Data(next.suffix(from: split)), to: url)
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 500)
        XCTAssertEqual(reader.lastReadStatistics.bytesRead, next.count)
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 500)
        XCTAssertEqual(reader.lastReadStatistics.bytesRead, 0)
    }

    func testValidLastLineWithoutNewlineRemainsVisible() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.write(Data(try fixture.event(input: 100).dropLast()))
        let reader = fixture.reader()
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 100)
        try fixture.append(Data("\n".utf8) + fixture.event(input: 200), to: url)
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 200)
    }

    func testOversizedUnfinishedLineDoesNotGetRereadOnAppend() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.write(try fixture.event(input: 100) + Data(repeating: 120, count: 20_000))
        let reader = fixture.reader(limits: .init(readChunkBytes: 43, maximumLineBytes: 512))
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 100)
        let tail = Data(repeating: 120, count: 10_000) + Data("\n".utf8) + (try fixture.event(input: 300))
        try fixture.append(tail, to: url)
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 300)
        XCTAssertEqual(reader.lastReadStatistics.bytesRead, tail.count)
        XCTAssertLessThanOrEqual(reader.lastReadStatistics.maximumBufferedLineBytes, 512)
    }

    func testTruncationAndSameSizeRewriteInvalidateCache() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.write(try fixture.event(input: 123456))
        let reader = fixture.reader()
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 123456)
        try fixture.overwrite(try fixture.event(input: 7), at: url)
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 7)
        let replacement = try fixture.event(input: 9)
        XCTAssertEqual(replacement.count, try Data(contentsOf: url).count)
        try fixture.overwrite(replacement, at: url)
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 9)
        XCTAssertEqual(reader.lastReadStatistics.bytesRead, replacement.count)
    }

    func testGrowingInPlaceRewriteIsNotMistakenForAppend() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.write(try fixture.event(input: 100))
        let reader = fixture.reader()
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 100)
        try fixture.overwrite(try fixture.event(input: 54321), at: url)
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 54321)
    }

    func testAtomicReplacementInvalidatesCacheEvenWhenFileGrows() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.write(try fixture.event(input: 100))
        let reader = fixture.reader()
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 100)
        try fixture.overwrite(try fixture.event(input: 54321), at: url, atomically: true)
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 54321)
    }

    func testTimestampOrderingAndSameTimestampLaterLineWins() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let newer = "2026-10-12T09:30:00.976Z"
        let older = "2026-10-12T09:00:00Z"
        try fixture.write(try fixture.event(input: 100, timestamp: newer)
            + fixture.event(input: 300, timestamp: newer)
            + fixture.event(input: 200, timestamp: older))
        XCTAssertEqual(fixture.reader().summedTokenUsage()?.inputTokens, 300)
    }

    func testMissingTimestampUsesCurrentMtimeAfterAppend() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.write(try fixture.event(input: 300, timestamp: "invalid")
            + fixture.event(input: 200, timestamp: "2026-10-12T09:00:00Z"))
        let reader = fixture.reader()
        XCTAssertEqual(reader.summedTokenUsage()?.inputTokens, 300)
        fixture.now = fixture.now.addingTimeInterval(120)
        try fixture.append(try fixture.event(input: 400, timestamp: "invalid"), to: url)
        let snapshot = reader.readSnapshot()
        XCTAssertEqual(snapshot.tokenUsage?.inputTokens, 400)
        XCTAssertEqual(snapshot.metric.measuredAt, fixture.now)
    }

    func testQuotaDurationsAndResetAreProjectedWithoutRereading() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reset = fixture.now.addingTimeInterval(60)
        try fixture.write(try fixture.event(rateLimits: [
            "primary": ["used_percent": 45, "resets_at": reset.timeIntervalSince1970, "window_minutes": 10080],
            "secondary": ["used_percent": 70, "resets_at": reset.timeIntervalSince1970, "windowDurationMins": 43200]
        ]))
        let reader = fixture.reader()
        let before = reader.readSnapshot().metric
        XCTAssertEqual(before.usedPercent, 45)
        XCTAssertEqual(before.weeklyPercent, 70)
        XCTAssertEqual(before.primaryWindowDurationMins, 10080)
        XCTAssertEqual(before.secondaryWindowDurationMins, 43200)
        XCTAssertEqual(before.dataSource, .localEstimate)
        fixture.now = reset.addingTimeInterval(1)
        let after = reader.readSnapshot().metric
        XCTAssertEqual(after.usedPercent, 0)
        XCTAssertEqual(after.weeklyPercent, 0)
        XCTAssertEqual(reader.lastReadStatistics.bytesRead, 0)
    }

    func testAllSessionsContributeDespiteWatcherAndCacheCaps() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for index in 0..<200 {
            try fixture.write(try fixture.event(input: 100, cached: 20, output: 10), name: "session-\(index).jsonl")
        }
        let reader = fixture.reader(limits: .init(maximumCachedFiles: 2))
        for _ in 0..<2 {
            let snapshot = reader.readSnapshot()
            XCTAssertEqual(snapshot.activeFileURLs.count, 200)
            XCTAssertEqual(snapshot.watchedFileURLs.count, 128)
            XCTAssertEqual(snapshot.tokenUsage, CodexTokenUsage(inputTokens: 20000, cachedInputTokens: 4000, outputTokens: 2000))
            XCTAssertLessThanOrEqual(reader.cachedFileCount, 2)
        }
    }

    func testRecentQuotaOutsideActiveWindowDoesNotContributeTokens() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archived = fixture.root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let url = archived.appendingPathComponent("archived.jsonl")
        try fixture.event(input: 300, rateLimits: ["primary": ["used_percent": 37]]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: fixture.now.addingTimeInterval(-2 * 86400)], ofItemAtPath: url.path)
        let snapshot = fixture.reader().readSnapshot()
        XCTAssertEqual(snapshot.metric.usedPercent, 37)
        XCTAssertNil(snapshot.tokenUsage)
        XCTAssertTrue(snapshot.activeFileURLs.isEmpty)
    }

    func testExpiredAndDeletedSessionsAreRemovedFromAggregateAndCache() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.write(try fixture.event())
        let reader = fixture.reader()
        XCTAssertNotNil(reader.summedTokenUsage())
        fixture.now = fixture.now.addingTimeInterval(25 * 3600)
        XCTAssertNil(reader.summedTokenUsage())
        try FileManager.default.removeItem(at: url)
        let snapshot = reader.readSnapshot()
        XCTAssertNil(snapshot.tokenUsage)
        XCTAssertNil(snapshot.metric.measuredAt)
        XCTAssertEqual(reader.cachedFileCount, 0)
    }

    func testLatestTokenEventWithoutTotalsDoesNotReuseOlderTotals() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let noTotals = Data("{\"timestamp\":\"2026-10-12T09:00:00.123Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null}}\n".utf8)
        try fixture.write(try fixture.event() + noTotals)
        XCTAssertNil(fixture.reader().summedTokenUsage())
    }

    private final class Fixture {
        let root: URL
        var now = ISO8601DateFormatter().date(from: "2026-10-12T10:00:00Z")!

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("pelu-reader-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func reader(limits: CodexJSONLReader.Limits = .init()) -> CodexJSONLReader {
            CodexJSONLReader(codexDirectory: root, now: { self.now }, limits: limits)
        }

        func event(input: Int = 100, cached: Int = 20, output: Int = 10,
                   timestamp: String = "2026-10-12T09:00:00.123Z", rateLimits: [String: Any]? = nil) throws -> Data {
            var payload: [String: Any] = ["type": "token_count", "info": ["total_token_usage": [
                "input_tokens": input, "cached_input_tokens": cached, "output_tokens": output
            ]]]
            if let rateLimits { payload["rate_limits"] = rateLimits }
            return try JSONSerialization.data(withJSONObject: ["timestamp": timestamp, "type": "event_msg", "payload": payload], options: [.sortedKeys]) + Data("\n".utf8)
        }

        @discardableResult
        func write(_ data: Data, name: String = "session.jsonl") throws -> URL {
            let directory = Calendar.current.dateComponents([.year, .month, .day], from: now)
            let url = root.appendingPathComponent(String(format: "sessions/%d/%02d/%02d", directory.year!, directory.month!, directory.day!))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let file = url.appendingPathComponent(name)
            try data.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
            return file
        }

        func append(_ data: Data, to url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        }

        func overwrite(_ data: Data, at url: URL, atomically: Bool = false) throws {
            try data.write(to: url, options: atomically ? [.atomic] : [])
            now = now.addingTimeInterval(1)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        }
    }
}
