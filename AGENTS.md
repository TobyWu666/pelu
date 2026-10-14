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

Codex JSONL 記憶體回歸用 `python3 scripts/test-memory-regression.py`；加 `--baseline-ref d31f831` 可跑原版（原版超過預設 256 MiB 上限、預期 exit 1），加 `--megabytes 128 --iterations 60` 可跑較大壓力測試。只產生暫存合成資料，不讀使用者對話；macOS `/usr/bin/time -l` 的峰值是 reader probe，不是整個 App。

repo 在 iCloud Drive，build 產物會被加上 `com.apple.FinderInfo`，codesign 會拒簽測試 bundle，所以 SwiftPM 的 build 目錄要放在 iCloud 外（`--scratch-path`；xcodebuild 用 `-derivedDataPath` 同理）。改了 `PeluCore` / `PeluUI` 至少跑 `swift test` + 受影響 app 的 xcodebuild。Sandbox 內 `codesign --verify` 可能誤報失敗，簽章驗證要在完整系統環境跑。

## 4. 資料流與關鍵規則

- **Claude Code**：主來源 `GET https://api.anthropic.com/api/oauth/usage`（`ClaudeUsageAPIClient` / `ClaudeUsageAPIParser`，Claude Code `/usage` 用的非公開端點），token 讀 Keychain `Claude Code-credentials`，涵蓋終端機、IDE、桌面版、claude.ai 的用量。讀取一律透過 `/usr/bin/security find-generic-password -w`，**不要改回 `SecItemCopyMatching`**：Claude Code（含 Claude app 內嵌的那份）每開一個 session 就用 `security` 重寫這個項目好幾次，每次都讓 Pelu 自己的授權失效、要求重新輸入登入密碼，`security` 則一直留在項目的 ACL 裡。只查屬性（`mdat`）不會跳提示，所以先比對修改時間，有變才重新讀 token；使用者拒絕 `security` 的提示時隔 1 小時再試。**不要自己 refresh token**（refresh token 會輪替，可能把 Claude Code 登出）；過期就等 Claude Code 下次執行。端點限流很兇（30–60 秒輪詢會卡 429 數小時，連 Claude Code 的 `/usage` 一起壞），所以 `~/.claude/projects/*/*.jsonl` 有新活動才 5 分鐘一次、沒有則 15 分鐘一次（本地 2–8 點兩者 ×2），失敗退避 5→15→30→60 分鐘；不要調快，也不要偽裝成 claude-code 的 User-Agent。此做法在 Anthropic 條款上屬灰色地帶（文件禁止第三方蒐集／中介 Claude.ai token），改動前先問使用者。資料過期門檻統一用 `UsageMetric.staleAfter`。備援是 statusLine hook（`~/.claude/usag-statusline.py`，寫入 `~/.claude/settings.json`），輸出 `~/.claude/usag-status.json`（檔名就是 `usag`，不是錯字）→ `ClaudeCodeParser`；hook 只在終端機 session 執行，IDE 擴充套件不會觸發。兩者取 `measuredAt` 較新者，context / cost 只有 hook 有。這個 token 只有 Claude Code 會 refresh（約 8 小時過期），只用 Claude app 時會過期；`ClaudeUsageAPIClient.credentialState == .expired` 且資料過期時，metric 帶 note 提示到終端機執行一次 `claude`（Mac 面板在資料過期時也會顯示 note）。第三個來源是 Claude app 自己寫的 `~/Library/Application Support/Claude/plan-usage-history.json`（`ClaudeDesktopUsageParser`，`fh` / `sd` = 5 小時 / 7 天 %），只在比 API / hook 新時採用；它幾乎只在 Claude app 啟動時寫入、沒有重置時間，所以超過視窗長度的取樣直接丟掉，不歸零。Claude app 的登入（`config.json` 的 `oauth:tokenCache*`，用 Keychain `Claude Safe Storage` 加密）不要去解。
- **ChatGPT.app**（原 Codex.app，bundle id 仍是 `com.openai.codex`）的 codex 在 `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`。
- **Codex**：主來源 `codex app-server` JSON-RPC `account/rateLimits/read`（`CodexAppServerClient` / `CodexQuotaProvider`，`dataSource = officialQuota`）；備援掃 `~/.codex/sessions/**/*.jsonl`（`localEstimate`）。binary 依序找 ChatGPT.app / Codex.app 內附、NSWorkspace、常見 CLI 路徑。
- **Codex JSONL 資源上限**：`PeluCore/CodexJSONLReader` 一次掃描產生 quota / token / watcher snapshot。64 KiB 分塊、單行最多 1 MiB，跳過超長或無效紀錄；只有 `token_count` 才解 JSON，每次 JSON 解碼有 autorelease pool。快取最多 1,024 份檔案的最新數值、讀取位置、檔案身分與邊界 checksum，不保留對話內容；未變檔案不重讀，append 只解析尾端（額外最多 4 KiB 檢查舊檔案邊界），截短／同大小覆寫／inode 替換會重掃。缺 timestamp 的檔案修改後重掃以維持 mtime 備援語意；未完成末行只保留 offset，完成後重讀。只監看最近修改的 128 份檔案，其餘仍由 60 秒輪詢計入，**不可因 watcher 或 cache 上限截斷 token 加總**。`CoalescingRefreshScheduler` 保持一個執行中／一個待處理刷新，開始間隔至少 1 秒；provider 的既有 API 輪詢與認證契約照舊。
- **Cursor**：`GET https://cursor.com/api/usage-summary`（cursor.com/dashboard 前端用的非公開端點，`CursorUsageClient` / `CursorUsageParser`），用 Cursor app 存在 `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`（SQLite `ItemTable`，key `cursorAuth/accessToken`）的 session JWT，組成 cookie `WorkosCursorSessionToken=<sub 去掉 "provider|" 前綴>::<jwt>`（URL-encode）。Bearer header 會 401。**不要 refresh / 寫回 token**。Cursor 正在寫 state 時 5 分鐘、否則 15 分鐘（同樣有凌晨 ×2），失敗退避 5→15→30→60 分鐘。用量是一個帳單週期內的兩個額度：primary = `apiPercentUsed`（指定模型 / API），secondary = `autoPercentUsed`（Auto + Composer），兩者 reset 都是 `billingCycleEnd`，status 取兩者較高。UI 文字用 `UsageMetric.windowTitle(secondary:)`（Cursor 顯示 API / Auto，其他顯示視窗長度）。沒裝 Cursor 就不產生 metric；尚未量到的 placeholder 不上傳 CloudKit。灰色地帶程度同 Claude，改動前先問使用者。
- **Grok Bot**（xAI 與 Cursor 合作的 Electron app，bundle id `com.anysphere.sand`，用 Cursor 帳號登入）：`POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus`（Connect JSON，body `{}`，`GrokBotUsageClient` / `GrokBotUsageParser`），用上面同一個 Cursor IDE token 帶 `Authorization: Bearer`。Grok Bot 自己的 token 在 `~/Library/Application Support/Grok Bot/sand-secrets.json`，用 Electron safeStorage（Keychain）加密，**不要去解**，所以這台 Mac 沒登入 Cursor IDE 就讀不到。單一每週額度：`usagePercent` → primary，視窗 = `nextResetTimestampUtc − currentPeriodStart`，沒有 secondary（`ProviderKind.hasSecondaryWindow == false`）。`usesPooledEnterpriseAllowance` 沒有個人百分比，不顯示數字。只有 `usagePercent > 0`，或裝了 Grok Bot 且 `hasNonZeroIncludedLimit` 時才產生 metric（`GrokBotUsageStatus.isWorthShowing`）。輪詢：Grok Bot 正在寫 support 資料夾時 5 分鐘、否則 15 分鐘，沒裝 app 時 60 分鐘（同樣有凌晨 ×2），失敗退避 5→15→30→60 分鐘。走 `extraMetrics`，不需要改 CloudKit schema。灰色地帶程度同 Cursor。
- **配額視窗長度由 provider 決定**，不要寫死 5h / 7d。`UsageMetric.usedPercent` / `weeklyPercent` 是歷史命名，語意是 primary / secondary window。
- **CloudKit**：record type `MacSnapshot`，record name `mac-{macId}`，container 一律用 `MacSnapshotRecord.containerIdentifier`（**不要用 `CKContainer.default()`**）。上傳要序列化／合併，避免 `Server Record Changed` 衝突。PeluMac 固定走 Production 環境；iOS Debug 走 Development。
- **`payload` 只放 Claude / Codex**（`ProviderKind.fitsLegacyPayload`）：iOS ≤ 1.1 把 `payload` 當嚴格的 `[UsageMetric]` 解碼，多一個未知 provider 就整台 Mac 消失。其他 provider（目前是 Cursor）放 `extraMetrics`（Bytes，同格式 JSON）。新版 reader 對兩個欄位都逐筆容錯（`LossyMetrics`）。Production schema 沒有 `extraMetrics` 時存檔會被拒，`CloudKitSyncer` 會改成不帶 extras 重送並暫停一小時。**新增欄位要先在 CloudKit Console 的 Development 加好並 Deploy Schema Changes 到 Production**，再發 PeluMac。
- **多 Mac 聚合**（`AggregateSnapshot.displaySnapshot`）：Claude 取最高用量；Codex / Cursor / Grok Bot quota 是帳號層級，取**最新**一筆量測而不是最高值；沒有數字的 placeholder（例如「今日無 Codex 使用紀錄」，沒有 `measuredAt`）只在所有 Mac 都沒有數字時才顯示，否則它會靠較新的 `generatedAt` 蓋掉別台 Mac 的真實讀數。PeluMac 也不上傳沒有 `measuredAt` 的 Codex / Cursor metric（iOS 1.1 沒有這層過濾）。
- **Mac 面板**：顯示多個服務時，上方一排 tile（各自 primary % + secondary 小字），點選的服務在下方顯示完整雙環／橫條卡片（`pelu.mac.selectedProvider`）；`pelu.mac.panelProviders` 是逗號分隔的 provider rawValue，仍相容舊值 `all` / `claude` / `codex`；Grok Bot 出現前存下的清單會在啟動時一次性補上 `grok_bot`（`pelu.mac.panelProviders.grokBotAdded`）。選單列 `pelu.menubar.style` 為 `text`（預設，`C 37%`）或 `rings`（`MenuBarRings` 畫成單張非 template NSImage：外圈 primary 用量、內圈 primary 視窗已過時間、中間 `ProviderKind.menuBarLetter`，Claude C / Codex X / Cursor U / Grok Bot G）。兩種模式都不放 logo，沒有任何內容可顯示時才退回 logo（否則選單列項目會消失點不到）。PeluMac 是 `LSUIElement`（不出現在 Dock / ⌘Tab），開視窗後要 `NSApp.activate()` 才拿得到鍵盤焦點。iOS Dashboard 卡片有 `bars`（預設，主數字 + 進度條刻度）/ `rings`（主次兩個雙環）兩種，設定頁「顯示」切換，key `pelu.ios.cardStyle`（`UsageCardStyle`）。iOS 中型 widget 只放前兩個 provider，Live Activity 只有 Claude / Codex。
- iPhone 端：`CKQuerySubscription` + silent push 觸發更新；App Group `group.org.tobywu.pelu` 給 Widget 讀。

## 5. 不可破壞的契約

```
SUFeedURL         https://pelu.wutoby.com/appcast.xml
SUPublicEDKey     pBmFC7cROkIY05Xzcu6tAQipN2iUzz2HUdlhN3rf5qg=   （1.0.11 起；≤1.0.10 是 3BXIeW0MQHP3rPFeLEEO5kL4R6z0JGUau2975UX8GoE=，私鑰已遺失）
DMG asset name    PeluMac.dmg
CloudKit          iCloud.org.tobywu.pelu（record type MacSnapshot，schema v1；欄位 macId / label / schemaVersion / bundleVersion / generatedAt / payload / extraMetrics）
App Group         group.org.tobywu.pelu
Bundle IDs        org.tobywu.pelu / org.tobywu.pelu.widget / org.tobywu.pelu.mac
```

- 改 feed URL → 既有安裝者收不到更新。Sparkle 公鑰只能靠 key rotation 更換：新版必須用同一張 Developer ID 簽、`SUVerifyUpdateBeforeExtraction` 保持關閉，而且 EdDSA 金鑰和 Developer ID 憑證不能在同一版一起換。1.0.11 就是這樣換的。
- `CFBundleVersion` 每次發版必須遞增（Sparkle 以它判斷新版）。`pbxproj` 裡的 `MARKETING_VERSION = 1.0.0` 是佔位，實際版號由 `release.sh` 帶入。
- CloudKit record 欄位只能**新增**、舊欄位要保持可讀，因為新舊版 Mac / iPhone 會同時存在。
- Sparkle `SU*` key 只能放在 `Apps/PeluMac/Info.plist`（Mac target 保持 `GENERATE_INFOPLIST_FILE = NO`），放 `INFOPLIST_KEY_SU*` 會在開設定時 crash。
- 根目錄 `LICENSE` 只放標準 MIT 本文（含 copyright 行）。附加字型署名會讓 GitHub licensee 判成 NOASSERTION；Source Han Serif TC 的 OFL 署名放 `NOTICE`，條文在 `Apps/Pelu/Resources/Fonts/LICENSE.txt`。

## 6. 發版

**目前線上**：PeluMac `1.0.13`（build 14，2026-10-12，Grok Bot 用量、Claude token 改用 `security` 讀取），下一版 build ≥ 15；iOS `1.2`（build 4，READY_FOR_SALE），下一版 build ≥ 5。iOS 走 Xcode Archive → App Store Connect。

iOS 版號用命令列帶入（`MARKETING_VERSION=… CURRENT_PROJECT_VERSION=…`），pbxproj 不動。`xcodebuild archive` / `-exportArchive`（ExportOptions `method=app-store-connect`、`destination=upload`）都加 `-allowProvisioningUpdates`，但**不要帶 `-authenticationKey*`**：那把 API key 沒有 cloud-managed distribution certificate 權限，會匯出失敗；不帶就改用 Xcode 裡登入的帳號雲端簽章，可以直接上傳。build、archive 路徑放在 iCloud 外。

App Store Connect 狀態（唯讀：app、版本、最近 build）與送審：

```sh
python3 scripts/appstore-status.py   # 需要 python3 -m pip install cryptography
python3 scripts/appstore-submit.py <version> <build> --notes-file <whats-new.txt>            # 建立版本（核准後自動發布）、寫入各語系「此版本新功能」、選 build
python3 scripts/appstore-submit.py <version> <build> --notes-file <whats-new.txt> --submit   # 同上並送審
```

build 上傳且處理成 `VALID` 後再跑 submit。共用的 JWT / API client 在 `scripts/appstoreconnect.py`。

- 設定在 repo 根目錄 `.appstoreconnect.local.json`（`key_id`、`issuer_id`、`bundle_id`、`private_key_path`），私鑰在 `.secrets/AuthKey_*.p8`。兩者已被 gitignore，靠 iCloud Drive 在各台 Mac 間同步；新 Mac 要等 iCloud 下載完檔案。
- `private_key_path` 相對於設定檔所在目錄，不依賴特定使用者帳號路徑。
- agent 可以直接執行腳本，但**絕對不要印出、複製或提交私鑰與設定檔內容**。`appstore-status.py` 只讀；`appstore-submit.py` 會寫入，帶 `--submit` 送審前要先得到使用者同意。要再加其他寫入 API（截圖、描述、價格等）前先問使用者。

PeluMac：

```sh
./scripts/release.sh <version> <build>      # build、重簽、notarize、staple、DMG、Sparkle 簽章，印出 appcast <item>
gh release create v<version> dist/PeluMac.dmg --repo TobyWu666/pelu-releases --title "Pelu <version>" --notes "..."
# 把 <item> 貼到 scripts/appcast.xml 最上方並 commit，再複製到 TobyWu666/pelu-web 的 appcast.xml 並 push
# （不必 clone：兩邊內容相同時可用 gh api -X PUT repos/TobyWu666/pelu-web/contents/appcast.xml 帶 sha 直接覆蓋）
```

前置：Keychain 有 Developer ID Application 憑證與 Sparkle 私鑰（首次用 `scripts/generate-sparkle-keys.sh` 產生，Keychain service `https://sparkle-project.org`；備份在 `.secrets/sparkle-ed25519-private-key.txt`，新 Mac 用 `generate_keys -f` 匯入，另有離線備份）、已安裝 Developer ID provisioning profile（`Pelu Mac Developer ID`，必須包含這台 Mac Keychain 裡那張 Developer ID 憑證，換 Mac 時在 developer.apple.com 編輯 profile 勾選憑證並重新下載）、`xcrun notarytool store-credentials pelu-notary`、`brew install create-dmg`。

易踩雷（`release.sh` 已處理，改腳本時別弄壞）：

- Sparkle nested binaries（Updater.app、Autoupdate、XPC）要 inside-out 重簽，否則 notarization 拒收。
- 重簽主 app 要 `--preserve-metadata=identifier,entitlements,flags`，不能拿 source entitlements 覆寫，否則 CloudKit / App Group 失效。
- DMG 背景用 multi-rep `scripts/dmg-background.tiff`，對應 750×500 視窗。
- macOS 會清掉 `$TMPDIR` 裡放久的檔案：build 報 `Sparkle.xcframework` 找不到時，刪掉 `$TMPDIR/pelu-build-release/SourcePackages` 重跑。notarytool `connectTimeout` 多半是網路暫時不穩，重跑即可。

發布後驗證：

```sh
curl -fsSL https://pelu.wutoby.com/appcast.xml | head -40
curl -ILs https://github.com/TobyWu666/pelu-releases/releases/latest/download/PeluMac.dmg | head
spctl --assess --type install --verbose=4 dist/PeluMac.dmg
codesign -d --entitlements - "${TMPDIR:-/tmp}/pelu-build-release/Build/Products/Release/PeluMac.app"   # 要看到 application-identifier 與 team-identifier
```

手動 QA：從 DMG 開啟應提示移到 `/Applications`；登入時啟動實測；重置 onboarding 走完會自動關窗；裝上一版用「立即檢查更新」走完整 Sparkle 升級；Codex 有活動時 menu bar 顯示 official quota 且 log 無連續 CloudKit conflict。

## 7. 設計原則

色票與字體 token 以 `Sources/PeluUI/PeluTheme.swift` 為準（主色 Pelu Teal `#12B8A6`；狀態色 Lime / Amber / Coral；iOS Dashboard 問候語標題用內嵌的 Source Han Serif TC Bold，其餘用系統字體）。語氣是「桌邊的小儀表」：安靜、清楚、Apple 原生工具感；數字是主角，一張卡片一個主要數字；顏色只在進度與狀態出現；避免童趣、紫藍漸層、厚陰影、霓虹深色。Widget / Live Activity 比主 App 更克制。

## 8. 進行中

格式：`- [agent] 範圍 — 涉及檔案 — 開始日期`

（目前無）
