import Foundation

public enum ResetTimeFormatter {
    /// Returns a string like "重置於 2d12h" or "重置於 1h45m" or "重置於 45m".
    public static func string(from date: Date, now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "已重置" }

        let total = Int(interval)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60

        if days > 0 {
            return "重置於 \(days)d\(hours)h"
        } else if hours > 0 {
            return "重置於 \(hours)h\(minutes)m"
        } else {
            return "重置於 \(max(minutes, 1))m"
        }
    }
}
