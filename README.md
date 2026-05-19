# Pelu

Pelu is a lightweight Apple-platform tool for checking Claude Code and Codex usage from iPhone, widgets, Live Activities, and a macOS menu bar bridge.

## Current State

This repo currently contains the first implementation slice:

- `PeluCore`: shared models, JSON coding, initial loose parsers, and App Group cache wrapper.
- `UsageHTTPServer`: a lightweight local HTTP server that serves `GET /usage` as `UsageSnapshot` JSON.
- `CloudUsageClient`: shared Swift client for the Cloudflare Worker `GET /usage` and `POST /usage` MVP API.
- `PeluUI`: shared SwiftUI dashboard components based on the Soft Signal visual direction.
- `Pelu` iOS app: a SwiftUI dashboard screen that refreshes from the Mac local endpoint first, then falls back to Cloudflare when a shared secret is configured.
- `Cloudflare`: Worker scaffold for `pelu.tobywu.org`, backed by KV and a shared secret.
- `PeluMacPrototype`: a macOS `MenuBarExtra` prototype that renders demo usage data.
- `Pelu.xcodeproj`: an Xcode project with `Pelu` iOS and `PeluMac` macOS app targets wired to `PeluCore` and `PeluUI`.

## Bundle Identifiers

- iOS app: `org.tobywu.pelu`
- Widget: `org.tobywu.pelu.widget`
- Live Activity: `org.tobywu.pelu.liveactivity`
- macOS app: `org.tobywu.pelu.mac`
- App Group: `group.org.tobywu.pelu`
- Backend domain: `pelu.tobywu.org`

## Local Verification

```sh
swift test
swift build
xcodebuild -project Pelu.xcodeproj -scheme Pelu -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Pelu.xcodeproj -scheme PeluMac -destination 'generic/platform=macOS' build
```

`PeluMac` starts a local demo usage endpoint on launch:

```sh
curl http://127.0.0.1:8765/usage
```

The iOS simulator dashboard can refresh from the same endpoint:

```text
http://127.0.0.1:8765/usage
```

This works in the simulator because simulator localhost resolves to the Mac. On a physical iPhone, localhost is the phone itself, so use the Mac LAN endpoint shown in the `PeluMac` popover instead:

```text
http://192.168.x.x:8765/usage
```

In the iOS app, tap the Mac/iPhone toolbar button, paste the endpoint, save, then refresh. The iOS target includes Local Network permission text and allows local HTTP networking for this development path. If the first real-device connection still fails, confirm both devices are on the same Wi-Fi and allow incoming connections if macOS Firewall prompts for `PeluMac`.

## Cloud MVP

The primary non-Wi-Fi channel is `https://pelu.tobywu.org/usage`.

MVP auth uses a shared secret:

```http
Authorization: Bearer <secret>
```

Worker files live in `Cloudflare/`:

- `Cloudflare/src/index.ts`
- `Cloudflare/wrangler.toml`
- `Cloudflare/README.md`

Runtime setup:

```sh
cd Cloudflare
wrangler kv namespace create PELU_USAGE_KV
wrangler secret put PELU_SHARED_SECRET
wrangler deploy
```

After deployment:

- Mac app: set `PELU_SHARED_SECRET` before launching from a dev shell, or later use the planned settings UI. If set, `PeluMac` uploads the current snapshot to the Worker on launch.
- iOS app: open the Mac/iPhone toolbar settings, keep cloud endpoint as `https://pelu.tobywu.org/usage`, enter the shared secret, then refresh. The app tries local first and falls back to cloud.

If `xcodebuild` fails because the active developer directory is Command Line Tools, switch to full Xcode before building platform app targets:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Or prefix commands without changing the global developer directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pelu.xcodeproj -scheme Pelu -destination 'generic/platform=iOS Simulator' build
```
