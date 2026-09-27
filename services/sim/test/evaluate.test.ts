import { describe, expect, it } from "vitest";
import type { Address } from "viem";

import { blockStartPrice, evaluate, needsRetry, realizedDelta, type DecodedEvent, type Outcome, type StateSnapshot, type StepOutcome } from "../src/evaluate.js";
import { encodeVictimKey, planScenario } from "../src/scenarios.js";
import { Q96 } from "../src/sizing.js";

const OWNER: Address = "0x1111111111111111111111111111111111111111";
const HOOK: Address = "0x2222222222222222222222222222222222222222";
const PM: Address = "0x3333333333333333333333333333333333333333";
const ROUTERS = {
  A: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as Address,
  V: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as Address,
  M: "0xcccccccccccccccccccccccccccccccccccccccc" as Address,
  B: "0xdddddddddddddddddddddddddddddddddddddddd" as Address,
  F: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" as Address,
};
const ZERO: Address = "0x0000000000000000000000000000000000000000";
const USDC: Address = "0x31d0220469e10c4E71834a79b1f276d740d3768F";
const POOL = "0x8e04e9c3fd9137cdc79ef352d1b1af9c5b3c5384cca2d8641c754bd6a2000304";

const sizing = { ethLeg: 50_000n, usdcLeg: 40_000n, reverseUsdcLeg: 47_482n, reserve0: 1_000_000n, reserve1: 1_000_000n };
const input = { sizing, minBond: 100_000_000n, owner: OWNER };

function swapEvent(sender: Address, amount0: bigint, amount1: bigint): DecodedEvent {
  return { name: "Swap", address: PM, args: { id: POOL, sender, amount0, amount1, sqrtPriceX96: Q96, liquidity: 1_000_000n, tick: 0, fee: 3000 } };
}
function withheld(sender: Address, currency: Address, amount: bigint): DecodedEvent {
  return { name: "ClampWithheld", address: HOOK, args: { poolId: POOL, sender, currency, amount } };
}
function checkpointed(sqrtPriceX96: bigint): DecodedEvent {
  return { name: "Checkpointed", address: HOOK, args: { poolId: POOL, blockNumber: 100n, sqrtPriceX96, liquidity: 1_000_000n } };
}
function sandwiched(searcher: Address, slashed: bigint, refunded: bigint): DecodedEvent {
  return { name: "Sandwiched", address: HOOK, args: { poolId: POOL, searcher, slashed, isRepeat: false, remaining: 50_000_000n, flaggedUntil: 172_900n, refunded } };
}
function refundCredited(victim: Address, searcher: Address, amount: bigint): DecodedEvent {
  return { name: "VictimRefundCredited", address: HOOK, args: { poolId: POOL, victim, searcher, amount } };
}
function step(index: number, block: bigint, events: DecodedEvent[], status: StepOutcome["status"] = "success"): StepOutcome {
  return { index, txHash: `0x${index.toString(16).padStart(64, "0")}`, blockNumber: block, status, gasUsed: 300_000n, events };
}
function state(over: Partial<StateSnapshot> = {}): StateSnapshot {
  return {
    blockNumber: 99n,
    sqrtPriceX96: Q96,
    liquidity: 1_000_000n,
    insuranceReserve: 0n,
    withheld0: 0n,
    withheld1: 0n,
    ownerClaimable: 0n,
    bondedBalance: {},
    isExempt: {},
    ...over,
  };
}

/** A clamped unbonded sandwich: the back-run's 4,000 wei gain is withheld, leaving A 2,000 wei down. */
function unbondedSteps(block = 100n): StepOutcome[] {
  return [
    step(0, block, [checkpointed(Q96), swapEvent(ROUTERS.A, -50_000n, 47_482n)]),
    step(1, block, [swapEvent(ROUTERS.V, -50_000n, 42_000n)]),
    step(2, block, [swapEvent(ROUTERS.A, 52_000n, -47_482n), withheld(ROUTERS.A, ZERO, 4_000n)]),
  ];
}

describe("unbonded-sandwich", () => {
  const plan = planScenario("unbonded-sandwich", input);

  it("passes on a clamped sandwich in one block", () => {
    const outcome: Outcome = { owner: OWNER, routers: ROUTERS, steps: unbondedSteps(), pre: state(), post: state() };
    const results = evaluate(plan, outcome);
    expect(results.map((r) => [r.id, r.pass])).toEqual([
      ["same-block", true],
      ["all-succeeded", true],
      ["no-slash", true],
      ["withheld-on-backrun", true],
      ["round-trip", true],
    ]);
    expect(results.find((r) => r.id === "round-trip")?.detail).toContain("profit in currency0 at block start -2000");
    expect(needsRetry(results)).toBe(false);
  });

  it("fails the round trip and the withhold when nothing was clamped", () => {
    const steps = unbondedSteps();
    steps[2] = step(2, 100n, [swapEvent(ROUTERS.A, 52_000n, -47_482n)]);
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps, pre: state(), post: state() });
    const byId = Object.fromEntries(results.map((r) => [r.id, r]));
    expect(byId["withheld-on-backrun"]?.pass).toBe(false);
    expect(byId["withheld-on-backrun"]?.detail).toContain("missing ClampWithheld");
    expect(byId["round-trip"]?.pass).toBe(false);
    expect(byId["round-trip"]?.detail).toContain("2000");
  });

  it("does not credit a withhold that names another sender", () => {
    const steps = unbondedSteps();
    steps[2] = step(2, 100n, [swapEvent(ROUTERS.A, 52_000n, -47_482n), withheld(ROUTERS.V, ZERO, 4_000n)]);
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps, pre: state(), post: state() });
    expect(results.find((r) => r.id === "withheld-on-backrun")?.pass).toBe(false);
  });

  it("flags a split batch as needing a retry", () => {
    const steps = unbondedSteps();
    steps[2] = { ...(steps[2] as StepOutcome), blockNumber: 101n };
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps, pre: state(), post: state() });
    const same = results.find((r) => r.id === "same-block");
    expect(same?.pass).toBe(false);
    expect(same?.detail).toContain("100, 100, 101");
    expect(needsRetry(results)).toBe(true);
  });

  it("fails no-slash when a Sandwiched event appears", () => {
    const steps = unbondedSteps();
    steps[2]?.events.push(sandwiched(ROUTERS.A, 1n, 0n));
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps, pre: state(), post: state() });
    expect(results.find((r) => r.id === "no-slash")).toMatchObject({ pass: false, detail: "Sandwiched emitted in step 2" });
  });

  it("fails all-succeeded on a reverted leg", () => {
    const steps = unbondedSteps();
    steps[1] = step(1, 100n, [], "reverted");
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps, pre: state(), post: state() });
    expect(results.find((r) => r.id === "all-succeeded")).toMatchObject({ pass: false, detail: "step 1 reverted" });
  });
});

describe("bonded-sandwich", () => {
  const plan = planScenario("bonded-sandwich", input);
  const pre = state({ bondedBalance: { A: 100_000_000n, V: 0n }, isExempt: { A: true, V: false } });
  const post = state({ blockNumber: 101n, insuranceReserve: 49_994_518n, ownerClaimable: 5_482n, bondedBalance: { A: 50_000_000n, V: 0n }, isExempt: { A: false, V: false } });
  const steps: StepOutcome[] = [
    step(0, 98n, [{ name: "Bonded", address: HOOK, args: { searcher: ROUTERS.A, amount: 100_000_000n, depositBlock: 98n } }]),
    step(1, 100n, [checkpointed(Q96), swapEvent(ROUTERS.A, -50_000n, 47_482n)]),
    step(2, 100n, [swapEvent(ROUTERS.V, -50_000n, 42_000n)]),
    step(3, 100n, [
      swapEvent(ROUTERS.A, 52_000n, -47_482n),
      withheld(ROUTERS.A, ZERO, 4_000n),
      refundCredited(OWNER, ROUTERS.A, 5_482n),
      sandwiched(ROUTERS.A, 50_000_000n, 5_482n),
    ]),
  ];

  it("passes when slash, refund, reserve, and clamp all show", () => {
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps, pre, post });
    expect(results.every((r) => r.pass)).toBe(true);
    expect(results.map((r) => r.id)).toEqual([
      "exempt-before", "same-block", "all-succeeded", "slashed", "refund-credited", "owner-claimable", "reserve", "bond-reduced", "withheld-on-backrun",
    ]);
  });

  it("ignores the setup step when checking same-block", () => {
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps, pre, post });
    expect(results.find((r) => r.id === "same-block")).toMatchObject({ pass: true, detail: "block 100" });
  });

  it("fails when the refund went to the router instead of the owner", () => {
    const wrong = steps.map((s) => ({ ...s, events: [...s.events] }));
    (wrong[3] as StepOutcome).events = [swapEvent(ROUTERS.A, 52_000n, -47_482n), withheld(ROUTERS.A, ZERO, 4_000n), refundCredited(ROUTERS.V, ROUTERS.A, 5_482n), sandwiched(ROUTERS.A, 50_000_000n, 5_482n)];
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps: wrong, pre, post: { ...post, ownerClaimable: 0n } });
    const byId = Object.fromEntries(results.map((r) => [r.id, r]));
    expect(byId["refund-credited"]?.pass).toBe(false);
    expect(byId["owner-claimable"]?.pass).toBe(false);
    expect(byId["slashed"]?.pass).toBe(true);
  });

  it("fails exempt-before when A was flagged going in", () => {
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps, pre: { ...pre, isExempt: { A: false } }, post });
    expect(results.find((r) => r.id === "exempt-before")).toMatchObject({ pass: false });
  });

  it("fails reserve and bond checks when state did not move", () => {
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps, pre, post: pre });
    const byId = Object.fromEntries(results.map((r) => [r.id, r]));
    expect(byId["reserve"]?.pass).toBe(false);
    expect(byId["bond-reduced"]?.pass).toBe(false);
    expect(byId["owner-claimable"]?.pass).toBe(false);
  });

  it("treats a skipped bond step as fine for all-succeeded", () => {
    const skipped = [{ ...(steps[0] as StepOutcome), status: "skipped" as const, txHash: null, blockNumber: null }, ...steps.slice(1)];
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps: skipped, pre, post });
    expect(results.find((r) => r.id === "all-succeeded")?.pass).toBe(true);
  });
});

describe("bonded-arb-follower", () => {
  const plan = planScenario("bonded-arb-follower", input);
  const pre = state({ bondedBalance: { B: 100_000_000n }, isExempt: { B: true, F: false } });
  const good: StepOutcome[] = [
    step(0, 98n, []),
    step(1, 100n, [checkpointed(Q96), swapEvent(ROUTERS.B, -50_000n, 47_482n)]),
    step(2, 100n, [swapEvent(ROUTERS.F, 41_000n, -40_000n), withheld(ROUTERS.F, ZERO, 1_500n)]),
  ];
  it("passes when only F is withheld", () => {
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps: good, pre, post: pre });
    expect(results.every((r) => r.pass)).toBe(true);
  });
  it("fails b-untouched when B is withheld", () => {
    const bad = good.map((s) => ({ ...s, events: [...s.events] }));
    bad[1]?.events.push(withheld(ROUTERS.B, USDC, 10n));
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps: bad, pre, post: pre });
    expect(results.find((r) => r.id === "b-untouched")).toMatchObject({ pass: false, detail: expect.stringContaining("step 1") });
    expect(results.find((r) => r.id === "withheld-on-follower")?.pass).toBe(true);
  });
});

describe("unbonded-mule", () => {
  const plan = planScenario("unbonded-mule", input);
  it("passes when the mule is withheld", () => {
    const steps: StepOutcome[] = [
      step(0, 100n, [checkpointed(Q96), swapEvent(ROUTERS.A, -50_000n, 47_482n)]),
      step(1, 100n, [swapEvent(ROUTERS.V, -50_000n, 42_000n)]),
      step(2, 100n, [swapEvent(ROUTERS.M, 43_000n, -40_000n), withheld(ROUTERS.M, ZERO, 3_000n)]),
    ];
    const results = evaluate(plan, { owner: OWNER, routers: ROUTERS, steps, pre: state(), post: state() });
    expect(results.every((r) => r.pass)).toBe(true);
  });
});

describe("helpers", () => {
  it("realizedDelta subtracts the withheld amount on the right currency", () => {
    const s = step(2, 100n, [swapEvent(ROUTERS.A, 52_000n, -47_482n), withheld(ROUTERS.A, ZERO, 4_000n)]);
    expect(realizedDelta(s, ROUTERS.A)).toEqual({ amount0: 48_000n, amount1: -47_482n });
    const t = step(2, 100n, [swapEvent(ROUTERS.A, -50_000n, 48_000n), withheld(ROUTERS.A, USDC, 1_000n)]);
    expect(realizedDelta(t, ROUTERS.A)).toEqual({ amount0: -50_000n, amount1: 47_000n });
    expect(realizedDelta(t, ROUTERS.V)).toBeUndefined();
  });

  it("prefers the hook's checkpoint price over the pre-state read", () => {
    const plan = planScenario("unbonded-sandwich", input);
    const outcome: Outcome = { owner: OWNER, routers: ROUTERS, steps: unbondedSteps(), pre: state({ sqrtPriceX96: 2n * Q96 }), post: state() };
    expect(blockStartPrice(plan, outcome)).toBe(Q96);
    const noCheckpoint = { ...outcome, steps: unbondedSteps().map((s) => ({ ...s, events: s.events.filter((e) => e.name !== "Checkpointed") })) };
    expect(blockStartPrice(plan, noCheckpoint)).toBe(2n * Q96);
  });

  it("uses the victim key for the refund match, not the router", () => {
    expect(encodeVictimKey(OWNER)).not.toBe(encodeVictimKey(ROUTERS.V));
  });
});
