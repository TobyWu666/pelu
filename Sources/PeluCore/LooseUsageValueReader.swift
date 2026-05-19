import Foundation

enum LooseUsageValueReader {
    static func firstDouble(in value: Any, matching keys: Set<String>) -> Double? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if keys.contains(normalized(key)), let number = double(from: child) {
                    return number
                }
            }

            for child in dictionary.values {
                if let number = firstDouble(in: child, matching: keys) {
                    return number
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let number = firstDouble(in: child, matching: keys) {
                    return number
                }
            }
        }

        return nil
    }

    static func firstDate(in value: Any, matching keys: Set<String>) -> Date? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if keys.contains(normalized(key)), let date = date(from: child) {
                    return date
                }
            }

            for child in dictionary.values {
                if let date = firstDate(in: child, matching: keys) {
                    return date
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let date = firstDate(in: child, matching: keys) {
                    return date
                }
            }
        }

        return nil
    }

    static func firstDecimal(in value: Any, matching keys: Set<String>) -> Decimal? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if keys.contains(normalized(key)), let decimal = decimal(from: child) {
                    return decimal
                }
            }

            for child in dictionary.values {
                if let decimal = firstDecimal(in: child, matching: keys) {
                    return decimal
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let decimal = firstDecimal(in: child, matching: keys) {
                    return decimal
                }
            }
        }

        return nil
    }

    static func decimal(from value: Double?) -> Decimal? {
        guard let value else { return nil }
        return Decimal(string: String(value))
    }

    private static func normalized(_ key: String) -> String {
        key.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func double(from value: Any) -> Double? {
        if let double = value as? Double {
            return double
        }

        if let int = value as? Int {
            return Double(int)
        }

        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")
                .replacingOccurrences(of: "$", with: "")
            return Double(trimmed)
        }

        return nil
    }

    private static func decimal(from value: Any) -> Decimal? {
        if let decimal = value as? Decimal {
            return decimal
        }

        if let int = value as? Int {
            return Decimal(int)
        }

        if let double = value as? Double {
            return Decimal(string: String(double))
        }

        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "$", with: "")
            return Decimal(string: trimmed)
        }

        return nil
    }

    private static func date(from value: Any) -> Date? {
        if let date = value as? Date {
            return date
        }

        if let timeInterval = double(from: value), timeInterval > 1_000_000_000 {
            return Date(timeIntervalSince1970: timeInterval)
        }

        guard let string = value as? String else {
            return nil
        }

        if let date = ISO8601DateFormatter().date(from: string) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                return date
            }
        }

        return nil
    }
}
