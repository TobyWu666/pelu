import Foundation

public enum UpdatedAtFormatter {
    /// Compact "last updated" timestamp shown on dashboards / widgets.
    /// Includes month/day so it's obvious when data is stale across days.
    /// zh-TW example: "5/19 21:30".
    public static func string(from date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale.current

        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "M/d HH:mm"
        }
        return formatter.string(from: date)
    }

    /// Relative "X 分鐘前" / "剛剛" style. Used by the dashboard header when
    /// we want to emphasize *how stale* the data is (e.g. disconnect state).
    public static func relativeString(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "剛剛" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分鐘前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小時前" }
        let days = hours / 24
        return "\(days) 天前"
    }
}
