import SwiftUI

public enum PeluTheme {
    public static let teal = Color(red: 18 / 255, green: 184 / 255, blue: 166 / 255)
    public static let tealBright = Color(red: 46 / 255, green: 211 / 255, blue: 193 / 255)
    public static let sky = Color(red: 90 / 255, green: 169 / 255, blue: 255 / 255)
    public static let lime = Color(red: 164 / 255, green: 214 / 255, blue: 94 / 255)
    public static let amber = Color(red: 245 / 255, green: 165 / 255, blue: 36 / 255)
    public static let coral = Color(red: 255 / 255, green: 107 / 255, blue: 95 / 255)

    public static let ink = Color(red: 23 / 255, green: 32 / 255, blue: 38 / 255)
    public static let slate700 = Color(red: 61 / 255, green: 74 / 255, blue: 82 / 255)
    public static let slate500 = Color(red: 113 / 255, green: 128 / 255, blue: 138 / 255)
    public static let slate200 = Color(red: 221 / 255, green: 229 / 255, blue: 232 / 255)
    public static let slate050 = Color(red: 248 / 255, green: 250 / 255, blue: 251 / 255)

    public static let night = Color(red: 13 / 255, green: 18 / 255, blue: 22 / 255)
    public static let nightSurface = Color(red: 21 / 255, green: 28 / 255, blue: 33 / 255)
    public static let nightBorder = Color(red: 37 / 255, green: 48 / 255, blue: 57 / 255)

    public static func brandTeal(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? tealBright : teal
    }

    public static func background(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? night : slate050
    }

    public static func surface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? nightSurface : .white
    }

    public static func border(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? nightBorder : slate200
    }

    public static func primaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 244 / 255, green: 247 / 255, blue: 248 / 255)
            : ink
    }

    public static func secondaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 199 / 255, green: 210 / 255, blue: 216 / 255)
            : slate700
    }

    public static func tertiaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 169 / 255, green: 181 / 255, blue: 188 / 255)
            : slate500
    }
}
