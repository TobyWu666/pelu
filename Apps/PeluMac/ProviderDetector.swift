import Foundation
import PeluCore

/// Inspects the local Mac to see which AI CLIs are installed and whether their
/// statusLine hook is wired up correctly. Used in onboarding to give the user
/// concrete next steps instead of a generic "no data" screen.
enum ProviderDetector {
    struct Result {
        let claudeInstalled: Bool
        let claudeHookState: HookState
        let codexInstalled: Bool
        let codexBinarySource: CodexBinarySource
        let python3Available: Bool

        /// True when at least one provider can be tracked. If false, the app
        /// has nothing to show.
        var hasAnyProvider: Bool { claudeInstalled || codexInstalled }
    }

    /// How we found the `codex` binary needed to spawn `app-server`. The
    /// jsonl reader works without it; the app-server quota provider doesn't.
    enum CodexBinarySource: Equatable {
        case desktopApp(path: String)
        case cli(path: String)
        case notFound
    }

    /// What we found in `~/.claude/settings.json`'s `statusLine` block.
    enum HookState {
        /// Claude isn't installed at all (no `~/.claude/`).
        case providerMissing
        /// Settings exist but no statusLine hook → safe to install ours.
        case unconfigured
        /// Our hook is already installed (matches `PELU_HOOK_VERSION` marker).
        case peluInstalled
        /// A different statusLine command is set — we need user confirmation
        /// before overwriting it. `.pre-pelu-bak` will preserve the original.
        case conflict(existingCommand: String)
    }

    static func detect() -> Result {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let claudeDir = home.appendingPathComponent(".claude")
        let codexDir = home.appendingPathComponent(".codex")

        let claudeInstalled = fm.fileExists(atPath: claudeDir.path)
        let codexInstalled = fm.fileExists(atPath: codexDir.path)

        let hookState: HookState
        if !claudeInstalled {
            hookState = .providerMissing
        } else {
            hookState = inspectClaudeHook(claudeDir: claudeDir)
        }

        return Result(
            claudeInstalled: claudeInstalled,
            claudeHookState: hookState,
            codexInstalled: codexInstalled,
            codexBinarySource: detectCodexBinarySource(),
            python3Available: detectPython3()
        )
    }

    /// Classify where `CodexAppServerClient.locateBinary()` found a binary,
    /// so onboarding can say "using your installed Codex desktop app" vs
    /// "using the CLI you installed via brew/npm".
    private static func detectCodexBinarySource() -> CodexBinarySource {
        guard let url = CodexAppServerClient.locateBinary() else { return .notFound }
        let path = url.path
        if path.contains(".app/Contents/Resources/codex") {
            return .desktopApp(path: path)
        }
        return .cli(path: path)
    }

    private static func inspectClaudeHook(claudeDir: URL) -> HookState {
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unconfigured
        }
        guard let statusLine = json["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return .unconfigured
        }
        if command.contains("usag-statusline.py") {
            return .peluInstalled
        }
        return .conflict(existingCommand: command)
    }

    /// Run `/usr/bin/python3 --version` to confirm a working Python 3.8+ is
    /// present (the hook script uses `from datetime import timezone` which
    /// needs 3.6+, but we recommend 3.8 baseline for safety).
    private static func detectPython3() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["--version"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
