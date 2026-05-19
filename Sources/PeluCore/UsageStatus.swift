import Foundation

public enum UsageStatus: String, Codable, Sendable, CaseIterable {
    case normal
    case caution
    case warning
    case offline
    case unknown

    public static func from(percent: Double?) -> UsageStatus {
        guard let percent else { return .unknown }

        return switch percent {
        case ..<70:
            .normal
        case 70..<85:
            .caution
        default:
            .warning
        }
    }
}
