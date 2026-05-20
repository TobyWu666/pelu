import CloudKit
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Required for CKQuerySubscription delivery — iOS needs an APNs device token
        // to route CloudKit silent pushes. No prompt is shown to the user; this only
        // works at all because the app entitlement includes `aps-environment`.
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // We don't ship the token anywhere — CloudKit manages routing internally.
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("Pelu APNs registration failed: \(error)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // CloudKit subscriptions deliver notifications shaped like
        // { "ck": { ...subscription metadata... } }. Anything not parseable
        // as a CKNotification isn't for us — could be a future push from another
        // subsystem we add later.
        guard let _ = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            completionHandler(.noData)
            return
        }

        Task { @MainActor in
            do {
                _ = try await UsageSurfaceUpdater.fetchFromCloud(
                    updateLiveActivity: UserDefaults.standard.bool(forKey: "pelu.liveActivityEnabled")
                )
                completionHandler(.newData)
            } catch {
                NSLog("Pelu CloudKit fetch failed: \(error)")
                completionHandler(.failed)
            }
        }
    }
}
