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

        // Low-quota: fire when the primary-window usage crosses 90%.
        // Pass an empty aggregate when there's no prior data so the notifier
        // still has a chance to alert on a first-launch already-above-90 case.
        await LocalUsageNotifier.notifyLowQuotaCrossings(
            from: previousAggregate ?? AggregateSnapshot(macs: []),
            to: aggregate
        )
        // Reset: schedule reminders from the same composite shown on the
        // dashboard so several Macs cannot each generate a duplicate alert.
        await LocalUsageNotifier.scheduleResetReminders(for: aggregate)

        return aggregate
    }
}

/// Local UNNotification scheduling for low-quota crossings (data-driven) and
/// upcoming reset times (time-scheduled at exact resetDate).
@MainActor
enum LocalUsageNotifier {
    private static let lowQuotaThreshold: Double = 90

    /// Fire when the dashboard's displayed primary window enters the >90%
    /// zone for a provider.
    /// Triggers on:
    ///   - first observation that's already over the threshold (no previous data)
    ///   - upward crossing from ≤90 to >90
    /// Does NOT trigger on:
    ///   - sustained values above threshold (previous was also >90 — already alerted)
    /// Per-provider only; honors the user's `lowQuotaEnabled` toggle.
    static func notifyLowQuotaCrossings(
        from previous: AggregateSnapshot,
        to current: AggregateSnapshot
    ) async {
        guard NotificationManager.shared.lowQuotaEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let now = Date()
        let previousMetrics = Dictionary(
            uniqueKeysWithValues: (previous.displaySnapshot(at: now)?.metrics ?? []).map {
                ($0.provider, $0)
            }
        )
        guard let display = current.displaySnapshot(at: now) else { return }

        for metric in display.metrics {
            guard let curUsed = metric.usedPercent, curUsed > lowQuotaThreshold else { continue }

            // Skip if the displayed value was already over the threshold.
            if let prevUsed = previousMetrics[metric.provider]?.usedPercent,
               prevUsed > lowQuotaThreshold {
                continue
            }

            let request = UNNotificationRequest(
                identifier: "lowquota-\(metric.provider.rawValue)",
                content: notificationContent(
                    title: "額度即將用完",
                    body: "\(metric.provider.displayName) \(UsageMetric.windowLabel(durationMins: metric.resolvedPrimaryWindowDurationMins))額度剩餘低於 10%。"
                ),
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            try? await center.add(request)
        }
    }

    /// Pre-schedule requests for each displayed provider window. The provider-
    /// reported duration decides whether the short-term or weekly toggle applies.
    /// The dashboard snapshot is authoritative: pending requests
    /// from a previous per-Mac version or a prior winner are replaced on sync.
    static func scheduleResetReminders(for aggregate: AggregateSnapshot) async {
        let fiveHourEnabled = NotificationManager.shared.resetEnabled
        let weeklyEnabled = NotificationManager.shared.weeklyResetEnabled
        await cancelPendingRequests(withPrefix: "reset-")
        await cancelPendingRequests(withPrefix: "weeklyreset-")
        guard fiveHourEnabled || weeklyEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let now = Date()
        guard let display = aggregate.displaySnapshot(at: now) else { return }
        for metric in display.metrics {
            await scheduleReset(
                provider: metric.provider,
                slot: "primary",
                resetDate: metric.resetDate,
                durationMins: metric.resolvedPrimaryWindowDurationMins,
                shortTermEnabled: fiveHourEnabled,
                weeklyEnabled: weeklyEnabled,
                center: center,
                now: now
            )
            await scheduleReset(
                provider: metric.provider,
                slot: "secondary",
                resetDate: metric.weeklyResetDate,
                durationMins: metric.resolvedSecondaryWindowDurationMins,
                shortTermEnabled: fiveHourEnabled,
                weeklyEnabled: weeklyEnabled,
                center: center,
                now: now
            )
        }
    }

    private static func scheduleReset(
        provider: ProviderKind,
        slot: String,
        resetDate: Date?,
        durationMins: Int,
        shortTermEnabled: Bool,
        weeklyEnabled: Bool,
        center: UNUserNotificationCenter,
        now: Date
    ) async {
        guard let resetDate, resetDate > now else { return }
        let isWeekly = durationMins >= 7 * 24 * 60
        guard isWeekly ? weeklyEnabled : shortTermEnabled else { return }

        let prefix = isWeekly ? "weeklyreset" : "reset"
        let label = UsageMetric.windowLabel(durationMins: durationMins)
        let request = UNNotificationRequest(
            identifier: "\(prefix)-\(provider.rawValue)-\(slot)",
            content: notificationContent(
                title: "\(label)額度已重置",
                body: "\(provider.displayName) \(label)用量已重置，可以繼續用了。"
            ),
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, resetDate.timeIntervalSinceNow),
                repeats: false
            )
        )
        try? await center.add(request)
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

    /// Versions before display-based notifications stored one reset request
    /// per Mac (`reset-<macId>-<provider>`). Drop those at launch so an
    /// upgraded install cannot deliver duplicates before its next cloud fetch.
    static func cancelLegacyPerMacResetReminders() async {
        let center = UNUserNotificationCenter.current()
        let requests = await center.pendingNotificationRequests()
        let validDisplayIDs = Set(
            ProviderKind.allCases.flatMap { provider in
                ["reset-\(provider.rawValue)", "weeklyreset-\(provider.rawValue)"]
            }
        )
        let identifiers = requests.map(\.identifier).filter {
            ($0.hasPrefix("reset-") || $0.hasPrefix("weeklyreset-"))
                && !validDisplayIDs.contains($0)
        }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
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
