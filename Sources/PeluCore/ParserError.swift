import Foundation

public enum ParserError: Error, Equatable, Sendable {
    case unreadableJSON
    case unsupportedPayload
}
