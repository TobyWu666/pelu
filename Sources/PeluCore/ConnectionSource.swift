import Foundation

public enum ConnectionSource: String, Codable, Sendable, CaseIterable {
    case local
    case cloud
    case cache
    case demo

    public var displayName: String {
        switch self {
        case .local:
            "Mac 本地連線"
        case .cloud:
            "雲端同步"
        case .cache:
            "快取資料"
        case .demo:
            "Demo 資料"
        }
    }
}
