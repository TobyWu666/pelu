# Pelu

把 Mac 上 Claude Code 與 Codex 的用量，即時同步到 iPhone 主畫面、Widget 與動態島。

**完全靠 CloudKit private database 同步**，資料只儲存在使用者自己的 iCloud。沒有 Pelu 伺服器、沒有帳號註冊、沒有配對流程 — 只要 Mac 跟 iPhone 登入同一個 iCloud 帳號就會自動同步。

```
[Claude Code / Codex 寫本機檔案]
              ↓
[PeluMac 讀檔 → CKDatabase.save]
              ↓
[User's iCloud private DB]
              ↓
[CKQuerySubscription → silent APNs push]
              ↓
[iPhone app / Widget / Live Activity]
```

## Components

| 路徑 | 角色 |
|---|---|
| `Sources/PeluCore/` | 共用 Swift package — model、parser、CloudKitSyncer、CloudKit account checker、App Group cache |
| `Sources/PeluUI/` | 共用 SwiftUI 元件（dashboard、status pill、theme） |
| `Apps/Pelu/` | iOS app — dashboard、settings、CloudKit subscription handler |
| `Apps/PeluMac/` | macOS menu bar app — 讀本機 AI CLI 檔案、自動安裝 Claude statusLine hook、寫 CloudKit |
| `Apps/PeluWidget/` | iOS Widget（small + medium）、Live Activity（鎖屏 + 動態島） |
| `Tests/PeluCoreTests/` | Swift Testing 套件 — parsers、Codable round-trip、AppGroup store |

## Bundle Identifiers

| 元件 | ID |
|---|---|
| iOS app | `org.tobywu.pelu` |
| Widget | `org.tobywu.pelu.widget` |
| Live Activity | `org.tobywu.pelu.liveactivity` |
| macOS app | `org.tobywu.pelu.mac` |
| App Group | `group.org.tobywu.pelu` |
| CloudKit container | `iCloud.org.tobywu.pelu` |

## 系統需求

- iOS 17.0+
- macOS 14.0+ (Sonoma)
- 同一個 iCloud 帳號登入 Mac 與 iPhone

## 工作原理

### Mac
1. 第一次啟動：onboarding 檢查 iCloud → 偵測 Claude Code / Codex 安裝 → 自動裝 statusLine hook（修改 `~/.claude/settings.json`，原檔備份成 `.pre-pelu-bak`）
2. FSEvents 監聽 `~/.claude/usag-status.json`（hook 寫出）+ 每分鐘 Timer 掃 `~/.codex/sessions/*.jsonl`
3. 每次數據變化或每分鐘 → `CKDatabase.save(MacSnapshot)`

### iPhone
1. App 啟動 → `CloudKitAccountChecker` 確認 iCloud 可用
2. 註冊 `CKQuerySubscription`（背景 silent push 觸發來源）
3. `CKDatabase.fetch` 拉所有 Mac 的 `MacSnapshot` records → 組成 `AggregateSnapshot`
4. Mac 寫 CloudKit 後幾秒內 → iPhone 收到 silent push → 自動 fetch + 更新 Widget + 更新 Live Activity

### Auth
不需要任何 secret 或 token。iCloud 帳號身分就是 auth — CloudKit 自動隔離不同 Apple ID 的 private database。

## Build & Test

需要完整 Xcode（不只 Command Line Tools）。

```sh
# Swift package
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build

# Apps
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pelu.xcodeproj -scheme Pelu -destination 'generic/platform=iOS Simulator' build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pelu.xcodeproj -scheme Pelu -destination 'generic/platform=iOS' build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pelu.xcodeproj -scheme PeluMac -destination 'generic/platform=macOS' build
```

## 打包 Mac app

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Pelu.xcodeproj -scheme PeluMac \
  -configuration Release -derivedDataPath ./build-release \
  -destination 'generic/platform=macOS' \
  clean build
```

產物：`build-release/Build/Products/Release/PeluMac.app`

公開分發需要：
- **Developer ID 簽章** + **notarization**（否則 Gatekeeper 擋）
- 包成 .dmg + 提供 SHA256

自用 / 朋友分享：可走 ad-hoc 簽章，第一次右鍵 → 打開繞過 Gatekeeper。

## 多 Mac 支援

每台 Mac 在第一次啟動時產生一個 UUID（存在 macOS Keychain），label 用 `Host.localizedName`。Worker side per-Mac KV → CloudKit per-Mac records。iPhone dashboard 為每台 Mac 顯示一張卡片。Widget / Live Activity 顯示「主要 Mac」（依 label 字母排序第一個）— v1.1+ 加 AppIntent configuration 讓使用者選。

## 隱私

- **資料只存在你的 iCloud**，從不送到 Pelu 開發者或第三方伺服器
- Pelu 開發者**沒有任何技術手段**可以讀取你的資料
- App Store Privacy 標籤：`Data Not Collected`

## License

個人專案，未授權商業使用。
