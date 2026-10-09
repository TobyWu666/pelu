# Pelu

把 Mac 上 Claude Code 與 Codex 的用量配額，即時同步到 iPhone 主畫面、Widget 與動態島。

**全部透過使用者自己的 iCloud Private Database 同步**——沒有 Pelu 後端、沒有帳號註冊、沒有配對流程。Mac 和 iPhone 登入同一個 iCloud 帳號就會自動同步。

> 官方網站：<https://pelu.wutoby.com> /
> iPhone App：App Store「Pelu」/
> Mac App：<https://github.com/TobyWu666/pelu-releases/releases/latest> /

---

## 功能

### iPhone App
- **Dashboard**：Claude Code 與 Codex 的即時配額視窗、reset 倒數（依 provider 回傳的週期顯示）
- **多 Mac 聚合**：同一個 iCloud 帳號裝多台 Mac 時，自動聚合顯示(Claude 取用量最高的那台,Codex 取最新一筆帳號層級量測)
- **歷史紀錄**：30 天用量紀錄與花費估算（gpt-5-codex API 等值計算）
- **桌面 Widget**：small / medium 兩種尺寸
- **Live Activity**：鎖屏與動態島即時顯示配額與 reset 倒數
- **通知**：短期與每週 reset 提醒、低額度警告
- **斷線提示**：超過 5 分鐘沒收到新資料會在 header 顯示「斷線」狀態

### PeluMac
- Menu bar 常駐 app,可選擇是否顯示 Claude / Codex 百分比數字
- 第一次啟動時偵測 iCloud、Claude Code、Codex 並引導安裝 statusLine hook
- 獨立 Settings 視窗,支援 Sparkle 自動更新
- 自動讀取本機用量並寫入 CloudKit
- 「登入時自動啟動」選項
- 自動偵測 app 安裝位置,避免從 DMG 直接執行造成 translocation 問題

---

## 工作原理

```
┌──────────────────────────────────────────────────┐
│ Mac                                              │
│                                                  │
│  Claude Code statusLine hook                     │
│         ↓                                        │
│  ~/.claude/usag-status.json                      │
│                                                  │
│  Codex app-server RPC (主)                       │
│  ~/.codex/sessions/*.jsonl (備援)                │
│         ↓                                        │
│        PeluMac                                   │
│         ↓                                        │
│  CKDatabase.save(MacSnapshot)                    │
└────────────────────┬─────────────────────────────┘
                     ↓
        ┌─────────────────────────┐
        │ 使用者自己的 iCloud      │
        │ Private Database         │
        └────────────┬─────────────┘
                     │ CKQuerySubscription
                     │ + silent APNs push
                     ↓
┌──────────────────────────────────────────────────┐
│ iPhone                                           │
│  Pelu App / Widget / Live Activity               │
└──────────────────────────────────────────────────┘
```

### 用量資料來源

| Provider | 主要來源 | 備援 |
|---|---|---|
| Claude Code | Pelu 安裝的 statusLine hook 寫進 `~/.claude/usag-status.json` | — |
| Codex | `codex app-server` JSON-RPC `account/rateLimits/read`（官方 quota） | `~/.codex/sessions/*.jsonl` 推算 |

Codex RPC 會優先使用 ChatGPT／Codex 桌面 app 內附的 binary(`/Applications/ChatGPT.app` 或 `/Applications/Codex.app` 的 `Contents/Resources/codex`),不需要使用者另外裝 CLI。

### 認證

完全不需要 token 或密碼。**iCloud 帳號就是身分**——CloudKit 自動隔離不同 Apple ID 的 private database。

---

## 系統需求

- **iOS 17.0+**(iPhone)
- **macOS 14.0+ Sonoma**(Mac)
- Mac 與 iPhone 登入同一個 iCloud 帳號

---

## 隱私

- **不收集任何使用者資料**,符合 Apple App Store「Data Not Collected」標準
- **資料只存在使用者自己的 iCloud Private Database**,Pelu 開發者沒有任何技術手段可以存取
- 沒有 Pelu 後端伺服器、沒有第三方分析、沒有廣告 SDK
- 詳細隱私政策:<https://pelu.wutoby.com/privacy.html>

---

## 專案結構

```
Pelu/
├─ Apps/
│  ├─ Pelu/                 iOS app
│  ├─ PeluMac/              macOS menu bar app
│  ├─ PeluWidget/           Widget + Live Activity
│  └─ Shared/               跨平台共用 assets
├─ Sources/
│  ├─ PeluCore/             model、parser、CloudKit、Codex RPC client
│  ├─ PeluUI/               共用 SwiftUI 元件與主題
│  └─ PeluMacPrototype/     SwiftPM prototype
├─ Tests/PeluCoreTests/     單元測試
├─ scripts/                 release.sh、Sparkle 工具、appcast 範本
├─ assets/                  原始 logo / icon 素材
├─ AGENTS.md                開發與協作守則(架構、契約、發版流程)
├─ Pelu.xcodeproj
└─ Package.swift
```

### Bundle ID

| 元件 | ID |
|---|---|
| iOS App | `org.tobywu.pelu` |
| Widget | `org.tobywu.pelu.widget` |
| macOS App | `org.tobywu.pelu.mac` |
| App Group | `group.org.tobywu.pelu` |
| CloudKit Container | `iCloud.org.tobywu.pelu` |

> Fork 此專案時,需要把以上所有 ID 換成你自己 Apple Developer Team 下的 ID,並到 CloudKit Console 建立對應 container,否則 build 與 CloudKit 同步都無法運作。

---

## 開發者區

### Build & Test

需要完整 Xcode(不只 Command Line Tools)。

```sh
# Swift package 測試與 build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build

# iOS app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Pelu.xcodeproj -scheme Pelu \
  -destination 'generic/platform=iOS' build

# Mac app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Pelu.xcodeproj -scheme PeluMac \
  -destination 'generic/platform=macOS' build
```

### 發版、架構與開發守則

Mac 發版流程(`scripts/release.sh`、Sparkle、Notarization)、App Store Connect 狀態查詢、不可變更的契約、CloudKit 環境與資料流細節都在 [AGENTS.md](./AGENTS.md)。

---

## 技術棧

- **語言**:Swift 6.0
- **UI**:SwiftUI(iOS + macOS 都是 SwiftUI 為主)
- **持久化 / 同步**:CloudKit Private Database、UserDefaults、App Group
- **依賴**:[Sparkle](https://sparkle-project.org/)(macOS 自動更新)
- **打包**:Xcode + SwiftPM hybrid(`Pelu.xcodeproj` + `Package.swift`)
- **發版**:Developer ID + Notarization(macOS)、App Store Connect(iOS)

---

## 授權

本專案以 [MIT License](./LICENSE) 釋出。

捆綁的 [Source Han Serif TC](https://github.com/adobe-fonts/source-han-serif) 字型由 Adobe 設計,以 SIL Open Font License 1.1 授權——授權條文見 [`Apps/Pelu/Resources/Fonts/LICENSE.txt`](./Apps/Pelu/Resources/Fonts/LICENSE.txt),署名見 [NOTICE](./NOTICE)。

---

## 作者

[Kuan Ting Wu (Toby)](https://github.com/TobyWu666)
