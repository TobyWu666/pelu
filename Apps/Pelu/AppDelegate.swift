import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            NotificationManager.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // 取不到 APNs token 不阻擋 app 啟動，使用者下次切換 toggle 時會再試。
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Only react to Pelu's own background pushes — ignore any other push that may
        // be added later. The Worker tags refresh pushes with `peluRefresh = 1`.
        guard let refresh = userInfo["peluRefresh"], "\(refresh)" != "0" else {
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
                NSLog("Pelu silent push fetch failed: \(error)")
                completionHandler(.failed)
            }
        }
    }
}
