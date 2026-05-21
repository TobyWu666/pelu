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

        // Low-quota: fire when 5h usage% crosses 90 (data-driven).
        if let previous = previousAggregate {
            await LocalUsageNotifier.notifyLowQuotaCrossings(from: previous, to: aggregate)
        }
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

    /// Fire when 5h `usedPercent` crosses the low-quota threshold upward.
    /// Per-Mac × per-provider; honors the user's `lowQuotaEnabled` toggle.
    static func notifyLowQuotaCrossings(
        from previous: AggregateSnapshot,
        to current: AggregateSnapshot
    ) async {
        guard NotificationManager.shared.lowQuotaEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let prevByMac = Dictionary(uniqueKeysWithValues: previous.macs.map { ($0.macId, $0) })
        for mac in current.macs {
            guard let prevMac = prevByMac[mac.macId] else { continue }
            let prevMetrics = Dictionary(uniqueKeysWithValues: prevMac.snapshot.metrics.map { ($0.provider, $0) })
            for metric in mac.snapshot.metrics {
                guard let prev = prevMetrics[metric.provider],
                      let prevUsed = prev.usedPercent,
                      let curUsed = metric.usedPercent,
                      prevUsed <= lowQuotaThreshold,
                      curUsed > lowQuotaThreshold else { continue }

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
    /// resetDate so the user is told the moment they can resume — no fresh
    /// CloudKit fetch or CLI activity required. Re-adding with the same id
    /// overwrites the pending request, so a Mac uploading a new resetDate
    /// naturally cancels the old reminder.
    static func scheduleResetReminders(for aggregate: AggregateSnapshot) async {
        guard NotificationManager.shared.resetEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let now = Date()
        for mac in aggregate.macs {
            for metric in mac.snapshot.metrics {
                guard let resetDate = metric.resetDate, resetDate > now else { continue }
                let interval = max(1, resetDate.timeIntervalSinceNow)
                let request = UNNotificationRequest(
                    identifier: "reset-\(mac.macId)-\(metric.provider.rawValue)",
                    content: notificationContent(
                        title: "額度已重置",
                        body: "\(mac.label) · \(metric.provider.displayName) 用量已重置，可以繼續用了。"
                    ),
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                )
                try? await center.add(request)
            }
        }
    }

    private static func notificationContent(title: String, body: String) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return content
    }
}
