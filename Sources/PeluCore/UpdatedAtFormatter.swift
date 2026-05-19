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
}
