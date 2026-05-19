import PeluCore
import SwiftUI

public extension UsageStatus {
    var tintColor: Color {
        switch self {
        case .normal:
            PeluTheme.teal
        case .caution:
            PeluTheme.amber
        case .warning:
            PeluTheme.coral
        case .offline, .unknown:
            PeluTheme.slate500
        }
    }

    var label: String {
        switch self {
        case .normal:
            "正常"
        case .caution:
            "注意"
        case .warning:
            "接近上限"
        case .offline:
            "離線"
        case .unknown:
            "未知"
        }
    }
}
