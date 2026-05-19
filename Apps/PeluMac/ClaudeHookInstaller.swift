import Foundation

/// Installs Claude Code's statusLine hook so Pelu can read usage data.
///
/// Claude Code doesn't ship `~/.claude/usag-status.json`; that file is written
/// by a custom statusLine hook (concept borrowed from aqua5230/usage). On every
/// statusline refresh Claude Code pipes the session JSON to the hook over stdin,
/// and we just persist it to disk for PeluMac to pick up via FSEvents.
///
/// Auto-runs on PeluMac launch; idempotent.
enum ClaudeHookInstaller {
    private static let claudeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")
    private static let hookScriptURL = claudeDir.appendingPathComponent("usag-statusline.py")
    private static let settingsURL = claudeDir.appendingPathComponent("settings.json")

    /// Bump this when the embedded hook script changes so we know to overwrite
    /// older copies on disk.
    private static let scriptVersion = "2"
    private static let versionMarker = "# PELU_HOOK_VERSION="

    /// True when (a) the hook script exists at the current embedded version,
    /// AND (b) settings.json points at it.
    static func isInstalled() -> Bool {
        guard let onDisk = try? String(contentsOf: hookScriptURL, encoding: .utf8) else { return false }
        guard onDisk.contains("\(versionMarker)\(scriptVersion)") else { return false }
        guard let data = try? Data(contentsOf: settingsURL) else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let statusLine = json["statusLine"] as? [String: Any] else { return false }
        let command = statusLine["command"] as? String ?? ""
        return command.contains("usag-statusline.py")
    }

    /// Install the hook script + wire it into settings.json. Backs up any
    /// existing settings.json to settings.json.pelu-bak before overwriting.
    static func install() throws {
        try FileManager.default.createDirectory(
            at: claudeDir, withIntermediateDirectories: true
        )

        // 1. Write the Python hook script.
        try hookScript.write(to: hookScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: hookScriptURL.path
        )

        // 2. Merge into settings.json (preserve any existing keys).
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
            // Back up only once — don't overwrite an earlier backup that might
            // contain even older settings.
            let backup = settingsURL.appendingPathExtension("pelu-bak")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? data.write(to: backup, options: .atomic)
            }
        }
        settings["statusLine"] = [
            "type": "command",
            "command": "/usr/bin/python3 \(hookScriptURL.path)",
        ]
        let out = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try out.write(to: settingsURL, options: .atomic)
    }

    /// Silent install on launch if not already wired up. Failures are logged
    /// but don't block app startup — user can re-trigger from the menu bar.
    static func installIfNeeded() {
        guard !isInstalled() else { return }
        do {
            try install()
            NSLog("Pelu: installed Claude Code statusLine hook at \(hookScriptURL.path)")
        } catch {
            NSLog("Pelu: failed to install Claude Code hook: \(error)")
        }
    }

    // The Python script is embedded as a string constant so the .app is
    // self-contained — no separate file to ship.
    private static let hookScript: String = """
    #!/usr/bin/env python3
    # PELU_HOOK_VERSION=2
    \"\"\"Claude Code statusLine hook: persist the session JSON to disk.

    Claude Code pipes the full session JSON (with rate_limits.five_hour /
    seven_day, context_window, cost) to stdin on every statusLine refresh.
    We write it to ~/.claude/usag-status.json without echoing any output,
    so the user's existing statusLine renderer is unaffected.

    Stdlib-only so any system python3 can run this.
    \"\"\"

    from __future__ import annotations

    import contextlib
    import json
    import os
    import sys
    import tempfile
    from datetime import datetime, timezone
    from typing import Any

    UTC = timezone.utc  # datetime.UTC only exists in 3.11+; alias for older python3.

    STATUS_FILE = os.path.expanduser("~/.claude/usag-status.json")


    def save(data: dict[str, Any], now: datetime) -> None:
        data["_received_at"] = now.isoformat()
        data["_received_at_ts"] = now.timestamp()
        target_dir = os.path.dirname(STATUS_FILE)
        os.makedirs(target_dir, exist_ok=True)
        tmp_path: str | None = None
        try:
            fd, tmp_path = tempfile.mkstemp(dir=target_dir, suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp_path, STATUS_FILE)
            tmp_path = None
        finally:
            if tmp_path and os.path.exists(tmp_path):
                with contextlib.suppress(OSError):
                    os.unlink(tmp_path)


    def main() -> None:
        try:
            raw = sys.stdin.read()
        except Exception:
            return
        if not raw.strip():
            return
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return
        if not isinstance(data, dict):
            return
        save(data, datetime.now(UTC))


    if __name__ == "__main__":
        main()
    """
}
