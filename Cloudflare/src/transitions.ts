// Detect "low quota" and "reset" transitions between two usage snapshots.

interface UsageMetric {
  provider: string;
  usedPercent: number | null;
}

interface UsageSnapshot {
  metrics: UsageMetric[];
}

export type TransitionKind = "lowQuota" | "reset";

export interface Transition {
  provider: string; // "claude_code" | "codex"
  kind: TransitionKind;
}

const LOW_QUOTA_THRESHOLD = 90;
// 重置時，used% 通常從高位（>50）一口氣回到接近 0。
const RESET_HIGH_THRESHOLD = 50;
const RESET_LOW_THRESHOLD = 20;

export function detectTransitions(
  previous: UsageSnapshot | null,
  next: UsageSnapshot,
): Transition[] {
  if (!previous) return [];

  const result: Transition[] = [];
  const prevByProvider = new Map(previous.metrics.map((m) => [m.provider, m]));

  for (const cur of next.metrics) {
    const prev = prevByProvider.get(cur.provider);
    if (!prev) continue;
    const prevPercent = prev.usedPercent;
    const curPercent = cur.usedPercent;
    if (prevPercent == null || curPercent == null) continue;

    // Low-quota crossing: prev ≤ 90 → cur > 90
    if (prevPercent <= LOW_QUOTA_THRESHOLD && curPercent > LOW_QUOTA_THRESHOLD) {
      result.push({ provider: cur.provider, kind: "lowQuota" });
    }

    // Reset: prev was high (>50), cur dropped to low (<20)
    if (prevPercent > RESET_HIGH_THRESHOLD && curPercent < RESET_LOW_THRESHOLD) {
      result.push({ provider: cur.provider, kind: "reset" });
    }
  }

  return result;
}

export function notificationText(
  t: Transition,
): { title: string; body: string } {
  const providerName = providerDisplayName(t.provider);
  if (t.kind === "lowQuota") {
    return {
      title: "額度即將用完",
      body: `${providerName} 5 小時剩餘額度低於 10%。`,
    };
  }
  return {
    title: "額度已重置",
    body: `${providerName} 用量已重置，可以繼續用了。`,
  };
}

function providerDisplayName(provider: string): string {
  switch (provider) {
    case "claude_code":
    case "claudeCode":
      return "Claude Code";
    case "codex":
      return "Codex";
    default:
      return provider;
  }
}
