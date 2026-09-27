import { describe, expect, it } from "vitest";
import type { Address } from "viem";

import type { Outcome } from "../src/evaluate.js";
import { buildReport, planTotals, plannedTx, reportFileName, serialize, summarize, timestampSlug } from "../src/report.js";
import { planScenario } from "../src/scenarios.js";
import { Q96 } from "../src/sizing.js";

const OWNER: Address = "0x1111111111111111111111111111111111111111";
const sizing = { ethLeg: 50_000n, usdcLeg: 40_000n, reverseUsdcLeg: 47_482n, reserve0: 1_000_000n, reserve1: 1_000_000n };
const input = { sizing, minBond: 100_000_000n, owner: OWNER };

describe("serialize", () => {
  it("writes bigints as decimal strings and round-trips", () => {
    const text = serialize({ a: 1n, nested: { b: -2n, c: [3n, "x", true, null] } });
    expect(JSON.parse(text)).toEqual({ a: "1", nested: { b: "-2", c: ["3", "x", true, null] } });
    expect(text.endsWith("\n")).toBe(true);
  });
});

describe("file names", () => {
  it("builds a sortable timestamp slug without colons", () => {
    const d = new Date("2026-09-27T03:45:12.345Z");
    expect(timestampSlug(d)).toBe("2026-09-27T03-45-12-345Z");
    expect(reportFileName("bonded-sandwich", d)).toBe("2026-09-27T03-45-12-345Z-bonded-sandwich.json");
  });
});

describe("buildReport", () => {
  const plan = planScenario("unbonded-sandwich", input);
  const snapshot = { blockNumber: 1n, sqrtPriceX96: Q96, liquidity: 1n, insuranceReserve: 0n, withheld0: 0n, withheld1: 0n, ownerClaimable: 0n, bondedBalance: {}, isExempt: {} };
  const outcome: Outcome = { owner: OWNER, routers: {}, steps: [], pre: snapshot, post: snapshot };

  it("marks pass only when every expectation passes", () => {
    const now = new Date("2026-09-27T00:00:00Z");
    const r = buildReport({ plan, outcome, expectations: [{ id: "x", description: "d", pass: true, detail: "" }], chainId: 1301, hook: OWNER, poolId: "0x00", sizing, now });
    expect(r.pass).toBe(true);
    expect(r.needsRetry).toBe(false);
    expect(r.generatedAt).toBe("2026-09-27T00:00:00.000Z");
    expect(r.scenario).toBe("unbonded-sandwich");
    expect(r.calls).toEqual(plan.calls);
  });

  it("marks needsRetry when the same-block expectation failed", () => {
    const r = buildReport({ plan, outcome, expectations: [{ id: "same-block", description: "d", pass: false, detail: "" }], chainId: 1301, hook: OWNER, poolId: "0x00", sizing });
    expect(r.pass).toBe(false);
    expect(r.needsRetry).toBe(true);
    expect(JSON.parse(serialize(r)).needsRetry).toBe(true);
  });

  it("serializes every bigint field", () => {
    const r = buildReport({ plan, outcome, expectations: [], chainId: 1301, hook: OWNER, poolId: "0x00", sizing });
    const parsed = JSON.parse(serialize(r));
    expect(parsed.sizing.ethLeg).toBe("50000");
    expect(parsed.calls[0].amountSpecified).toBe("-50000");
    expect(parsed.pre.sqrtPriceX96).toBe(Q96.toString());
  });
});

describe("plan file pieces", () => {
  it("describes a swap and a bond transaction", () => {
    const plan = planScenario("bonded-sandwich", input);
    const bond = plannedTx(0, plan.calls[0]!, undefined);
    expect(bond).toMatchObject({ index: 0, phase: "setup", role: "A", router: "not deployed yet", function: "bond(hook,uint256)", args: { amount: 100_000_000n }, value: 0n });
    const swap = plannedTx(1, plan.calls[1]!, OWNER);
    expect(swap).toMatchObject({ phase: "batch", router: OWNER, function: "swap(PoolKey,SwapParams,bytes)", value: 50_000n });
    expect(swap.args).toMatchObject({ zeroForOne: true, amountSpecified: -50_000n, hookData: "0x" });
  });

  it("totals inputs and bonds across scenarios", () => {
    const totals = planTotals([planScenario("bonded-sandwich", input), planScenario("bonded-arb-follower", input)]);
    expect(totals).toEqual({ txCount: 7, ethIn: 150_000n, usdcIn: 47_482n + 40_000n, bonds: 200_000_000n });
  });

  it("summarizes results one per line", () => {
    const text = summarize([
      { id: "a", description: "first", pass: true, detail: "ok" },
      { id: "b", description: "second", pass: false, detail: "no" },
    ]);
    expect(text).toBe("  [PASS] a: first (ok)\n  [FAIL] b: second (no)");
  });
});
