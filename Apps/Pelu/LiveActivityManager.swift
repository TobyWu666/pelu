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
        if let existing = Activity<PeluActivityAttributes>.activities.first(where: {
            $0.activityState == .active || $0.activityState == .stale
        }) {
            Task { await existing.update(content) }
        } else {
            start(with: state)
        }
    }

    func end() {
        for activity in Activity<PeluActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
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
