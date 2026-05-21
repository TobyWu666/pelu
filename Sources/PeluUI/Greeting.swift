import Foundation

/// Greeting picker: combines time-of-day with the user's current 5-hour
/// usage level, then picks one of several variants. The selection is
/// deterministic for a given (day, hour, level) triple — stable while the
/// user looks at the dashboard, but rotates over time so the same line
/// doesn't appear two days in a row at the same hour.
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
            case ..<30:   return .low
            case 30..<70: return .medium
            default:      return .high
            }
        }

        fileprivate var seed: Int {
            switch self {
            case .low: return 0
            case .medium: return 1
            case .high: return 2
            }
        }
    }

    public static func text(
        for date: Date = Date(),
        usedPercent: Double?,
        calendar: Calendar = .current
    ) -> String {
        let hour = calendar.component(.hour, from: date)
        // `.dayOfYear` is iOS 18+; ordinality(of:in:) gives the same number on iOS 17.
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let time = TimeOfDay.from(hour: hour)
        let level = Level.from(usedPercent: usedPercent)
        // Composite seed: stable within a (day, hour, level), varies across them.
        let seed = (dayOfYear &* 73) &+ (hour &* 7) &+ level.seed
        return text(time: time, level: level, seed: seed)
    }

    public static func text(time: TimeOfDay, level: Level, seed: Int = 0) -> String {
        let pool = options(for: time, level: level)
        if pool.isEmpty { return "" }
        let index = abs(seed) % pool.count
        return pool[index]
    }

    // Every (time, level) gets at least 4 variants. Tone is observational,
    // light, occasionally winking — no "Good morning, esteemed user" energy.
    private static func options(for time: TimeOfDay, level: Level) -> [String] {
        switch (time, level) {

        // ── 凌晨 00:00–05:59 ─────────────────────────────────────
        case (.dawn, .low):
            return [
                "夜深了，額度還沒被你動過幾下",
                "深夜開機，今天還是一張白紙",
                "醒著也別太勉強，先放鬆",
                "這時間打開 Pelu，挺浪漫的",
            ]
        case (.dawn, .medium):
            return [
                "凌晨還在敲鍵盤，配杯水吧",
                "深夜的思緒總是特別順",
                "現在這節奏不錯，但別忘了天會亮",
                "Claude 陪你熬夜中",
            ]
        case (.dawn, .high):
            return [
                "深夜爆肝中，注意身體",
                "明天起床會後悔，但今晚火力很猛",
                "凌晨還在硬幹，這把不會白費",
                "額度跟肝指數一起在跳",
            ]

        // ── 早 06:00–10:59 ────────────────────────────────────────
        case (.morning, .low):
            return [
                "新的一天，新的額度",
                "早晨好，咖啡跟 Claude 都備好了",
                "早，今天還沒開始消耗",
                "晨間的程式碼最清醒",
            ]
        case (.morning, .medium):
            return [
                "早安，已經動起來了",
                "今天起步不錯",
                "早晨節奏很穩",
                "看來你今天醒得不錯",
            ]
        case (.morning, .high):
            return [
                "一早就火力全開",
                "還沒到中午就燒這麼多",
                "早晨型選手不解釋",
                "今天起跑就拚很大",
            ]

        // ── 中 11:00–13:59 ────────────────────────────────────────
        case (.noon, .low):
            return [
                "中午好，今天還沒怎麼用",
                "午餐時間，腦袋休息一下",
                "中午了，先吃飯吧",
                "輕鬆的中午",
            ]
        case (.noon, .medium):
            return [
                "進度穩定，繼續推進",
                "中午狀態剛剛好",
                "保持節奏中",
                "今天表現很均衡",
            ]
        case (.noon, .high):
            return [
                "中午就快用完？這節奏猛",
                "上午就拚這樣，下午保重",
                "今天衝得很快，記得吃飯",
                "Claude 都快跟不上你了",
            ]

        // ── 下午 14:00–17:59 ──────────────────────────────────────
        case (.afternoon, .low):
            return [
                "下午輕鬆模式",
                "今天的下午挺 relax",
                "下午好，慢慢來",
                "省下來的額度可以留給晚上",
            ]
        case (.afternoon, .medium):
            return [
                "下午持續輸出中",
                "進度推進中",
                "下午的節奏對了",
                "穩穩地推進",
            ]
        case (.afternoon, .high):
            return [
                "下午表現亮眼",
                "今天下午很拚",
                "額度燒得有道理吧",
                "看樣子今天有大事要做",
            ]

        // ── 晚 18:00–23:59 ────────────────────────────────────────
        case (.evening, .low):
            return [
                "晚上好，今天輕鬆過了",
                "額度沒怎麼動，可以早睡",
                "晚上好，這天還算平靜",
                "標準下班型的一天",
            ]
        case (.evening, .medium):
            return [
                "晚上好，今天有把工作推進",
                "今天節奏正常",
                "穩穩地過完這天",
                "晚上好，今天表現中等",
            ]
        case (.evening, .high):
            return [
                "今天真的很拚，該休息了吧",
                "今天的額度很有故事",
                "辛苦了，今天燒得很值得",
                "看完數字，去喝杯什麼吧",
            ]
        }
    }
}
