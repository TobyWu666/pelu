import Foundation

/// Raw token counts extracted from Codex JSONL `token_count` events
/// (`info.total_token_usage`). Codex RPC doesn't expose these — only the
/// JSONL path does — so the field is populated by PeluMac's
/// `CodexJSONLReader` regardless of which source produced the percentages.
///
/// `inputTokens` includes `cachedInputTokens` (subset); `outputTokens`
/// already covers `reasoning_output_tokens` (verified: input + output ==
/// total in observed payloads).
public struct CodexTokenUsage: Codable, Equatable, Hashable, Sendable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int

    public init(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) {
        let normalizedInput = max(0, inputTokens)
        // cached is a subset of input by definition — clamp so a malformed
        // event (cached > input) can't make the estimator charge for
        // tokens that don't exist.
        self.inputTokens = normalizedInput
        self.cachedInputTokens = min(max(0, cachedInputTokens), normalizedInput)
        self.outputTokens = max(0, outputTokens)
    }

    public static let zero = CodexTokenUsage(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0
    )

    public var isEmpty: Bool {
        inputTokens == 0 && outputTokens == 0
    }

    public func adding(_ other: CodexTokenUsage) -> CodexTokenUsage {
        CodexTokenUsage(
            inputTokens: inputTokens + other.inputTokens,
            cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
            outputTokens: outputTokens + other.outputTokens
        )
    }
}

/// USD-per-million-token rates for OpenAI's Codex coding agent. Defaults
/// reflect `gpt-5-codex` published pricing as of 2026-05.
///
/// JSONL `token_count` events don't include the model identifier — Codex
/// can route between `gpt-5-codex` and `gpt-5-mini-codex` based on task
/// difficulty — so the numbers we surface are always an estimate. UI
/// must label them as such ("≈" prefix + footer note).
public enum CodexPricing {
    public static let inputUSDPerMillion: Decimal = Decimal(string: "1.25")!
    public static let cachedInputUSDPerMillion: Decimal = Decimal(string: "0.125")!
    public static let outputUSDPerMillion: Decimal = Decimal(string: "10.00")!

    /// USD cost for the given token counts. Uses cached-input discount on
    /// the cached portion only; non-cached portion = inputTokens - cached.
    public static func estimateUSD(for usage: CodexTokenUsage) -> Decimal {
        let nonCached = max(usage.inputTokens - usage.cachedInputTokens, 0)
        let nonCachedCost = Decimal(nonCached) * inputUSDPerMillion
        let cachedCost = Decimal(usage.cachedInputTokens) * cachedInputUSDPerMillion
        let outputCost = Decimal(usage.outputTokens) * outputUSDPerMillion
        return (nonCachedCost + cachedCost + outputCost) / 1_000_000
    }
}
