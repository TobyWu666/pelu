# Pelu Cloudflare Worker

Pelu 雲端通道 + APNs 推送後端。

- Domain: `pelu.tobywu.org`
- Auth: shared secret in `Authorization: Bearer <secret>`
- Storage: Cloudflare KV binding `PELU_USAGE_KV`（id: `2115c5d710e146189c8ce52e26669212`）
- Endpoints:
  - `GET /health`
  - `GET /usage` — iPhone 拉最新 snapshot
  - `POST /usage` — Mac 上傳 snapshot；同時偵測狀態轉換，推送通知到訂閱的裝置
  - `POST /device` — iPhone 註冊 / 更新 APNs token 與通知偏好
  - `DELETE /device?token=<hex>` — 解除註冊

## Secrets

所有 secret 透過 `wrangler secret put` 上傳，不進 repo。

| Secret | 說明 |
|---|---|
| `PELU_SHARED_SECRET` | Mac / iOS 共用的 bearer secret |
| `APNS_AUTH_KEY` | Apple Developer 後台下載的 `.p8` 完整內容（含 BEGIN/END 行） |
| `APNS_KEY_ID` | `.p8` 的 Key ID（10 字元） |
| `APNS_TEAM_ID` | Apple Developer Team ID（10 字元） |
| `APNS_BUNDLE_ID` | App bundle id，預設 `org.tobywu.pelu` |
| `APNS_ENVIRONMENT` | `development`（sandbox APNs）或 `production`（正式 APNs）|

設定範例：

```sh
wrangler secret put APNS_AUTH_KEY < /path/to/AuthKey_XXXXXXXXXX.p8
printf 'XXXXXXXXXX' | wrangler secret put APNS_KEY_ID
printf 'YYYYYYYYYY' | wrangler secret put APNS_TEAM_ID
printf 'org.tobywu.pelu' | wrangler secret put APNS_BUNDLE_ID
printf 'development' | wrangler secret put APNS_ENVIRONMENT
```

正式上 TestFlight / App Store 時，記得把 `APNS_ENVIRONMENT` 改成 `production`，並同步把 iOS `Pelu.entitlements` 的 `aps-environment` 從 `development` 改成 `production`。

## 狀態轉換偵測

每次 `POST /usage` 進來時，Worker 會比對 KV 既有 snapshot 跟新 snapshot：

- `usedPercent ≤ 90 → > 90`：發「低額度警告」
- `usedPercent > 50 → < 20`：判定為重置事件，發「重置提醒」

對每個訂閱該偏好的裝置（依 KV `device:*` 紀錄）發送 APNs alert push。
APNs 回 410 / `BadDeviceToken` / `Unregistered` 時，自動刪除該裝置記錄。

## KV namespace

如需重建：

```sh
wrangler kv namespace create PELU_USAGE_KV
```

binding 名稱要維持 `PELU_USAGE_KV` 否則要同步改 `src/index.ts`。

## 部署

```sh
wrangler deploy
```
