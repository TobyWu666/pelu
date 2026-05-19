import { describe, expect, it } from "vitest";
import { detectTransitions, notificationText } from "../src/transitions";

const m = (provider: string, usedPercent: number | null) => ({ provider, usedPercent });

describe("detectTransitions", () => {
  it("returns no transitions when there is no previous snapshot", () => {
    expect(detectTransitions(null, { metrics: [m("claude_code", 95)] })).toEqual([]);
  });

  it("fires lowQuota when previous was at-or-under 90 and current goes above", () => {
    const prev = { metrics: [m("claude_code", 88)] };
    const next = { metrics: [m("claude_code", 91)] };
    expect(detectTransitions(prev, next)).toEqual([
      { provider: "claude_code", kind: "lowQuota" },
    ]);
  });

  it("does NOT fire lowQuota when previous was already above 90", () => {
    const prev = { metrics: [m("claude_code", 92)] };
    const next = { metrics: [m("claude_code", 96)] };
    expect(detectTransitions(prev, next)).toEqual([]);
  });

  it("fires lowQuota on the exact crossover (≤90 → >90)", () => {
    const prev = { metrics: [m("claude_code", 90)] };
    const next = { metrics: [m("claude_code", 91)] };
    expect(detectTransitions(prev, next)).toEqual([
      { provider: "claude_code", kind: "lowQuota" },
    ]);
  });

  it("fires reset when value drops from >50 to <20", () => {
    const prev = { metrics: [m("claude_code", 75)] };
    const next = { metrics: [m("claude_code", 5)] };
    expect(detectTransitions(prev, next)).toEqual([
      { provider: "claude_code", kind: "reset" },
    ]);
  });

  it("does NOT fire reset when drop is shallow (60 → 30)", () => {
    const prev = { metrics: [m("claude_code", 60)] };
    const next = { metrics: [m("claude_code", 30)] };
    expect(detectTransitions(prev, next)).toEqual([]);
  });

  it("does NOT fire reset when previous was already low (40 → 5)", () => {
    const prev = { metrics: [m("claude_code", 40)] };
    const next = { metrics: [m("claude_code", 5)] };
    expect(detectTransitions(prev, next)).toEqual([]);
  });

  it("ignores metrics whose usedPercent is null on either side", () => {
    expect(
      detectTransitions(
        { metrics: [m("claude_code", null)] },
        { metrics: [m("claude_code", 95)] },
      ),
    ).toEqual([]);
    expect(
      detectTransitions(
        { metrics: [m("claude_code", 80)] },
        { metrics: [m("claude_code", null)] },
      ),
    ).toEqual([]);
  });

  it("matches providers by name and ignores ones that disappear", () => {
    const prev = { metrics: [m("claude_code", 88), m("codex", 80)] };
    const next = { metrics: [m("claude_code", 95)] }; // codex absent
    expect(detectTransitions(prev, next)).toEqual([
      { provider: "claude_code", kind: "lowQuota" },
    ]);
  });

  it("can emit multiple transitions across providers", () => {
    const prev = { metrics: [m("claude_code", 85), m("codex", 70)] };
    const next = { metrics: [m("claude_code", 95), m("codex", 5)] };
    expect(detectTransitions(prev, next)).toEqual([
      { provider: "claude_code", kind: "lowQuota" },
      { provider: "codex", kind: "reset" },
    ]);
  });
});

describe("notificationText", () => {
  it("uses Claude Code display name for both schema spellings", () => {
    expect(notificationText({ provider: "claude_code", kind: "lowQuota" }).body).toContain(
      "Claude Code",
    );
    expect(notificationText({ provider: "claudeCode", kind: "lowQuota" }).body).toContain(
      "Claude Code",
    );
  });

  it("uses Codex display name", () => {
    expect(notificationText({ provider: "codex", kind: "reset" }).body).toContain("Codex");
  });
});
