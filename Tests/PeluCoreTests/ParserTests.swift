import Foundation
import Testing
@testable import PeluCore

@Test func claudeCodeParserReadsRealSchema() throws {
    // Mirrors the actual ~/.claude/usag-status.json written by Claude Code 2.x
    let payload = """
    {
      "context_window": {
        "used_percentage": 4,
        "remaining_percentage": 96
      },
      "rate_limits": {
        "five_hour": {
          "used_percentage": 2,
          "resets_at": 1779117000
        },
        "seven_day": {
          "used_percentage": 21,
          "resets_at": 1779469200
        }
      },
      "cost": {
        "total_cost_usd": 0.228967
      }
    }
    """.data(using: .utf8)!

    // Pass a generatedAt before the reset_at timestamps so the parser
    // doesn't apply its "reset-already-elapsed → 0" rule (which would
    // otherwise trigger because these test dates are now in the past).
    let metric = try ClaudeCodeParser().parse(
        data: payload,
        generatedAt: Date(timeIntervalSince1970: 1700000000)
    )

    #expect(metric.provider == .claudeCode)
    #expect(metric.usedPercent == 2)
    #expect(metric.weeklyPercent == 21)
    #expect(metric.contextWindowPercent == 4)
    #expect(metric.resetDate == Date(timeIntervalSince1970: 1779117000))
    #expect(metric.status == .normal)
    #expect(metric.costTodayUSD != nil)
}

@Test func claudeCodeParserZeroesUsedPercentAfterFiveHourReset() throws {
    let payload = """
    {
      "rate_limits": {
        "five_hour": {
          "used_percentage": 85,
          "resets_at": 1779117000
        },
        "seven_day": {
          "used_percentage": 40,
          "resets_at": 9999999999
        }
      }
    }
    """.data(using: .utf8)!

    // generatedAt is *after* the 5h reset but *before* the weekly reset.
    let metric = try ClaudeCodeParser().parse(
        data: payload,
        generatedAt: Date(timeIntervalSince1970: 1779117000 + 60)
    )

    #expect(metric.usedPercent == 0)        // 5h window is past its reset
    #expect(metric.weeklyPercent == 40)     // weekly window still active
}

@Test func claudeCodeParserReportsHookTimeForStaleFile() throws {
    // Written two days ago by the hook; no terminal session has run since.
    let payload = """
    {
      "rate_limits": {
        "five_hour": { "used_percentage": 5, "resets_at": 1791281400 },
        "seven_day": { "used_percentage": 7, "resets_at": 1791565200 }
      },
      "_received_at_ts": 1791279254.88
    }
    """.data(using: .utf8)!

    let now = Date(timeIntervalSince1970: 1791449763)
    let metric = try ClaudeCodeParser().parse(
        data: payload,
        generatedAt: now,
        fileModifiedAt: now.addingTimeInterval(-60)
    )

    #expect(metric.usedPercent == 0)
    #expect(metric.weeklyPercent == 7)
    #expect(metric.measuredAt == Date(timeIntervalSince1970: 1791279254.88))
}

@Test func claudeCodeParserFallsBackToLooseSchema() throws {
    let payload = """
    {
      "usage": {
        "used_percent": "37%",
        "cost_today_usd": "4.28",
        "reset_at": "2026-05-18T22:00:00Z"
      }
    }
    """.data(using: .utf8)!

    // generatedAt before the loose-schema reset_at so we get the raw value.
    let metric = try ClaudeCodeParser().parse(
        data: payload,
        generatedAt: Date(timeIntervalSince1970: 1700000000)
    )

    #expect(metric.provider == .claudeCode)
    #expect(metric.usedPercent == 37)
    #expect(metric.costTodayUSD == Decimal(string: "4.28"))
    #expect(metric.status == .normal)
    #expect(metric.resetDate != nil)
}

