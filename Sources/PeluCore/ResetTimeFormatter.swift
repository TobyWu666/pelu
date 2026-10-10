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

    /// Spelled-out time left, e.g. "2 小時 19 分", "3 天 23 小時", "45 分鐘".
    /// Nil once the date has passed.
    public static func remaining(until date: Date, now: Date = Date()) -> String? {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return nil }

        let total = Int(interval)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60

        if days > 0 {
            return hours > 0 ? "\(days) 天 \(hours) 小時" : "\(days) 天"
        } else if hours > 0 {
            return minutes > 0 ? "\(hours) 小時 \(minutes) 分" : "\(hours) 小時"
        } else {
            return "\(max(minutes, 1)) 分鐘"
        }
    }
}
