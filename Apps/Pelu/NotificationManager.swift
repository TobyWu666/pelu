import Foundation
import PeluCore
import UIKit
import UserNotifications
import WidgetKit

/// Local UNNotification authorization manager. CloudKit handles push delivery
/// (silent pushes wake the app via subscription); this class only manages whether
/// we're allowed to *show* local user-facing notifications for low-quota / reset
/// events detected on-device.
@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let lowQuotaKey = "pelu.notify.lowQuota"
    private let resetKey = "pelu.notify.reset"

    var lowQuotaEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: lowQuotaKey) }
        set { UserDefaults.standard.set(newValue, forKey: lowQuotaKey) }
    }

    var resetEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: resetKey) }
        set { UserDefaults.standard.set(newValue, forKey: resetKey) }
    }

    private init() {}

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorizationStatus = settings.authorizationStatus
            return true
        case .denied:
            authorizationStatus = .denied
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                let updated = await center.notificationSettings()
                authorizationStatus = updated.authorizationStatus
                return granted
            } catch {
                authorizationStatus = .denied
                return false
            }
        @unknown default:
            return false
        }
    }
}

/// Single entry point for refreshing the iOS UI surfaces (dashboard, widget,
/// Live Activity) from CloudKit. Used by manual refresh, the 5-min timer, and
/// the silent push handler.
@MainActor
enum UsageSurfaceUpdater {
    enum UpdaterError: Error {
        case accountUnavailable(CloudKitAccountChecker.Result)
    }

    private static let syncer = CloudKitSyncer(
        bundleVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    )

    static func fetchFromCloud(updateLiveActivity: Bool) async throws -> AggregateSnapshot {
        // Don't even try to fetch if iCloud isn't available — the caller can
        // surface a meaningful error to the onboarding / dashboard UI.
        let accountStatus = await CloudKitAccountChecker().status()
        guard accountStatus == .available else {
            throw UpdaterError.accountUnavailable(accountStatus)
        }

        // Snapshot the previous aggregate *before* overwriting it, so we can
        // diff and fire local notifications for low-quota / reset crossings.
        let previousAggregate = try? AppGroupStore()?.loadLatestAggregate()
        let aggregate = try await syncer.fetchAllMacs()

        try? AppGroupStore()?.save(aggregate)
        try? UsageHistoryStore()?.record(aggregate)
        WidgetCenter.shared.reloadAllTimelines()

        if updateLiveActivity, let primary = aggregate.primary {
            LiveActivityManager.shared.update(with: primary.snapshot)
        }

        // Fire local notifications if any 5-hour usage% crosses the low-quota
        // threshold or resets. Per-Mac × per-provider; honors the toggles.
        if let previous = previousAggregate {
            await LocalUsageNotifier.notifyTransitions(from: previous, to: aggregate)
        }

        return aggregate
    }
}

/// Detects 5h-window threshold crossings between two `AggregateSnapshot`s
/// and posts `UNNotificationRequest`s when the user has opted in.
@MainActor
enum LocalUsageNotifier {
    private static let lowQuotaThreshold: Double = 90
    // "Reset" heuristic: usage drops sharply from >50% to <20% — the rate
    // limit window must have rolled over.
    private static let resetHighThreshold: Double = 50
    private static let resetLowThreshold: Double = 20

    static func notifyTransitions(
        from previous: AggregateSnapshot,
        to current: AggregateSnapshot
    ) async {
        let manager = NotificationManager.shared
        let center = UNUserNotificationCenter.current()
        // Skip the system check entirely if both toggles are off.
        guard manager.lowQuotaEnabled || manager.resetEnabled else { return }

        // Cross-reference Macs by macId so a missing-then-present Mac doesn't
        // generate a spurious "crossed" event.
        let prevByMac = Dictionary(uniqueKeysWithValues: previous.macs.map { ($0.macId, $0) })
        for mac in current.macs {
            guard let prevMac = prevByMac[mac.macId] else { continue }
            let prevMetrics = Dictionary(uniqueKeysWithValues: prevMac.snapshot.metrics.map { ($0.provider, $0) })
            for metric in mac.snapshot.metrics {
                guard let prev = prevMetrics[metric.provider] else { continue }
                guard let prevUsed = prev.usedPercent, let curUsed = metric.usedPercent else { continue }

                if manager.lowQuotaEnabled,
                   prevUsed <= lowQuotaThreshold, curUsed > lowQuotaThreshold {
                    await schedule(
                        center: center,
                        title: "額度即將用完",
                        body: "\(mac.label) · \(metric.provider.displayName) 5 小時剩餘額度低於 10%。",
                        identifier: "lowquota-\(mac.macId)-\(metric.provider.rawValue)"
                    )
                }

                if manager.resetEnabled,
                   prevUsed > resetHighThreshold, curUsed < resetLowThreshold {
                    await schedule(
                        center: center,
                        title: "額度已重置",
                        body: "\(mac.label) · \(metric.provider.displayName) 用量已重置，可以繼續用了。",
                        identifier: "reset-\(mac.macId)-\(metric.provider.rawValue)"
                    )
                }
            }
        }
    }

    private static func schedule(
        center: UNUserNotificationCenter,
        title: String,
        body: String,
        identifier: String
    ) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            // Fire immediately — there's no `nil` trigger but a 1-sec interval
            // is functionally identical for the user.
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try? await center.add(request)
    }
}
