import Foundation
import PeluCore
import UIKit
import UserNotifications
import WidgetKit

extension Notification.Name {
    /// Broadcast after `UsageSurfaceUpdater.fetchFromCloud` finishes writing
    /// `usage-history.json` + `latest-aggregate-snapshot.json`. Lets passive
    /// screens (歷史) reload from disk without running their own fetch.
    static let peluUsageDidUpdate = Notification.Name("PeluUsageDidUpdate")
}

/// Local UNNotification authorization manager. CloudKit handles push delivery
/// (silent pushes wake the app via subscription); this class only manages whether
/// we're allowed to *show* local user-facing notifications for low-quota / reset
/// events detected on-device.
@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let lowQuotaKey = "pelu.notify.lowQuota"
    private let resetKey = "pelu.notify.reset"             // 5 小時重置（沿用舊 key）
    private let weeklyResetKey = "pelu.notify.weeklyReset" // 每週重置（新 key）

    var lowQuotaEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: lowQuotaKey) }
        set { UserDefaults.standard.set(newValue, forKey: lowQuotaKey) }
    }

    var resetEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: resetKey) }
        set { UserDefaults.standard.set(newValue, forKey: resetKey) }
    }

    var weeklyResetEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: weeklyResetKey) }
        set { UserDefaults.standard.set(newValue, forKey: weeklyResetKey) }
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
        let now = Date()

        try? AppGroupStore()?.save(aggregate)
        _ = try? UsageHistoryStore()?.record(aggregate)
        WidgetCenter.shared.reloadAllTimelines()
        NotificationCenter.default.post(name: .peluUsageDidUpdate, object: nil)

        if updateLiveActivity {
            if let display = aggregate.displaySnapshot(at: now) {
                LiveActivityManager.shared.update(with: display)
            } else {
                LiveActivityManager.shared.end()
            }
        }

        // Low-quota: fire when 5h usage% crosses 90 (data-driven).
        // Pass an empty aggregate when there's no prior data so the notifier
        // still has a chance to alert on a first-launch already-above-90 case.
        await LocalUsageNotifier.notifyLowQuotaCrossings(
            from: previousAggregate ?? AggregateSnapshot(macs: []),
            to: aggregate
        )
        // Reset: pre-schedule a UNNotification at each future resetDate so the
        // user gets pinged at the exact moment they can resume — no dependency
        // on a fresh CloudKit fetch or CLI activity.
        await LocalUsageNotifier.scheduleResetReminders(for: aggregate)

        return aggregate
    }
}

/// Local UNNotification scheduling for low-quota crossings (data-driven) and
/// upcoming reset times (time-scheduled at exact resetDate).
@MainActor
enum LocalUsageNotifier {
    private static let lowQuotaThreshold: Double = 90

    /// Fire when 5h `usedPercent` enters the >90% zone for a given Mac × provider.
    /// Triggers on:
    ///   - first observation that's already over the threshold (no previous data)
    ///   - upward crossing from ≤90 to >90
    /// Does NOT trigger on:
    ///   - sustained values above threshold (previous was also >90 — already alerted)
    /// Per-Mac × per-provider; honors the user's `lowQuotaEnabled` toggle.
    static func notifyLowQuotaCrossings(
        from previous: AggregateSnapshot,
        to current: AggregateSnapshot
    ) async {
        guard NotificationManager.shared.lowQuotaEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let now = Date()
        let prevByMac = Dictionary(uniqueKeysWithValues: previous.macs.map { ($0.macId, $0) })
        for mac in current.macs {
            let prevMetrics: [ProviderKind: UsageMetric] = prevByMac[mac.macId].map {
                Dictionary(uniqueKeysWithValues: $0.snapshot.metrics.map {
                    ($0.provider, $0.effective(at: now))
                })
            } ?? [:]

            for storedMetric in mac.snapshot.metrics {
                let metric = storedMetric.effective(at: now)
                guard let curUsed = metric.usedPercent, curUsed > lowQuotaThreshold else { continue }

                // Skip if previous reading was already over the threshold — we've
                // either already alerted, or the user has been informed via UI.
                if let prevUsed = prevMetrics[metric.provider]?.usedPercent,
                   prevUsed > lowQuotaThreshold {
                    continue
                }

                let request = UNNotificationRequest(
                    identifier: "lowquota-\(mac.macId)-\(metric.provider.rawValue)",
                    content: notificationContent(
                        title: "額度即將用完",
                        body: "\(mac.label) · \(metric.provider.displayName) 5 小時剩餘額度低於 10%。"
                    ),
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                )
                try? await center.add(request)
            }
        }
    }

    /// Pre-schedule a `UNNotificationRequest` at each Mac × provider's 5h
    /// AND weekly resetDate. 5 小時與每週各由獨立 toggle 控制（resetEnabled
    /// / weeklyResetEnabled）。Re-adding with the same id overwrites the
    /// pending request, so a Mac uploading a new resetDate naturally cancels
    /// the old reminder.
    static func scheduleResetReminders(for aggregate: AggregateSnapshot) async {
        let fiveHourEnabled = NotificationManager.shared.resetEnabled
        let weeklyEnabled = NotificationManager.shared.weeklyResetEnabled
        guard fiveHourEnabled || weeklyEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let now = Date()
        for mac in aggregate.macs {
            for metric in mac.snapshot.metrics {
                if fiveHourEnabled,
                   let resetDate = metric.resetDate,
                   resetDate > now {
                    let request = UNNotificationRequest(
                        identifier: "reset-\(mac.macId)-\(metric.provider.rawValue)",
                        content: notificationContent(
                            title: "5 小時額度已重置",
                            body: "\(mac.label) · \(metric.provider.displayName) 5 小時用量已重置，可以繼續用了。"
                        ),
                        trigger: UNTimeIntervalNotificationTrigger(
                            timeInterval: max(1, resetDate.timeIntervalSinceNow),
                            repeats: false
                        )
                    )
                    try? await center.add(request)
                }

                if weeklyEnabled,
                   let weeklyResetDate = metric.weeklyResetDate,
                   weeklyResetDate > now {
                    let request = UNNotificationRequest(
                        identifier: "weeklyreset-\(mac.macId)-\(metric.provider.rawValue)",
                        content: notificationContent(
                            title: "每週額度已重置",
                            body: "\(mac.label) · \(metric.provider.displayName) 每週用量已重置，可以繼續用了。"
                        ),
                        trigger: UNTimeIntervalNotificationTrigger(
                            timeInterval: max(1, weeklyResetDate.timeIntervalSinceNow),
                            repeats: false
                        )
                    )
                    try? await center.add(request)
                }
            }
        }
    }

    static func cancelLowQuotaWarnings() async {
        await cancelPendingRequests(withPrefix: "lowquota-")
    }

    static func cancelFiveHourResetReminders() async {
        await cancelPendingRequests(withPrefix: "reset-")
    }

    static func cancelWeeklyResetReminders() async {
        await cancelPendingRequests(withPrefix: "weeklyreset-")
    }

    private static func cancelPendingRequests(withPrefix prefix: String) async {
        let center = UNUserNotificationCenter.current()
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private static func notificationContent(title: String, body: String) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return content
    }
}
