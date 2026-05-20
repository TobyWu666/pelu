import Foundation
import Testing
@testable import PeluUI

@Test func timeOfDayBoundaries() {
    #expect(Greeting.TimeOfDay.from(hour: 0)  == .dawn)
    #expect(Greeting.TimeOfDay.from(hour: 5)  == .dawn)
    #expect(Greeting.TimeOfDay.from(hour: 6)  == .morning)
    #expect(Greeting.TimeOfDay.from(hour: 10) == .morning)
    #expect(Greeting.TimeOfDay.from(hour: 11) == .noon)
    #expect(Greeting.TimeOfDay.from(hour: 13) == .noon)
    #expect(Greeting.TimeOfDay.from(hour: 14) == .afternoon)
    #expect(Greeting.TimeOfDay.from(hour: 17) == .afternoon)
    #expect(Greeting.TimeOfDay.from(hour: 18) == .evening)
    #expect(Greeting.TimeOfDay.from(hour: 23) == .evening)
}

@Test func usageLevelBuckets() {
    #expect(Greeting.Level.from(usedPercent: nil)   == .low)
    #expect(Greeting.Level.from(usedPercent: 0)     == .low)
    #expect(Greeting.Level.from(usedPercent: 29.9)  == .low)
    #expect(Greeting.Level.from(usedPercent: 30)    == .medium)
    #expect(Greeting.Level.from(usedPercent: 69.9)  == .medium)
    #expect(Greeting.Level.from(usedPercent: 70)    == .high)
    #expect(Greeting.Level.from(usedPercent: 100)   == .high)
}

@Test func greetingMatrixHasAllFifteenSlots() {
    let times: [Greeting.TimeOfDay] = [.dawn, .morning, .noon, .afternoon, .evening]
    let levels: [Greeting.Level] = [.low, .medium, .high]
    for time in times {
        for level in levels {
            let text = Greeting.text(time: time, level: level)
            #expect(!text.isEmpty)
        }
    }
}
