import Foundation

/// Retains at most one pending refresh. Requests during work produce one
/// followup, and continuous activity cannot create an unbounded queue.
public final class CoalescingRefreshScheduler: @unchecked Sendable {
    private let queue: DispatchQueue
    private let minimumInterval: TimeInterval
    private let lock = NSLock()
    // All mutable state is protected by `lock`; work runs outside the lock.
    private var pending: (@Sendable () -> Void)?
    private var isScheduled = false
    private var nextAllowedStart = DispatchTime.now()

    public init(queue: DispatchQueue, minimumInterval: TimeInterval = 1) {
        self.queue = queue
        self.minimumInterval = max(0, minimumInterval)
    }

    public func request(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        pending = work
        if isScheduled {
            lock.unlock()
            return
        }
        isScheduled = true
        let deadline = nextAllowedStart
        lock.unlock()
        schedule(at: deadline)
    }

    private func schedule(at deadline: DispatchTime) {
        queue.asyncAfter(deadline: deadline) { [weak self] in self?.runPending() }
    }

    private func runPending() {
        lock.lock()
        let work = pending
        pending = nil
        nextAllowedStart = .now() + minimumInterval
        lock.unlock()
        if let work { autoreleasepool(invoking: work) }
        lock.lock()
        let needsFollowup = pending != nil
        isScheduled = needsFollowup
        let deadline = nextAllowedStart
        lock.unlock()
        if needsFollowup { schedule(at: deadline) }
    }
}
