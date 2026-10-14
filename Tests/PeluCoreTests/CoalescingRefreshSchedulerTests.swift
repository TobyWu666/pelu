import Foundation
import XCTest
@testable import PeluCore

final class CoalescingRefreshSchedulerTests: XCTestCase {
    func testBurstKeepsOnlyLatestPendingWorkAndReleasesOldCaptures() {
        let queue = DispatchQueue(label: "pelu-test-burst")
        queue.suspend()
        let scheduler = CoalescingRefreshScheduler(queue: queue, minimumInterval: 0)
        let state = State()
        var capture: Capture? = Capture()
        let releasedCapture = WeakCapture(capture)
        scheduler.request { [captured = capture!] in _ = captured }
        capture = nil
        let done = expectation(description: "Latest request ran")
        for index in 0..<1000 {
            scheduler.request {
                state.record(index)
                done.fulfill()
            }
        }
        XCTAssertNil(releasedCapture.value)
        queue.resume()
        wait(for: [done], timeout: 2)
        queue.sync {}
        XCTAssertEqual(state.values, [999])
    }

    func testRequestsDuringWorkProduceExactlyOneFollowup() {
        let queue = DispatchQueue(label: "pelu-test-followup")
        let scheduler = CoalescingRefreshScheduler(queue: queue, minimumInterval: 0)
        let state = State()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = expectation(description: "One followup ran")
        scheduler.request {
            state.record(-1)
            started.signal()
            _ = release.wait(timeout: .now() + 2)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        for index in 0..<1000 {
            scheduler.request {
                state.record(index)
                done.fulfill()
            }
        }
        release.signal()
        wait(for: [done], timeout: 2)
        queue.sync {}
        XCTAssertEqual(state.values, [-1, 999])
    }

    func testConcurrentCallersStillQueueOnlyOneRefresh() {
        let queue = DispatchQueue(label: "pelu-test-concurrent")
        queue.suspend()
        let scheduler = CoalescingRefreshScheduler(queue: queue, minimumInterval: 0)
        let state = State()
        let done = expectation(description: "Burst ran once")
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            scheduler.request {
                state.record(index)
                done.fulfill()
            }
        }
        queue.resume()
        wait(for: [done], timeout: 2)
        queue.sync {}
        XCTAssertEqual(state.values.count, 1)
    }

    func testContinuousActivityHonorsMinimumInterval() {
        let queue = DispatchQueue(label: "pelu-test-cadence")
        let scheduler = CoalescingRefreshScheduler(queue: queue, minimumInterval: 0.05)
        let state = State()
        let done = expectation(description: "Two refreshes completed")
        done.expectedFulfillmentCount = 2
        scheduler.request {
            state.record(Int(DispatchTime.now().uptimeNanoseconds))
            done.fulfill()
            scheduler.request {
                state.record(Int(DispatchTime.now().uptimeNanoseconds))
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 2)
        let starts = state.values
        XCTAssertEqual(starts.count, 2)
        if starts.count == 2 { XCTAssertGreaterThanOrEqual(starts[1] - starts[0], 45_000_000) }
    }

    private final class Capture: @unchecked Sendable {}
    private final class WeakCapture {
        weak var value: Capture?
        init(_ value: Capture?) { self.value = value }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Int] = []
        var values: [Int] { lock.withLock { stored } }
        func record(_ value: Int) { lock.withLock { stored.append(value) } }
    }
}
