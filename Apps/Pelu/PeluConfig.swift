import Foundation

// iOS 端的 endpoint 與 Keychain 名稱。
// **沒有共享 secret**：iPhone 用 `/pair/claim` 取得的 per-device token，存在 Keychain。
// 第一次啟動會跑配對流程。檔案內容公開無 secret，不再需要 gitignore。
enum PeluConfig {
    static let usageEndpoint      = URL(string: "https://pelu.tobywu.org/usage")!
    static let deviceEndpoint     = URL(string: "https://pelu.tobywu.org/device")!
    static let pairClaimEndpoint  = URL(string: "https://pelu.tobywu.org/pair/claim")!
    static let keychainService    = "org.tobywu.pelu"
}
