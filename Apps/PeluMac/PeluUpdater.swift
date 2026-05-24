import Combine
import Foundation
import Sparkle

/// SwiftUI-friendly wrapper around `SPUStandardUpdaterController`.
///
/// PeluMac is **not sandboxed** (we read `~/.claude/` and `~/.codex/`),
/// so Sparkle's plain in-place update flow works without the XPC installer
/// helper. Distribution is Developer ID + Notarize + Staple (see plan §八);
/// Sparkle verifies each downloaded zip with the embedded Ed25519 public key
/// (`SUPublicEDKey`) and that the new app is signed by the same Team ID.
@MainActor
final class PeluUpdater: ObservableObject {
    let controller: SPUStandardUpdaterController

    @Published private(set) var canCheckForUpdates: Bool = true
    private var cancellables = Set<AnyCancellable>()

    init() {
        // startingUpdater: true — Sparkle reads SUFeedURL / SUPublicEDKey
        // from Info.plist on init. Automatic checks default to OFF in
        // Info.plist (SUEnableAutomaticChecks=NO); user opts in from Settings.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Bound to the "自動檢查更新" toggle in Settings.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
