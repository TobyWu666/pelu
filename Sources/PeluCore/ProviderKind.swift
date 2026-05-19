import Foundation

public enum ProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case claudeCode = "claude_code"
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode:
            "Claude Code"
        case .codex:
            "Codex"
        }
    }

    public var assetName: String {
        switch self {
        case .claudeCode:
            "ClaudeIcon"
        case .codex:
            "CodexIcon"
        }
    }
}
