import Foundation
import Testing
@testable import PeluCore

@Test func resetTimeFormatterShowsAlreadyResetWhenIntervalNonPositive() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    // Exact same instant — already reset.
    #expect(ResetTimeFormatter.string(from: now, now: now) == "已重置")
    // In the past — still already reset, not negative.
    let past = now.addingTimeInterval(-3600)
    #expect(ResetTimeFormatter.string(from: past, now: now) == "已重置")
}

@Test func resetTimeFormatterFormatsDaysHoursMinutes() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    // 45 minutes
    #expect(ResetTimeFormatter.string(from: now.addingTimeInterval(45 * 60), now: now) == "重置於 45m")
    // 1h 45m
    let oneHourFortyFive = now.addingTimeInterval(60 * 60 + 45 * 60)
    #expect(ResetTimeFormatter.string(from: oneHourFortyFive, now: now) == "重置於 1h45m")
    // 2 days 12 hours — spans day boundary
    let twoDaysTwelve = now.addingTimeInterval(2 * 86400 + 12 * 3600)
    #expect(ResetTimeFormatter.string(from: twoDaysTwelve, now: now) == "重置於 2d12h")
}

@Test func resetTimeFormatterRoundsSubMinuteUpToOneMinute() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    // 30 seconds away — display floor would be 0m which is misleading; expect "1m".
    let thirtySeconds = now.addingTimeInterval(30)
    #expect(ResetTimeFormatter.string(from: thirtySeconds, now: now) == "重置於 1m")
}
