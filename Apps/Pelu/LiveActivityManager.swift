import ActivityKit
import Foundation
import PeluCore

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private init() {}

    func update(with snapshot: UsageSnapshot) {
        let state = PeluActivityAttributes.ContentState.from(snapshot: snapshot)
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(300)
        )

        // Reuse any existing active activity to avoid stacking
        if Self.currentActivity() != nil {
            Task { await Self.updateCurrent(content) }
        } else {
            start(with: state)
        }
    }

    func end() {
        Task { await Self.endAll() }
    }

    // `Activity` isn't Sendable, so look it up inside the nonisolated async call
    // instead of capturing it on the main actor and sending it across.
    private nonisolated static func currentActivity() -> Activity<PeluActivityAttributes>? {
        Activity<PeluActivityAttributes>.activities.first {
            $0.activityState == .active || $0.activityState == .stale
        }
    }

    private nonisolated static func updateCurrent(
        _ content: ActivityContent<PeluActivityAttributes.ContentState>
    ) async {
        await currentActivity()?.update(content)
    }

    private nonisolated static func endAll() async {
        for activity in Activity<PeluActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func start(with state: PeluActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity<PeluActivityAttributes>.request(
                attributes: PeluActivityAttributes(),
                content: ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(300)
                )
            )
        } catch {
            print("Live Activity start failed: \(error)")
        }
    }
}
