import Foundation

/// Pure-function greeting picker. Combines time-of-day with the user's current
/// 5-hour usage level to produce a single 繁中 greeting line for the dashboard.
public enum Greeting {
    public enum TimeOfDay: Sendable {
        case dawn       // 00:00–05:59
        case morning    // 06:00–10:59
        case noon       // 11:00–13:59
        case afternoon  // 14:00–17:59
        case evening    // 18:00–23:59

        public static func from(hour: Int) -> TimeOfDay {
            switch hour {
            case 0..<6:   return .dawn
            case 6..<11:  return .morning
            case 11..<14: return .noon
            case 14..<18: return .afternoon
            default:      return .evening
            }
        }
    }

    public enum Level: Sendable {
        case low      // 0% – 30%
        case medium   // 30% – 70%
        case high     // 70% +

        public static func from(usedPercent: Double?) -> Level {
            guard let percent = usedPercent else { return .low }
            switch percent {
            case ..<30:  return .low
            case 30..<70: return .medium
            default:     return .high
            }
        }
    }

    /// Greeting given the date and current "busiest" usage percent across the
    /// user's Macs. Pass nil if no usage data is available — we treat that as low.
    public static func text(
        for date: Date = Date(),
        usedPercent: Double?,
        calendar: Calendar = .current
    ) -> String {
        let hour = calendar.component(.hour, from: date)
        return text(
            time: TimeOfDay.from(hour: hour),
            level: Level.from(usedPercent: usedPercent)
        )
    }

    public static func text(time: TimeOfDay, level: Level) -> String {
        switch (time, level) {
        case (.dawn, .low):       return "夜深了，還有餘裕"
        case (.dawn, .medium):    return "凌晨還在開機，記得休息"
        case (.dawn, .high):      return "深夜爆肝中，加油但別熬太晚"

        case (.morning, .low):    return "早安，新的一天剛開始"
        case (.morning, .medium): return "早安，已經動起來了"
        case (.morning, .high):   return "早安，今天火力全開"

        case (.noon, .low):       return "中午好，下午還有的拼"
        case (.noon, .medium):    return "中午好，進度穩定"
        case (.noon, .high):      return "中午好，今天衝很大"

        case (.afternoon, .low):  return "下午好，輕鬆模式"
        case (.afternoon, .medium): return "下午好，持續輸出中"
        case (.afternoon, .high): return "下午好，今天表現亮眼"

        case (.evening, .low):    return "晚安，今天輕鬆過"
        case (.evening, .medium): return "晚安，今天有好好工作"
        case (.evening, .high):   return "晚安，今天真的拼"
        }
    }
}
