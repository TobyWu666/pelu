// APNs token-based authentication + push delivery (Cloudflare Workers).
// Uses Web Crypto API (ES256 / ECDSA P-256 + SHA-256) — no Node crypto.

export interface APNsConfig {
  teamId: string;
  keyId: string;
  /** PEM-encoded .p8 key contents, including BEGIN/END lines. */
  authKey: string;
  /** App bundle id, used as apns-topic. */
  bundleId: string;
  /** "development" → sandbox; "production" → prod. */
  environment: "development" | "production";
}

interface CachedJWT {
  token: string;
  expiresAt: number;
}

let cachedJWT: CachedJWT | null = null;
// In-flight promise lock: when 100 devices fire pushes concurrently and the cache
// is cold/stale, they all hit getAPNsJWT(). Without this, every caller would
// independently import the P8 key + ECDSA-sign. With the lock, only the first
// does the work; the rest await the shared promise.
let jwtInflight: Promise<string> | null = null;
// Cache the imported CryptoKey too — importP8Key parses PEM, base64-decodes,
// and calls crypto.subtle.importKey on every call otherwise.
let cachedKey: CryptoKey | null = null;

export async function getAPNsJWT(config: APNsConfig): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  // Refresh 10 minutes before the 1-hour expiry (APNs requires <60min).
  if (cachedJWT && cachedJWT.expiresAt > now + 600) {
    return cachedJWT.token;
  }
  if (jwtInflight) return jwtInflight;

  jwtInflight = (async () => {
    try {
      const header = base64URL(JSON.stringify({ alg: "ES256", kid: config.keyId, typ: "JWT" }));
      const payload = base64URL(JSON.stringify({ iss: config.teamId, iat: now }));
      const signingInput = `${header}.${payload}`;

      if (!cachedKey) {
        cachedKey = await importP8Key(config.authKey);
      }
      const signature = await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        cachedKey,
        new TextEncoder().encode(signingInput),
      );
      const jwt = `${signingInput}.${base64URLBytes(new Uint8Array(signature))}`;
      cachedJWT = { token: jwt, expiresAt: now + 3600 };
      return jwt;
    } finally {
      jwtInflight = null;
    }
  })();
  return jwtInflight;
}

/// Drop the cached JWT — call this when APNs returns 403 ExpiredProviderToken.
export function invalidateJWTCache(): void {
  cachedJWT = null;
}

export interface APNsResult {
  status: number;
  reason?: string;
}

/// Silent background push — wakes the app for ~30s to refresh data, no UI shown.
export async function sendAPNsBackgroundRefresh(
  deviceToken: string,
  config: APNsConfig,
): Promise<APNsResult> {
  const jwt = await getAPNsJWT(config);
  const host =
    config.environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";

  const res = await fetch(`${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": config.bundleId,
      "apns-push-type": "background",
      "apns-priority": "5",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: { "content-available": 1 },
      peluRefresh: true,
    }),
  });

  if (res.ok) return { status: res.status };
  let reason: string | undefined;
  try {
    const json = (await res.json()) as { reason?: string };
    reason = json.reason;
  } catch {
    // ignore
  }
  return { status: res.status, reason };
}

export async function sendAPNsAlert(
  deviceToken: string,
  title: string,
  body: string,
  config: APNsConfig,
): Promise<APNsResult> {
  const jwt = await getAPNsJWT(config);
  const host =
    config.environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";

  const res = await fetch(`${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": config.bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: {
        alert: { title, body },
        "content-available": 1,
        sound: "default",
      },
      peluRefresh: true,
    }),
  });

  if (res.ok) return { status: res.status };
  let reason: string | undefined;
  try {
    const json = (await res.json()) as { reason?: string };
    reason = json.reason;
  } catch {
    // ignore
  }
  return { status: res.status, reason };
}

// ---- helpers ----

async function importP8Key(pem: string): Promise<CryptoKey> {
  const cleaned = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const der = base64Decode(cleaned);
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

function base64URL(input: string): string {
  return base64URLBytes(new TextEncoder().encode(input));
}

function base64URLBytes(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64Decode(b64: string): ArrayBuffer {
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}
