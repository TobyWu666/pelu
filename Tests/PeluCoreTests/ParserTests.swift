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

    let metric = try ClaudeCodeParser().parse(data: payload)

    #expect(metric.provider == .claudeCode)
    #expect(metric.usedPercent == 2)
    #expect(metric.weeklyPercent == 21)
    #expect(metric.contextWindowPercent == 4)
    #expect(metric.resetDate == Date(timeIntervalSince1970: 1779117000))
    #expect(metric.status == .normal)
    #expect(metric.costTodayUSD != nil)
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

    let metric = try ClaudeCodeParser().parse(data: payload)

    #expect(metric.provider == .claudeCode)
    #expect(metric.usedPercent == 37)
    #expect(metric.costTodayUSD == Decimal(string: "4.28"))
    #expect(metric.status == .normal)
    #expect(metric.resetDate != nil)
}

