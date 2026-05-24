import Foundation
import ServiceManagement

/// 包 `SMAppService.mainApp` 給設定頁的「開機自動啟動」toggle 用。
///
/// `SMAppService.mainApp` 是 macOS 13+ 的新 API，註冊主 app 為登入項目；
/// 不需要 helper bundle，狀態以系統為真值（使用者也可從「系統設定 → 一般 →
/// 登入項目」自己關掉）。
enum LaunchAtLogin {
    enum Result {
        case success
        /// 系統需要使用者在「系統設定 → 登入項目」中允許。
        case needsApproval
        case failure(String)
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enable: Bool) -> Result {
        let service = SMAppService.mainApp
        do {
            if enable {
                try service.register()
                return service.status == .requiresApproval ? .needsApproval : .success
            } else {
                try service.unregister()
                return .success
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
