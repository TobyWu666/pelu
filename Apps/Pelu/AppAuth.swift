import Foundation
import PeluCore

/// Owns the iPhone's per-device pair token. The Worker issued this token via
/// `/pair/claim` after the user typed the Mac's 6-digit pairing code; we hold it
/// in the Keychain and use it as the bearer secret for every cloud call.
///
/// Auth is missing → app shows the pairing screen and refuses to call /usage.
@MainActor
@Observable
final class AppAuth {
    static let shared = AppAuth()

    private(set) var pairToken: String?

    private let store = KeychainSecretStore(service: PeluConfig.keychainService)
    private let account = KeychainSecretStore.Account.pairToken

    private init() {
        pairToken = (try? store.get(account: account)) ?? nil
    }

    var isPaired: Bool { (pairToken?.isEmpty ?? true) == false }

    enum PairingError: LocalizedError, Equatable {
        case invalidCode
        case codeExpired
        case codeNotFound
        case server(Int)
        case transport

        var errorDescription: String? {
            switch self {
            case .invalidCode:  return "配對碼格式錯誤"
            case .codeExpired:  return "配對碼已過期，請在 Mac 重新產生"
            case .codeNotFound: return "找不到這個配對碼"
            case .server(let code): return "伺服器錯誤（\(code)）"
            case .transport:    return "網路連線失敗"
            }
        }
    }

    /// Exchange a 6-digit code for a long-lived pair token. On success the token
    /// is persisted to the Keychain and `pairToken` updates synchronously.
    func claim(code: String) async throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\d{6}$"#, options: .regularExpression) != nil else {
            throw PairingError.invalidCode
        }

        var request = URLRequest(url: PeluConfig.pairClaimEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": trimmed])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PairingError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw PairingError.transport }

        switch http.statusCode {
        case 200: break
        case 404: throw PairingError.codeNotFound
        case 410: throw PairingError.codeExpired
        case 400: throw PairingError.invalidCode
        default:  throw PairingError.server(http.statusCode)
        }

        struct ClaimResponse: Decodable { let pairToken: String }
        let decoded = try JSONDecoder().decode(ClaimResponse.self, from: data)
        try store.set(decoded.pairToken, account: account)
        pairToken = decoded.pairToken
    }

    /// Wipe local token. Use this from settings ("Re-pair this device") or
    /// programmatically if the server returns 401 on every request.
    func reset() {
        try? store.remove(account: account)
        pairToken = nil
    }
}
