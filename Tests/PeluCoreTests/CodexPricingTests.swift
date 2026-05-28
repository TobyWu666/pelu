import XCTest
@testable import PeluCore

final class CodexPricingTests: XCTestCase {
    func test_estimateUSD_matchesObservedTokenCountEvent() {
        // From a real Codex JSONL token_count payload (rollout 2026-05-25):
        // input=88011 cached=77056 output=1019. Hand-computed expected:
        //   nonCached input  = 88011 - 77056 = 10955  → 10955 * 1.25/1M  = 0.01369375
        //   cached input     = 77056           → 77056 * 0.125/1M = 0.009632
        //   output (w/reason)= 1019            → 1019 * 10/1M     = 0.01019
        // total                                             ≈ 0.03351575
        let usage = CodexTokenUsage(inputTokens: 88011, cachedInputTokens: 77056, outputTokens: 1019)
        let cost = CodexPricing.estimateUSD(for: usage)
        let expected = Decimal(string: "0.03351575")!
        XCTAssertEqual(cost, expected)
    }

    func test_estimateUSD_zeroUsage_isZero() {
        XCTAssertEqual(CodexPricing.estimateUSD(for: .zero), 0)
    }

    func test_estimateUSD_clampsCachedToInput() {
        // cached > input shouldn't happen in practice. The init clamps
        // cached to <= input so a malformed event can't make us charge
        // for non-existent tokens. After clamp: input=100, cached=100,
        // output=0 → 100 * 0.125/1M = 0.0000125.
        let weird = CodexTokenUsage(inputTokens: 100, cachedInputTokens: 200, outputTokens: 0)
        XCTAssertEqual(weird.cachedInputTokens, 100)
        let cost = CodexPricing.estimateUSD(for: weird)
        XCTAssertEqual(cost, Decimal(string: "0.0000125")!)
    }

    func test_tokenUsage_adding_sumsComponents() {
        let a = CodexTokenUsage(inputTokens: 10, cachedInputTokens: 5, outputTokens: 3)
        let b = CodexTokenUsage(inputTokens: 7, cachedInputTokens: 2, outputTokens: 11)
        let sum = a.adding(b)
        XCTAssertEqual(sum.inputTokens, 17)
        XCTAssertEqual(sum.cachedInputTokens, 7)
        XCTAssertEqual(sum.outputTokens, 14)
    }

    func test_tokenUsage_init_clampsNegatives() {
        let usage = CodexTokenUsage(inputTokens: -5, cachedInputTokens: -1, outputTokens: -3)
        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.cachedInputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 0)
        XCTAssertTrue(usage.isEmpty)
    }

    func test_tokenUsage_codableRoundtrip_preservesValues() throws {
        let usage = CodexTokenUsage(inputTokens: 88011, cachedInputTokens: 77056, outputTokens: 1019)
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(CodexTokenUsage.self, from: data)
        XCTAssertEqual(usage, decoded)
    }

    func test_usageMetric_tokenUsage_survivesEncodeDecode() throws {
        let metric = UsageMetric(
            provider: .codex,
            usedPercent: 12,
            tokenUsage: CodexTokenUsage(inputTokens: 100, cachedInputTokens: 50, outputTokens: 25)
        )
        let data = try JSONEncoder.peluAPI.encode(metric)
        let decoded = try JSONDecoder.peluAPI.decode(UsageMetric.self, from: data)
        XCTAssertEqual(decoded.tokenUsage, metric.tokenUsage)
    }

    func test_usageMetric_legacyPayload_decodesWithNilTokenUsage() throws {
        // Pre-v1.0.7 payload — no `tokenUsage` field. Should decode and
        // leave tokenUsage as nil rather than failing the whole snapshot.
        let legacy = """
        {
            "provider": "codex",
            "usedPercent": 42.0,
            "status": "normal"
        }
        """
        let data = Data(legacy.utf8)
        let metric = try JSONDecoder.peluAPI.decode(UsageMetric.self, from: data)
        XCTAssertNil(metric.tokenUsage)
        XCTAssertEqual(metric.usedPercent, 42)
    }
}
