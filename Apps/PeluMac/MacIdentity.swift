import Foundation
import PeluCore

/// Stable identity for this Mac. `macId` is a UUID minted on first launch and
/// stored in the macOS Keychain so it survives reinstalls. `label` is the
/// human-readable hostname (e.g. "Toby's MacBook Pro"), fetched lazily.
enum MacIdentity {
    private static let keychain = KeychainSecretStore(service: "org.tobywu.pelu.mac")
    private static let macIdAccount = "pelu.macId"

    /// Persistent per-machine UUID. Created on first call.
    static func macId() -> String {
        if let stored = try? keychain.get(account: macIdAccount), !stored.isEmpty {
            return stored
        }
        let generated = UUID().uuidString.lowercased()
        try? keychain.set(generated, account: macIdAccount)
        return generated
    }

    /// Human-readable Mac name shown on iPhone (e.g. "Toby's MacBook Pro").
    /// Falls back to ProcessInfo's host name if AppKit's localizedName isn't available.
    static func label() -> String {
        let host = Host.current()
        if let localized = host.localizedName, !localized.isEmpty { return localized }
        return ProcessInfo.processInfo.hostName
    }
}
