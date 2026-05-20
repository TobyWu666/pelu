import CloudKit
import Foundation

/// Friendly wrapper around `CKContainer.accountStatus`. Onboarding and the
/// settings screen both ask this question; centralize the messaging.
public struct CloudKitAccountChecker: Sendable {
    public enum Result: Sendable, Equatable {
        /// User is signed in and CloudKit operations should work.
        case available

        /// User has not signed into iCloud on this device. Show step-by-step
        /// instructions to enable it in System Settings → Apple ID.
        case noAccount

        /// Account exists but is restricted (parental controls or MDM).
        /// User can't enable iCloud Drive features — Pelu won't work.
        case restricted

        /// CloudKit could not determine status (offline, server outage).
        /// Show a transient error and retry button.
        case unknown(underlying: String)

        /// CloudKit returned an unexpected status code (forward compat).
        case unexpected(rawValue: Int)
    }

    public init() {}

    /// Default container, derived from the entitlement-configured CloudKit container.
    /// Apps should pass an explicit container if they need the non-default one.
    public func status(
        container: CKContainer = .default()
    ) async -> Result {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:    return .available
            case .noAccount:    return .noAccount
            case .restricted:   return .restricted
            case .couldNotDetermine:
                return .unknown(underlying: "couldNotDetermine")
            case .temporarilyUnavailable:
                return .unknown(underlying: "temporarilyUnavailable")
            @unknown default:
                return .unexpected(rawValue: status.rawValue)
            }
        } catch {
            return .unknown(underlying: String(describing: error))
        }
    }

    /// Human-readable label for onboarding screens (繁中).
    public static func displayMessage(for result: Result) -> String {
        switch result {
        case .available:
            return "iCloud 已連線"
        case .noAccount:
            return "請先在系統設定 → Apple ID 登入 iCloud。Pelu 不需要儲存空間，資料 < 1KB。"
        case .restricted:
            return "你的 iCloud 帳號目前被限制（家長監護或 MDM 設定）。請先解除限制再使用 Pelu。"
        case .unknown:
            return "暫時無法連到 iCloud，稍後再試。"
        case .unexpected:
            return "iCloud 回傳未知狀態，請更新 Pelu 後再試。"
        }
    }
}
