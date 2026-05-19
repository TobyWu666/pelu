import Foundation
import PeluCore
import UIKit
import UserNotifications
import WidgetKit

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let lowQuotaKey = "pelu.notify.lowQuota"
    private let resetKey = "pelu.notify.reset"
    private let tokenKey = "pelu.notify.deviceToken"

    var lowQuotaEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: lowQuotaKey) }
        set { UserDefaults.standard.set(newValue, forKey: lowQuotaKey) }
    }

    var resetEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: resetKey) }
        set { UserDefaults.standard.set(newValue, forKey: resetKey) }
    }

    var deviceToken: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }

    private init() {}

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Silent push（含 widget background refresh）不需要 UI 通知權限，
    /// 只要 app 有 `aps-environment` entitlement 就能拿 token。
    /// 每次啟動都呼叫，確保 token rotation 後 Worker 拿到最新 token。
    func ensureDeviceRegistered() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Request permission; on grant, register for remote notifications.
    /// Returns true if the user has at least authorized notifications.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorizationStatus = settings.authorizationStatus
            UIApplication.shared.registerForRemoteNotifications()
            return true
        case .denied:
            authorizationStatus = .denied
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                let updated = await center.notificationSettings()
                authorizationStatus = updated.authorizationStatus
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                return granted
            } catch {
                authorizationStatus = .denied
                return false
            }
        @unknown default:
            return false
        }
    }

    /// Called from AppDelegate after APNs hands us a device token.
    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        self.deviceToken = hex
        Task { await uploadPreferences() }
    }

    /// Push current preferences (with token) to the Worker.
    /// Safe to call from anywhere; no-op if device token or pair token missing.
    func uploadPreferences() async {
        guard let token = deviceToken, !token.isEmpty else { return }
        guard let bearer = AppAuth.shared.pairToken, !bearer.isEmpty else { return }

        var request = URLRequest(url: PeluConfig.deviceEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "deviceToken": token,
            "lowQuota": lowQuotaEnabled,
            "reset": resetEnabled,
            "bundleId": "org.tobywu.pelu",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        _ = try? await URLSession.shared.data(for: request)
    }
}

@MainActor
enum UsageSurfaceUpdater {
    enum UpdaterError: Error { case notPaired }

    static func fetchFromCloud(updateLiveActivity: Bool) async throws -> AggregateSnapshot {
        guard let bearer = AppAuth.shared.pairToken, !bearer.isEmpty else {
            throw UpdaterError.notPaired
        }
        let client = CloudUsageClient(
            endpoint: PeluConfig.usageEndpoint,
            sharedSecret: bearer
        )
        let aggregate = try await client.fetchAggregate()

        try? AppGroupStore()?.save(aggregate)
        WidgetCenter.shared.reloadAllTimelines()

        // Live Activity follows the primary Mac (alphabetically first label).
        // Multi-Mac UX for Live Activity is a future enhancement.
        if updateLiveActivity, let primary = aggregate.primary {
            LiveActivityManager.shared.update(with: primary.snapshot)
        }

        return aggregate
    }
}
