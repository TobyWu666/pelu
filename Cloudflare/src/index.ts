import {
  invalidateJWTCache,
  sendAPNsAlert,
  sendAPNsBackgroundRefresh,
  type APNsConfig,
  type APNsResult,
} from "./apns";
import { detectTransitions, notificationText, type Transition } from "./transitions";

export interface Env {
  PELU_USAGE_KV: KVNamespace;
  PELU_SHARED_SECRET: string;
  APNS_AUTH_KEY?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_BUNDLE_ID?: string;
  APNS_ENVIRONMENT?: string; // "development" | "production"
}

const USAGE_PREFIX = "usage:";        // usage:{macId} → stored snapshot per Mac
const LEGACY_USAGE_KEY = "latest";    // pre-multi-Mac single-slot key (read-only during migration)
const DEVICE_PREFIX = "device:";
const PAIR_CODE_PREFIX = "pair_code:";   // short-lived 6-digit handshake
const PAIR_TOKEN_PREFIX = "pair_token:"; // long-lived per-device API token

const PAIR_CODE_TTL_SECONDS = 5 * 60;

interface DeviceRecord {
  token: string;
  lowQuota: boolean;
  reset: boolean;
  bundleId: string;
  updatedAt: string;
}

interface PairCodeRecord {
  pairToken: string;
  expiresAt: number;
}

interface PairTokenRecord {
  createdAt: string;
  label?: string;
}

type AuthLevel = "admin" | "device" | null;

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return response(null, 204);
    }

    if (url.pathname === "/health" && request.method === "GET") {
      return response("ok\n", 200, "text/plain; charset=utf-8");
    }

    // /pair/claim is the only authenticated-by-code endpoint; it has its own check.
    if (url.pathname === "/pair/claim" && request.method === "POST") {
      return handlePairClaim(request, env);
    }

    const auth = await resolveAuthLevel(request, env);
    if (!auth) return response({ error: "unauthorized" }, 401);

    if (url.pathname === "/usage") {
      if (request.method === "GET")  return handleUsageGet(env);
      // /usage POST is Mac-only — require admin so a leaked iPhone pair token
      // can't be used to spoof readings.
      if (request.method === "POST") {
        if (auth !== "admin") return response({ error: "forbidden" }, 403);
        return handleUsagePost(request, env, ctx);
      }
      return methodNotAllowed("GET, POST, OPTIONS");
    }

    if (url.pathname === "/device") {
      if (request.method === "POST")   return handleDevicePost(request, env);
      if (request.method === "DELETE") return handleDeviceDelete(request, env);
      return methodNotAllowed("POST, DELETE, OPTIONS");
    }

    if (url.pathname === "/pair/create" && request.method === "POST") {
      // Only Mac (admin) can mint a pairing code.
      if (auth !== "admin") return response({ error: "forbidden" }, 403);
      return handlePairCreate(request, env);
    }

    return response({ error: "not_found" }, 404);
  },
};

// ---- /usage ----

interface UsageSnapshotPayload {
  generatedAt: string;
  metrics: { provider: string; usedPercent: number | null }[];
}

interface MacUploadEnvelope {
  macId: string;
  label: string;
  generatedAt: string;
  metrics: { provider: string; usedPercent: number | null }[];
}

interface MacRecord {
  macId: string;
  label: string;
  snapshot: UsageSnapshotPayload & { source: string };
}

/// Build the aggregate response: list every `usage:{macId}` slot, sort by label,
/// return `{ macs: [{ macId, label, snapshot }] }`. Falls back to legacy `latest`
/// when no per-Mac records exist (helps a freshly redeployed Worker show old data).
async function handleUsageGet(env: Env): Promise<Response> {
  const macs: MacRecord[] = [];

  let cursor: string | undefined;
  do {
    const list = await env.PELU_USAGE_KV.list({ prefix: USAGE_PREFIX, cursor });
    for (const key of list.keys) {
      const raw = await env.PELU_USAGE_KV.get(key.name);
      if (!raw) continue;
      try {
        const parsed = JSON.parse(raw) as MacRecord;
        if (parsed.macId && parsed.snapshot) macs.push(parsed);
      } catch {
        // skip malformed
      }
    }
    cursor = list.list_complete ? undefined : list.cursor;
  } while (cursor);

  if (macs.length === 0) {
    const legacy = await env.PELU_USAGE_KV.get(LEGACY_USAGE_KEY);
    if (!legacy) return response({ error: "usage_not_found" }, 404);
    return response(legacy, 200, "application/json; charset=utf-8");
  }

  macs.sort((a, b) => a.label.localeCompare(b.label));
  return response({ macs }, 200);
}

async function handleUsagePost(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
): Promise<Response> {
  const body = await request.text();
  const envelope = parseEnvelope(body);
  if (!envelope) return response({ error: "invalid_envelope" }, 400);

  const macKey = USAGE_PREFIX + envelope.macId;
  const previousText = await env.PELU_USAGE_KV.get(macKey);
  const previous = previousText ? parseMacRecord(previousText) : null;

  // Monotonic check is per-Mac: two Macs racing each other won't trigger this
  // because they write to different keys. A single Mac sending out-of-order
  // retries still gets reject-newer-wins.
  if (previous && Date.parse(envelope.generatedAt) <= Date.parse(previous.snapshot.generatedAt)) {
    return response({ status: "stale_ignored" }, 200);
  }

  const record: MacRecord = {
    macId: envelope.macId,
    label: envelope.label,
    snapshot: {
      generatedAt: envelope.generatedAt,
      source: "cloud",
      metrics: envelope.metrics,
    },
  };

  await env.PELU_USAGE_KV.put(macKey, JSON.stringify(record));

  ctx.waitUntil(dispatchPushes(previous, record, env));

  return response(null, 204);
}

async function dispatchPushes(
  previous: MacRecord | null,
  next: MacRecord,
  env: Env,
): Promise<void> {
  const isFirstUpload = previous === null;
  // Transitions are scoped to one Mac (we only compare against same macId's prev).
  const transitions = previous ? detectTransitions(previous.snapshot, next.snapshot) : [];
  // Push silent wake-up only when metrics actually changed — generatedAt changes
  // every minute even when nothing meaningful happened (Mac uploads on Timer tick
  // to keep the displayed timestamp fresh), and we don't want to burn APNs quota
  // on no-op timestamp updates.
  const metricsChanged = !previous || !metricsEqual(previous.snapshot.metrics, next.snapshot.metrics);
  const wantBackground = isFirstUpload || metricsChanged;

  if (!wantBackground && transitions.length === 0) return;

  const apnsConfig = resolveAPNsConfig(env);
  if (!apnsConfig) return;

  const devices = await listDevices(env);
  if (devices.length === 0) return;

  await Promise.allSettled(
    devices.map((device) => pushToDevice(device, transitions, wantBackground, apnsConfig, env)),
  );
}

async function pushToDevice(
  device: DeviceRecord,
  transitions: Transition[],
  wantBackground: boolean,
  apnsConfig: APNsConfig,
  env: Env,
): Promise<void> {
  const results: APNsResult[] = [];

  if (wantBackground) {
    results.push(await sendAPNsBackgroundRefresh(device.token, apnsConfig));
  }
  for (const transition of transitions) {
    if (!isDeviceSubscribedTo(device, transition)) continue;
    const message = notificationText(transition);
    results.push(await sendAPNsAlert(device.token, message.title, message.body, apnsConfig));
  }

  // 403 ExpiredProviderToken means our JWT expired — drop the cached JWT so the
  // next push re-signs. Do NOT delete the device record for this case.
  if (results.some((r) => r.status === 403 && r.reason === "ExpiredProviderToken")) {
    invalidateJWTCache();
  }

  if (results.some(shouldDropDevice)) {
    invalidateDevicesCache();
    await env.PELU_USAGE_KV.delete(DEVICE_PREFIX + device.token);
  }
}

/// Only the failure modes that *permanently* mean this device token is no good.
/// Everything else (5xx, 429, transient network errors, ExpiredProviderToken)
/// must NOT cause us to drop the device.
function shouldDropDevice(result: APNsResult): boolean {
  if (result.status === 410 && result.reason === "Unregistered") return true;
  if (result.reason === "BadDeviceToken") return true;
  if (result.reason === "DeviceTokenNotForTopic") return true;
  return false;
}

function metricsEqual(
  a: UsageSnapshotPayload["metrics"],
  b: UsageSnapshotPayload["metrics"],
): boolean {
  if (a.length !== b.length) return false;
  const sortKey = (m: { provider: string }) => m.provider;
  const sortedA = [...a].sort((x, y) => sortKey(x).localeCompare(sortKey(y)));
  const sortedB = [...b].sort((x, y) => sortKey(x).localeCompare(sortKey(y)));
  for (let i = 0; i < sortedA.length; i++) {
    if (sortedA[i].provider !== sortedB[i].provider) return false;
    if (sortedA[i].usedPercent !== sortedB[i].usedPercent) return false;
  }
  return true;
}

function parseEnvelope(text: string): MacUploadEnvelope | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }
  if (!isRecord(parsed)) return null;
  if (typeof parsed.macId !== "string" || parsed.macId.trim().length === 0) return null;
  if (typeof parsed.label !== "string" || parsed.label.trim().length === 0) return null;
  if (typeof parsed.generatedAt !== "string") return null;
  if (!Array.isArray(parsed.metrics)) return null;
  return {
    macId: parsed.macId.trim(),
    label: parsed.label.trim(),
    generatedAt: parsed.generatedAt,
    metrics: parsed.metrics as MacUploadEnvelope["metrics"],
  };
}

function parseMacRecord(text: string): MacRecord | null {
  try {
    const parsed = JSON.parse(text);
    if (!isRecord(parsed)) return null;
    if (typeof parsed.macId !== "string") return null;
    if (typeof parsed.label !== "string") return null;
    if (!isRecord(parsed.snapshot)) return null;
    return parsed as MacRecord;
  } catch {
    return null;
  }
}

function isDeviceSubscribedTo(device: DeviceRecord, transition: Transition): boolean {
  if (transition.kind === "lowQuota") return device.lowQuota;
  if (transition.kind === "reset")    return device.reset;
  return false;
}

// ---- /device ----

async function handleDevicePost(request: Request, env: Env): Promise<Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return response({ error: "invalid_json" }, 400);
  }
  if (!isRecord(body)) return response({ error: "invalid_payload" }, 400);

  const token = typeof body.deviceToken === "string" ? body.deviceToken.trim() : "";
  if (!token) return response({ error: "missing_device_token" }, 400);

  const record: DeviceRecord = {
    token,
    lowQuota: body.lowQuota === true,
    reset: body.reset === true,
    bundleId: typeof body.bundleId === "string" ? body.bundleId : "org.tobywu.pelu",
    updatedAt: new Date().toISOString(),
  };

  await env.PELU_USAGE_KV.put(DEVICE_PREFIX + token, JSON.stringify(record));
  invalidateDevicesCache();
  return response({ ok: true }, 200);
}

async function handleDeviceDelete(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const token = url.searchParams.get("token");
  if (!token) return response({ error: "missing_token" }, 400);
  await env.PELU_USAGE_KV.delete(DEVICE_PREFIX + token);
  invalidateDevicesCache();
  return response(null, 204);
}

// Cache the device list per isolate to avoid (N+1) KV reads on every POST /usage.
// 10 seconds is fine: device records only change on app launch / token rotation,
// and explicit invalidations cover both ends.
interface DevicesCache {
  value: DeviceRecord[];
  expiresAt: number;
}
const DEVICES_CACHE_TTL_MS = 10_000;
let devicesCache: DevicesCache | null = null;

function invalidateDevicesCache(): void {
  devicesCache = null;
}

async function listDevices(env: Env): Promise<DeviceRecord[]> {
  const now = Date.now();
  if (devicesCache && devicesCache.expiresAt > now) {
    return devicesCache.value;
  }

  const result: DeviceRecord[] = [];
  let cursor: string | undefined;
  do {
    const list = await env.PELU_USAGE_KV.list({ prefix: DEVICE_PREFIX, cursor });
    for (const key of list.keys) {
      const raw = await env.PELU_USAGE_KV.get(key.name);
      if (!raw) continue;
      try {
        const parsed = JSON.parse(raw) as DeviceRecord;
        if (parsed.token) result.push(parsed);
      } catch {
        // skip malformed
      }
    }
    cursor = list.list_complete ? undefined : list.cursor;
  } while (cursor);

  devicesCache = { value: result, expiresAt: now + DEVICES_CACHE_TTL_MS };
  return result;
}

// ---- helpers ----

function resolveAPNsConfig(env: Env): APNsConfig | null {
  if (!env.APNS_AUTH_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return null;
  const environment = env.APNS_ENVIRONMENT === "production" ? "production" : "development";
  return {
    authKey: env.APNS_AUTH_KEY,
    keyId: env.APNS_KEY_ID,
    teamId: env.APNS_TEAM_ID,
    bundleId: env.APNS_BUNDLE_ID ?? "org.tobywu.pelu",
    environment,
  };
}

/// Resolve the bearer token to an auth level. "admin" = Mac with shared secret.
/// "device" = iPhone with a pair token issued via /pair/claim. null = unauthorized.
async function resolveAuthLevel(request: Request, env: Env): Promise<AuthLevel> {
  const header = request.headers.get("Authorization") ?? "";
  if (!header.startsWith("Bearer ")) return null;
  const presented = header.slice("Bearer ".length).trim();
  if (!presented) return null;

  const adminSecret = env.PELU_SHARED_SECRET?.trim();
  if (adminSecret && presented === adminSecret) return "admin";

  // Look up as device pair token. KV.get caches at the edge; tolerable per-request.
  const stored = await env.PELU_USAGE_KV.get(PAIR_TOKEN_PREFIX + presented);
  if (stored) return "device";

  return null;
}

// ---- /pair ----

async function handlePairCreate(request: Request, env: Env): Promise<Response> {
  let body: unknown = {};
  try {
    body = await request.json();
  } catch {
    // No body is fine — label is optional.
  }
  const label = isRecord(body) && typeof body.label === "string" ? body.label : undefined;

  const code = generateNumericCode(6);
  const pairToken = generatePairToken();
  const expiresAt = Date.now() + PAIR_CODE_TTL_SECONDS * 1000;

  const codeRecord: PairCodeRecord = { pairToken, expiresAt };
  await env.PELU_USAGE_KV.put(PAIR_CODE_PREFIX + code, JSON.stringify(codeRecord), {
    expirationTtl: PAIR_CODE_TTL_SECONDS,
  });

  // The token isn't stored yet — only on claim. This prevents an attacker who
  // grabs a leaked pairing code from also having a pre-minted valid token if
  // the rightful user hasn't claimed yet.
  const tokenRecord: PairTokenRecord = { createdAt: new Date().toISOString(), label };
  await env.PELU_USAGE_KV.put(PAIR_TOKEN_PREFIX + pairToken + ".pending", JSON.stringify(tokenRecord), {
    expirationTtl: PAIR_CODE_TTL_SECONDS,
  });

  return response({ code, expiresAt }, 200);
}

async function handlePairClaim(request: Request, env: Env): Promise<Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return response({ error: "invalid_json" }, 400);
  }
  if (!isRecord(body)) return response({ error: "invalid_payload" }, 400);

  const code = typeof body.code === "string" ? body.code.trim() : "";
  if (!/^\d{6}$/.test(code)) return response({ error: "invalid_code" }, 400);

  const raw = await env.PELU_USAGE_KV.get(PAIR_CODE_PREFIX + code);
  if (!raw) return response({ error: "code_not_found" }, 404);

  let record: PairCodeRecord;
  try {
    record = JSON.parse(raw) as PairCodeRecord;
  } catch {
    return response({ error: "code_corrupt" }, 500);
  }
  if (record.expiresAt < Date.now()) {
    await env.PELU_USAGE_KV.delete(PAIR_CODE_PREFIX + code);
    return response({ error: "code_expired" }, 410);
  }

  // Promote pending token record into the active namespace.
  const pendingKey = PAIR_TOKEN_PREFIX + record.pairToken + ".pending";
  const pendingRaw = await env.PELU_USAGE_KV.get(pendingKey);
  const tokenRecord: PairTokenRecord = pendingRaw
    ? (JSON.parse(pendingRaw) as PairTokenRecord)
    : { createdAt: new Date().toISOString() };

  await env.PELU_USAGE_KV.put(PAIR_TOKEN_PREFIX + record.pairToken, JSON.stringify(tokenRecord));
  await env.PELU_USAGE_KV.delete(pendingKey);
  // Code is one-shot: delete immediately so it can't be replayed.
  await env.PELU_USAGE_KV.delete(PAIR_CODE_PREFIX + code);

  return response({ pairToken: record.pairToken }, 200);
}

function generateNumericCode(digits: number): string {
  const buf = new Uint32Array(1);
  crypto.getRandomValues(buf);
  const max = 10 ** digits;
  const n = buf[0] % max;
  return n.toString().padStart(digits, "0");
}

function generatePairToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function methodNotAllowed(allow: string): Response {
  return response({ error: "method_not_allowed" }, 405, "application/json; charset=utf-8", {
    Allow: allow,
  });
}

function response(
  body: unknown,
  status: number,
  contentType = "application/json; charset=utf-8",
  headers: HeadersInit = {},
): Response {
  const responseHeaders = new Headers(headers);
  responseHeaders.set("Access-Control-Allow-Origin", "*");
  responseHeaders.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
  responseHeaders.set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");

  if (body === null) {
    return new Response(null, { status, headers: responseHeaders });
  }
  responseHeaders.set("Content-Type", contentType);
  if (typeof body === "string") {
    return new Response(body, { status, headers: responseHeaders });
  }
  return new Response(JSON.stringify(body), { status, headers: responseHeaders });
}
