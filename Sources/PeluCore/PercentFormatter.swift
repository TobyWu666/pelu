import Foundation

public enum PercentFormatter {
    public static func string(from percent: Double?) -> String {
        guard let percent else { return "--%" }
        return "\(Int(percent.rounded()))%"
    }

    public static func progress(from percent: Double?) -> Double {
        guard let percent else { return 0 }
        return min(max(percent / 100, 0), 1)
    }
}
