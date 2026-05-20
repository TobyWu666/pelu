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

        let aggregate = try await syncer.fetchAllMacs()

        try? AppGroupStore()?.save(aggregate)
        // Local-only history: record once per fetch. The store keeps one
        // entry per calendar day, so the natural midnight rollover gives us
        // "yesterday's final reading" automatically.
        try? UsageHistoryStore()?.record(aggregate)
        WidgetCenter.shared.reloadAllTimelines()

        // Live Activity tracks the primary Mac (alphabetically first label).
        // Multi-Mac UX for Live Activity is a future enhancement.
        if updateLiveActivity, let primary = aggregate.primary {
            LiveActivityManager.shared.update(with: primary.snapshot)
        }

        return aggregate
    }
}
