import { describe, expect, it } from "vitest";

import {
  MAX_SQRT_PRICE_LIMIT,
  MIN_SQRT_PRICE_LIMIT,
  SCENARIO_NAMES,
  encodeVictimKey,
  legCounts,
  planScenario,
  rolesFor,
  totalLegCounts,
  type PlannedCall,
  type ScenarioName,
} from "../src/scenarios.js";

const OWNER = "0x1111111111111111111111111111111111111111" as const;
const sizing = { ethLeg: 50_000n, usdcLeg: 40_000n, reverseUsdcLeg: 47_482n, reserve0: 1_000_000n, reserve1: 1_000_000n };
const input = { sizing, minBond: 100_000_000n, owner: OWNER };

function swaps(calls: PlannedCall[]) {
  return calls.filter((c): c is Extract<PlannedCall, { kind: "swap" }> => c.kind === "swap");
}

function shape(calls: PlannedCall[]): string[] {
  return calls.map((c) => (c.kind === "bond" ? `bond:${c.role}` : `${c.role}:${c.zeroForOne ? "0->1" : "1->0"}`));
}

describe("swap params", () => {
  it("uses exact input with the unbounded price limit for each direction", () => {
    for (const name of SCENARIO_NAMES) {
      for (const s of swaps(planScenario(name, input).calls)) {
        expect(s.amountSpecified).toBeLessThan(0n);
        expect(s.sqrtPriceLimitX96).toBe(s.zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT);
        expect(s.value).toBe(s.zeroForOne ? -s.amountSpecified : 0n);
        expect(s.phase).toBe("batch");
      }
    }
  });

  it("encodes the victim key as a 32-byte address", () => {
    const hd = encodeVictimKey(OWNER);
    expect(hd.length).toBe(2 + 64);
    expect(hd).toBe(`0x${"0".repeat(24)}${OWNER.slice(2)}`);
    expect(encodeVictimKey("0xAbCdEf0000000000000000000000000000000001")).toBe(`0x${"0".repeat(24)}abcdef0000000000000000000000000000000001`);
    expect(() => encodeVictimKey("0x12" as never)).toThrow();
  });
});

describe("unbonded-sandwich", () => {
  const plan = planScenario("unbonded-sandwich", input);
  it("orders A, V, A with a reversal and no bond", () => {
    expect(shape(plan.calls)).toEqual(["A:0->1", "V:0->1", "A:1->0"]);
    expect(plan.bondedRoles).toEqual([]);
    expect(plan.roles).toEqual(["A", "V"]);
  });
  it("sizes the legs from the sizing", () => {
    const s = swaps(plan.calls);
    expect(s[0]?.amountSpecified).toBe(-50_000n);
    expect(s[1]?.amountSpecified).toBe(-50_000n);
    expect(s[2]?.amountSpecified).toBe(-47_482n);
    expect(s.every((c) => c.hookData === "0x")).toBe(true);
  });
  it("expects no slash, a withhold on A's back-run, and a non-positive round trip", () => {
    const ids = plan.expectations.map((e) => e.id);
    expect(ids).toEqual(["same-block", "all-succeeded", "no-slash", "withheld-on-backrun", "round-trip"]);
    const withheld = plan.expectations.find((e) => e.id === "withheld-on-backrun");
    expect(withheld).toMatchObject({ type: "eventEmitted", event: "ClampWithheld", step: 2, match: { arg: "sender", role: "A" } });
    expect(plan.expectations.find((e) => e.id === "round-trip")).toMatchObject({ type: "roundTripNonPositive", role: "A", legs: [0, 2] });
    expect(plan.expectations.find((e) => e.id === "no-slash")).toMatchObject({ type: "eventAbsent", event: "Sandwiched" });
  });
});

describe("unbonded-mule", () => {
  const plan = planScenario("unbonded-mule", input);
  it("hands the back-run to M", () => {
    expect(shape(plan.calls)).toEqual(["A:0->1", "V:0->1", "M:1->0"]);
    expect(swaps(plan.calls)[2]?.amountSpecified).toBe(-40_000n);
    expect(plan.roles).toEqual(["A", "V", "M"]);
  });
  it("expects the withhold on M and no slash", () => {
    expect(plan.expectations.find((e) => e.id === "withheld-on-mule")).toMatchObject({ event: "ClampWithheld", step: 2, match: { role: "M" } });
    expect(plan.expectations.some((e) => e.type === "eventAbsent" && e.event === "Sandwiched")).toBe(true);
  });
});

describe("bonded-sandwich", () => {
  const plan = planScenario("bonded-sandwich", input);
  it("bonds A first as a setup step, then runs the same three legs", () => {
    expect(shape(plan.calls)).toEqual(["bond:A", "A:0->1", "V:0->1", "A:1->0"]);
    expect(plan.calls[0]).toMatchObject({ kind: "bond", phase: "setup", role: "A", amount: 100_000_000n });
    expect(plan.bondedRoles).toEqual(["A"]);
  });
  it("names the owner as the victim's refund recipient and nobody else", () => {
    const s = swaps(plan.calls);
    expect(s[1]?.hookData).toBe(encodeVictimKey(OWNER));
    expect(s[0]?.hookData).toBe("0x");
    expect(s[2]?.hookData).toBe("0x");
  });
  it("expects the slash, the refund, the reserve, the bond cut, and the clamp on the back-run", () => {
    const byId = Object.fromEntries(plan.expectations.map((e) => [e.id, e]));
    expect(byId["exempt-before"]).toMatchObject({ type: "exemptBefore", role: "A", expected: true });
    expect(byId["slashed"]).toMatchObject({ type: "eventEmitted", event: "Sandwiched", step: 3, match: { arg: "searcher", role: "A" } });
    expect(byId["refund-credited"]).toMatchObject({ type: "eventEmitted", event: "VictimRefundCredited", step: 3, match: { arg: "victim", owner: true } });
    expect(byId["reserve"]).toMatchObject({ type: "reserveIncreased" });
    expect(byId["bond-reduced"]).toMatchObject({ type: "bondReduced", role: "A" });
    expect(byId["owner-claimable"]).toMatchObject({ type: "ownerRefundIncreased" });
    expect(byId["withheld-on-backrun"]).toMatchObject({ event: "ClampWithheld", step: 3, match: { role: "A" } });
  });
});

describe("bonded-arb-follower", () => {
  const plan = planScenario("bonded-arb-follower", input);
  it("bonds B, then B sells and F buys", () => {
    expect(shape(plan.calls)).toEqual(["bond:B", "B:0->1", "F:1->0"]);
    expect(plan.bondedRoles).toEqual(["B"]);
    expect(plan.roles).toEqual(["B", "F"]);
  });
  it("expects the withhold on F only", () => {
    const byId = Object.fromEntries(plan.expectations.map((e) => [e.id, e]));
    expect(byId["withheld-on-follower"]).toMatchObject({ event: "ClampWithheld", step: 2, match: { role: "F" } });
    expect(byId["b-untouched"]).toMatchObject({ type: "eventAbsent", event: "ClampWithheld", match: { arg: "sender", role: "B" } });
    expect(byId["no-slash"]).toMatchObject({ type: "eventAbsent", event: "Sandwiched" });
  });
});

describe("leg counts and roles", () => {
  it("counts input sides per scenario", () => {
    expect(legCounts("unbonded-sandwich")).toEqual({ eth: 2, usdc: 1 });
    expect(legCounts("unbonded-mule")).toEqual({ eth: 2, usdc: 1 });
    expect(legCounts("bonded-sandwich")).toEqual({ eth: 2, usdc: 1 });
    expect(legCounts("bonded-arb-follower")).toEqual({ eth: 1, usdc: 1 });
    expect(totalLegCounts(SCENARIO_NAMES)).toEqual({ eth: 7, usdc: 4 });
  });

  it("matches the planned calls", () => {
    for (const name of SCENARIO_NAMES) {
      const s = swaps(planScenario(name, input).calls);
      expect(legCounts(name)).toEqual({ eth: s.filter((c) => c.zeroForOne).length, usdc: s.filter((c) => !c.zeroForOne).length });
    }
  });

  it("collects distinct roles across scenarios", () => {
    expect(rolesFor(["unbonded-sandwich", "unbonded-mule"], input)).toEqual(["A", "V", "M"]);
    expect(rolesFor(SCENARIO_NAMES, input)).toEqual(["A", "V", "M", "B", "F"]);
  });

  it("is deterministic", () => {
    for (const name of SCENARIO_NAMES as readonly ScenarioName[]) {
      expect(planScenario(name, input)).toEqual(planScenario(name, input));
    }
  });

  it("rejects a non-positive leg or bond", () => {
    expect(() => planScenario("unbonded-sandwich", { ...input, sizing: { ...sizing, ethLeg: 0n } })).toThrow();
    expect(() => planScenario("bonded-sandwich", { ...input, minBond: 0n })).toThrow();
  });
});
