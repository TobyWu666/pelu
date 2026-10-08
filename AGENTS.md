# AGENTS.md

給所有在這個 repo 工作的 coding agent（Codex、Claude Code……）的唯一守則。產品介紹與使用者面向說明在 [README.md](./README.md)；`CLAUDE.md` 只是指向本檔。**不要再新增其他說明／規劃 md**，需要記錄的東西寫進本檔對應章節。

Pelu：PeluMac 讀取 Mac 上 Claude Code / Codex 的用量配額 → 寫進使用者自己的 iCloud Private Database → iPhone App / Widget / Live Activity 顯示。沒有後端。

---

## 1. 多 agent 協作規則

這個 repo 會同時有 Codex 與 Claude Code 在改，且放在 iCloud Drive。

1. **開工前**跑 `git status`，並看下面「§8 進行中」。別人列為進行中的檔案不要動。
2. **不屬於你這次任務的未提交修改**：不 revert、不 reformat、不 stash、不順手「修」。
3. **提交只 stage 自己改的檔案**（`git add <path>`），禁止 `git add -A` / `git add .` / `git commit -a`。
4. 開始一件跨多檔或跨多次 session 的工作時，在 §8 加一行（agent、範圍、日期）；完成或放棄時刪掉那一行。**未提交就離開時一定要留這一行**，否則下一個 agent 會當成孤兒程式碼。
5. 架構、契約、發版流程有變，直接更新本檔對應章節，不另開文件。

## 2. 專案地圖

```
Apps/Pelu/          iOS app（Dashboard / History / Settings / 通知 / Live Activity 管理）
Apps/PeluMac/       macOS menu bar app（UsageMonitor、Claude hook 安裝、Sparkle、登入啟動）
Apps/PeluWidget/    Widget + Live Activity UI
Apps/Shared/        共用 Assets.xcassets（App icon、logo、provider icon）
Sources/PeluCore/   模型、parser、CloudKit、Codex app-server client（無 UI，可 swift test）
Sources/PeluUI/     共用 SwiftUI 元件與 PeluTheme 色票
Sources/PeluMacPrototype/  SwiftPM 可執行 prototype（非出貨）
Tests/PeluCoreTests/
scripts/            release.sh、generate-sparkle-keys.sh、appcast.xml、DMG 背景
assets/             原始 logo / icon 素材（app 實際用的是 xcassets 內的副本）
```

App target 定義在 `Pelu.xcodeproj`（主要 scheme：`Pelu`、`PeluMac`、`PeluWidget`；Widget 嵌入 iOS app），共用程式碼走 `Package.swift`。

## 3. Build & Test

需要完整 Xcode：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --scratch-path "${TMPDIR:-/tmp}/pelu-swiftpm"
xcodebuild -project Pelu.xcodeproj -scheme PeluMac -destination 'generic/platform=macOS' build
xcodebuild -project Pelu.xcodeproj -scheme Pelu    -destination 'generic/platform=iOS'   build
```

repo 在 iCloud Drive，build 產物會被加上 `com.apple.FinderInfo`，codesign 會拒簽測試 bundle，所以 SwiftPM 的 build 目錄要放在 iCloud 外（`--scratch-path`；xcodebuild 用 `-derivedDataPath` 同理）。改了 `PeluCore` / `PeluUI` 至少跑 `swift test` + 受影響 app 的 xcodebuild。Sandbox 內 `codesign --verify` 可能誤報失敗，簽章驗證要在完整系統環境跑。

## 4. 資料流與關鍵規則

- **Claude Code**：主來源 `GET https://api.anthropic.com/api/oauth/usage`（`ClaudeUsageAPIClient` / `ClaudeUsageAPIParser`，Claude Code `/usage` 用的非公開端點），token 讀 Keychain `Claude Code-credentials`，涵蓋終端機、IDE、桌面版、claude.ai 的用量。**不要自己 refresh token**（refresh token 會輪替，可能把 Claude Code 登出）；過期就等 Claude Code 下次執行。端點限流很兇（30–60 秒輪詢會卡 429 數小時，連 Claude Code 的 `/usage` 一起壞），所以 `~/.claude/projects/*/*.jsonl` 有新活動才 5 分鐘一次、沒有則 15 分鐘一次（本地 2–8 點兩者 ×2），失敗退避 5→15→30→60 分鐘；不要調快，也不要偽裝成 claude-code 的 User-Agent。此做法在 Anthropic 條款上屬灰色地帶（文件禁止第三方蒐集／中介 Claude.ai token），改動前先問使用者。資料過期門檻統一用 `UsageMetric.staleAfter`。備援是 statusLine hook（`~/.claude/usag-statusline.py`，寫入 `~/.claude/settings.json`），輸出 `~/.claude/usag-status.json`（檔名就是 `usag`，不是錯字）→ `ClaudeCodeParser`；hook 只在終端機 session 執行，IDE 擴充套件不會觸發。兩者取 `measuredAt` 較新者，context / cost 只有 hook 有。
- **ChatGPT.app**（原 Codex.app，bundle id 仍是 `com.openai.codex`）的 codex 在 `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`。
- **Codex**：主來源 `codex app-server` JSON-RPC `account/rateLimits/read`（`CodexAppServerClient` / `CodexQuotaProvider`，`dataSource = officialQuota`）；備援掃 `~/.codex/sessions/**/*.jsonl`（`localEstimate`）。binary 依序找 ChatGPT.app / Codex.app 內附、NSWorkspace、常見 CLI 路徑。
- **配額視窗長度由 provider 決定**，不要寫死 5h / 7d。`UsageMetric.usedPercent` / `weeklyPercent` 是歷史命名，語意是 primary / secondary window。
- **CloudKit**：record type `MacSnapshot`，record name `mac-{macId}`，container 一律用 `MacSnapshotRecord.containerIdentifier`（**不要用 `CKContainer.default()`**）。上傳要序列化／合併，避免 `Server Record Changed` 衝突。PeluMac 固定走 Production 環境；iOS Debug 走 Development。
- **多 Mac 聚合**（`AggregateSnapshot.displaySnapshot`）：Claude 取最高用量；Codex quota 是帳號層級，取**最新**一筆量測而不是最高值。
- iPhone 端：`CKQuerySubscription` + silent push 觸發更新；App Group `group.org.tobywu.pelu` 給 Widget 讀。

## 5. 不可破壞的契約

```
SUFeedURL         https://pelu.wutoby.com/appcast.xml
SUPublicEDKey     3BXIeW0MQHP3rPFeLEEO5kL4R6z0JGUau2975UX8GoE=
DMG asset name    PeluMac.dmg
CloudKit          iCloud.org.tobywu.pelu（record type MacSnapshot，schema v1）
App Group         group.org.tobywu.pelu
Bundle IDs        org.tobywu.pelu / org.tobywu.pelu.widget / org.tobywu.pelu.mac
```

- 改 feed URL 或 Sparkle 公鑰 → 既有安裝者收不到更新。
- `CFBundleVersion` 每次發版必須遞增（Sparkle 以它判斷新版）。`pbxproj` 裡的 `MARKETING_VERSION = 1.0.0` 是佔位，實際版號由 `release.sh` 帶入。
- CloudKit record 欄位只能**新增**、舊欄位要保持可讀，因為新舊版 Mac / iPhone 會同時存在。
- Sparkle `SU*` key 只能放在 `Apps/PeluMac/Info.plist`（Mac target 保持 `GENERATE_INFOPLIST_FILE = NO`），放 `INFOPLIST_KEY_SU*` 會在開設定時 crash。
- 根目錄 `LICENSE` 只放標準 MIT 本文（含 copyright 行）。附加字型署名會讓 GitHub licensee 判成 NOASSERTION；Source Han Serif TC 的 OFL 署名放 `NOTICE`，條文在 `Apps/Pelu/Resources/Fonts/LICENSE.txt`。

## 6. 發版

**目前線上**：PeluMac `1.0.10`（build 11，2026-05-29），下一版 build ≥ 12；iOS `1.0`（build 2，READY_FOR_SALE），下一版 build ≥ 3（`1.1` build 3 已 archive，待上傳送審）。iOS 走 Xcode Archive → App Store Connect。

iOS 版號用命令列帶入（`MARKETING_VERSION=… CURRENT_PROJECT_VERSION=…`），pbxproj 不動。agent 可以用下面的 API key 加 `-allowProvisioningUpdates` 跑 `xcodebuild archive`，但 **`-exportArchive` 上傳會失敗**：這把 key 沒有 cloud-managed distribution certificate 權限，本機 Keychain 也沒有 Apple Distribution 憑證。做法是把 `.xcarchive` 放進 `~/Library/Developer/Xcode/Archives/<日期>/`，由使用者在 Organizer 按 Distribute App。

App Store Connect 狀態（唯讀：app、版本、最近 build）：

```sh
python3 scripts/appstore-status.py   # 需要 python3 -m pip install cryptography
```

- 設定在 repo 根目錄 `.appstoreconnect.local.json`（`key_id`、`issuer_id`、`bundle_id`、`private_key_path`），私鑰在 `.secrets/AuthKey_*.p8`。兩者已被 gitignore，靠 iCloud Drive 在各台 Mac 間同步；新 Mac 要等 iCloud 下載完檔案。
- `private_key_path` 相對於設定檔所在目錄，不依賴特定使用者帳號路徑。
- agent 可以直接執行腳本，但**絕對不要印出、複製或提交私鑰與設定檔內容**。腳本目前只讀取，要加寫入 API（上傳 metadata、送審等）前先問使用者。

PeluMac：

```sh
./scripts/release.sh <version> <build>      # build、重簽、notarize、staple、DMG、Sparkle 簽章，印出 appcast <item>
gh release create v<version> dist/PeluMac.dmg --repo TobyWu666/pelu-releases --title "Pelu <version>" --notes "..."
# 把 <item> 貼到 scripts/appcast.xml 最上方並 commit，再複製到 TobyWu666/pelu-web 的 appcast.xml 並 push
```

前置：Keychain 有 Developer ID Application 憑證與 Sparkle 私鑰（首次用 `scripts/generate-sparkle-keys.sh` 產生，存於 `https://sparkle-project.org`；務必另有離線備份）、已安裝 Developer ID provisioning profile、`xcrun notarytool store-credentials pelu-notary`、`brew install create-dmg`。

易踩雷（`release.sh` 已處理，改腳本時別弄壞）：

- Sparkle nested binaries（Updater.app、Autoupdate、XPC）要 inside-out 重簽，否則 notarization 拒收。
- 重簽主 app 要 `--preserve-metadata=identifier,entitlements,flags`，不能拿 source entitlements 覆寫，否則 CloudKit / App Group 失效。
- DMG 背景用 multi-rep `scripts/dmg-background.tiff`，對應 750×500 視窗。

發布後驗證：

```sh
curl -fsSL https://pelu.wutoby.com/appcast.xml | head -40
curl -ILs https://github.com/TobyWu666/pelu-releases/releases/latest/download/PeluMac.dmg | head
spctl --assess --type install --verbose=4 dist/PeluMac.dmg
codesign -d --entitlements - build-release/Build/Products/Release/PeluMac.app   # 要看到 application-identifier 與 team-identifier
```

手動 QA：從 DMG 開啟應提示移到 `/Applications`；登入時啟動實測；重置 onboarding 走完會自動關窗；裝上一版用「立即檢查更新」走完整 Sparkle 升級；Codex 有活動時 menu bar 顯示 official quota 且 log 無連續 CloudKit conflict。

## 7. 設計原則

色票與字體 token 以 `Sources/PeluUI/PeluTheme.swift` 為準（主色 Pelu Teal `#12B8A6`；狀態色 Lime / Amber / Coral；iOS Dashboard 問候語標題用內嵌的 Source Han Serif TC Bold，其餘用系統字體）。語氣是「桌邊的小儀表」：安靜、清楚、Apple 原生工具感；數字是主角，一張卡片一個主要數字；顏色只在進度與狀態出現；避免童趣、紫藍漸層、厚陰影、霓虹深色。Widget / Live Activity 比主 App 更克制。

## 8. 進行中

格式：`- [agent] 範圍 — 涉及檔案 — 開始日期`

（目前無）
