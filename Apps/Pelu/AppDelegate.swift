import CloudKit
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Required for CKQuerySubscription delivery — iOS needs an APNs device token
        // to route CloudKit silent pushes. No prompt is shown to the user; this only
        // works at all because the app entitlement includes `aps-environment`.
        application.registerForRemoteNotifications()

        // Become the UNUserNotificationCenter delegate so foreground notifications
        // (banner + sound) actually appear instead of being silently consumed —
        // by default iOS drops them when the target app is active.
        UNUserNotificationCenter.current().delegate = self

        // All navigation bar titles (large + inline) use the same SourceHanSerifTC-Bold
        // we render the greeting hero in — keeps the typographic identity coherent
        // across tabs instead of mixing serif heroes with SF Pro titles.
        applyNavigationTitleFont()

        return true
    }

    private func applyNavigationTitleFont() {
        let inlineSize: CGFloat = 17
        let largeSize: CGFloat = 30

        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        if let inlineFont = UIFont(name: "SourceHanSerifTC-Bold", size: inlineSize) {
            appearance.titleTextAttributes[.font] = inlineFont
        }
        if let largeFont = UIFont(name: "SourceHanSerifTC-Bold", size: largeSize) {
            appearance.largeTitleTextAttributes[.font] = largeFont
        }

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
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

// Conformance in an extension + nonisolated method so the protocol's main
// actor isolation doesn't fight Swift 6 strict concurrency. The body just
// hands a value back; no UI work, no shared mutable state.
extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }
}
