import AppKit
import Foundation

/// 偵測 PeluMac.app 目前的執行位置，若不在 `/Applications/` 提示使用者移過去。
///
/// **為什麼**：使用者反映「每次開啟都被問允許讀取資料夾」。最常見的根因不是
/// 程式碼真的去碰 `~/Downloads`，而是 PeluMac.app 還放在下載/桌面等 TCC
/// 受保護的資料夾裡 — macOS 的 Gatekeeper App Translocation 會把 app 掛到
/// 隨機 `/private/var/folders/.../AppTranslocation/<uuid>/d/...` 位置執行，
/// 結果：
///   1. 每次開啟 bundle 路徑都不同 → TCC 把它當不同 app，記不住授權
///   2. 因為 app binary 住在下載資料夾，macOS 會跳出「允許 Pelu 讀取下載」
///   3. 即使授權也只對「這次 translocation」有效，下次又會再問
///
/// 把 app 移到 `/Applications/` 後路徑穩定、Gatekeeper 不再 translocate，
/// TCC 授權才會被永久記住。這是 Slack / Discord 等 app 都採用的標準作法。
@MainActor
enum AppLocationHelper {
    private static let suppressionKey = "pelu.suppressMoveToApplications"

    /// 在 app 啟動完成後呼叫一次。translocated 一定提示（且無法忽略）；
    /// 否則僅在使用者沒按過「下次再說（不再提醒）」時才提示。
    static func warnIfNeeded() {
        let bundleURL = Bundle.main.bundleURL
        let path = bundleURL.path

        if path.hasPrefix("/Applications/") {
            return // already installed correctly
        }

        let translocated = path.contains("/AppTranslocation/")

        if !translocated && UserDefaults.standard.bool(forKey: suppressionKey) {
            return // user opted out of the reminder
        }

        presentMoveAlert(translocated: translocated, currentBundleURL: bundleURL)
    }

    private static func presentMoveAlert(translocated: Bool, currentBundleURL: URL) {
        let alert = NSAlert()
        alert.messageText = "請將 Pelu 移到「應用程式」資料夾"
        if translocated {
            alert.informativeText = """
            目前 Pelu 不是從「應用程式」資料夾啟動的，macOS 會用隨機路徑執行它 \
            (App Translocation)，導致每次開啟都重新詢問檔案存取權限。

            移到「應用程式」後，授權會被永久記住，下次開啟不會再問。
            """
        } else {
            alert.informativeText = """
            目前 Pelu 放在 \(currentBundleURL.deletingLastPathComponent().path)。

            把它移到「應用程式」資料夾後，macOS 才會記住你授予的檔案存取權限，\
            下次開啟不會再問你。
            """
        }
        alert.addButton(withTitle: "移到應用程式並重啟")
        alert.addButton(withTitle: translocated ? "稍後手動移動" : "不要再提醒")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            moveAndRelaunch(from: currentBundleURL)
        case .alertSecondButtonReturn:
            if !translocated {
                UserDefaults.standard.set(true, forKey: suppressionKey)
            }
        default:
            break
        }
    }

    private static func moveAndRelaunch(from currentBundleURL: URL) {
        let bundleName = currentBundleURL.lastPathComponent
        let targetURL = URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleName)
        let fm = FileManager.default

        do {
            if fm.fileExists(atPath: targetURL.path) {
                // 同名 app 已存在 → 丟到垃圾桶以保留還原機會。
                var resulting: NSURL?
                try fm.trashItem(at: targetURL, resultingItemURL: &resulting)
            }
            try fm.copyItem(at: currentBundleURL, to: targetURL)
        } catch {
            let failure = NSAlert()
            failure.messageText = "移動 Pelu 失敗"
            failure.informativeText = """
            無法將 Pelu 複製到「應用程式」資料夾：\(error.localizedDescription)

            請手動將 Pelu.app 拖到「應用程式」資料夾後再啟動。
            """
            failure.alertStyle = .warning
            failure.addButton(withTitle: "好")
            failure.runModal()
            return
        }

        // 啟動 /Applications/ 那份新 copy，然後結束自己。
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: targetURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
