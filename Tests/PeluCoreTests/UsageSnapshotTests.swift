import Foundation
import Testing
@testable import PeluCore

@Test func usageSnapshotRoundTripsThroughAPIJSON() throws {
    let snapshot = UsageSnapshot.demo(now: Date(timeIntervalSince1970: 1_800_000_000))

    let data = try JSONEncoder.peluAPI.encode(snapshot)
    let decoded = try JSONDecoder.peluAPI.decode(UsageSnapshot.self, from: data)

    #expect(decoded == snapshot)
}

@Test func usageStatusFollowsThresholds() {
    #expect(UsageStatus.from(percent: nil) == .unknown)
    #expect(UsageStatus.from(percent: 12) == .normal)
    #expect(UsageStatus.from(percent: 72) == .caution)
    #expect(UsageStatus.from(percent: 91) == .warning)
}
