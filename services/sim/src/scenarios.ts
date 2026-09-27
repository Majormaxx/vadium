// Pure scenario planners. Each returns the ordered calls the runner submits and the
// expectations it checks afterwards. Nothing here touches the network.

import type { Address, Hex } from "viem";

import type { LegCounts, Sizing } from "./sizing.js";

export const SCENARIO_NAMES = [
  "unbonded-sandwich",
  "unbonded-mule",
  "bonded-sandwich",
  "bonded-arb-follower",
] as const;
export type ScenarioName = (typeof SCENARIO_NAMES)[number];

/** Actor roles. Each role owns one SimSwapRouter, deployed once and reused across runs. */
export type Role = "A" | "V" | "M" | "B" | "F";
export const ROLE_NAMES: Record<Role, string> = {
  A: "attacker",
  V: "victim",
  M: "mule",
  B: "bonded arbitrageur",
  F: "unbonded follower",
};

/** TickMath.MIN_SQRT_PRICE + 1 and MAX_SQRT_PRICE - 1: unbounded limits in each direction. */
export const MIN_SQRT_PRICE_LIMIT = 4295128740n;
export const MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341n;

export type PlannedCall =
  | {
      kind: "bond";
      /** Sent alone and confirmed before the batch; the runner then waits one block. */
      phase: "setup";
      role: Role;
      amount: bigint;
      label: string;
    }
  | {
      kind: "swap";
      /** Sent back to back with consecutive nonces so the legs share a block. */
      phase: "batch";
      role: Role;
      zeroForOne: boolean;
      /** Negative: exact input. */
      amountSpecified: bigint;
      sqrtPriceLimitX96: bigint;
      hookData: Hex;
      /** Native value sent with the call (the input for zeroForOne legs). */
      value: bigint;
      label: string;
    };

/** Which decoded event argument must equal which actor. */
export interface EventMatch {
  arg: string;
  role?: Role;
  owner?: true;
}

export type Expectation =
  | { id: string; type: "sameBlock"; description: string }
  | { id: string; type: "allSucceeded"; description: string }
  | { id: string; type: "eventEmitted"; event: string; step: number; match?: EventMatch; description: string }
  | { id: string; type: "eventAbsent"; event: string; match?: EventMatch; description: string }
  | { id: string; type: "reserveIncreased"; description: string }
  | { id: string; type: "bondReduced"; role: Role; description: string }
  | { id: string; type: "ownerRefundIncreased"; description: string }
  | { id: string; type: "exemptBefore"; role: Role; expected: boolean; description: string }
  | { id: string; type: "roundTripNonPositive"; role: Role; legs: [number, number]; description: string };

export interface ScenarioPlan {
  name: ScenarioName;
  description: string;
  roles: Role[];
  /** Roles that must hold a live bond before the batch. */
  bondedRoles: Role[];
  calls: PlannedCall[];
  expectations: Expectation[];
}

export interface PlanInput {
  sizing: Sizing;
  minBond: bigint;
  /** The sim owner; named as refund recipient where a scenario wants the refund claimable by the EOA. */
  owner: Address;
}

/** `abi.encode(address)`: the address left-padded to 32 bytes. */
export function encodeVictimKey(recipient: Address): Hex {
  if (!/^0x[0-9a-fA-F]{40}$/.test(recipient)) throw new Error(`not an address: ${recipient}`);
  return `0x${recipient.slice(2).toLowerCase().padStart(64, "0")}`;
}

function swap(role: Role, zeroForOne: boolean, amount: bigint, hookData: Hex, label: string): PlannedCall {
  if (amount <= 0n) throw new Error(`leg for ${role} must be positive`);
  return {
    kind: "swap",
    phase: "batch",
    role,
    zeroForOne,
    amountSpecified: -amount,
    sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT,
    hookData,
    value: zeroForOne ? amount : 0n,
    label,
  };
}

function bond(role: Role, amount: bigint): PlannedCall {
  if (amount <= 0n) throw new Error("minBond must be positive");
  return { kind: "bond", phase: "setup", role, amount, label: `${role} bonds ${amount} raw USDC` };
}

export function legCounts(name: ScenarioName): LegCounts {
  switch (name) {
    case "unbonded-sandwich":
    case "unbonded-mule":
    case "bonded-sandwich":
      return { eth: 2, usdc: 1 };
    case "bonded-arb-follower":
      return { eth: 1, usdc: 1 };
  }
}

export function totalLegCounts(names: readonly ScenarioName[]): LegCounts {
  return names.reduce(
    (acc, n) => {
      const c = legCounts(n);
      return { eth: acc.eth + c.eth, usdc: acc.usdc + c.usdc };
    },
    { eth: 0, usdc: 0 },
  );
}

export function planScenario(name: ScenarioName, input: PlanInput): ScenarioPlan {
  const { sizing, minBond, owner } = input;
  const ethLeg = sizing.ethLeg;
  const reverse = sizing.reverseUsdcLeg;
  const usdcLeg = sizing.usdcLeg;

  switch (name) {
    case "unbonded-sandwich": {
      return {
        name,
        description:
          "An unbonded attacker front-runs and back-runs a victim in one block. The clamp withholds " +
          "the back-run's gain; nothing is slashed because there is no bond.",
        roles: ["A", "V"],
        bondedRoles: [],
        calls: [
          swap("A", true, ethLeg, "0x", "A sells ETH (front-run)"),
          swap("V", true, ethLeg, "0x", "V sells ETH (victim)"),
          swap("A", false, reverse, "0x", "A buys ETH back (back-run)"),
        ],
        expectations: [
          { id: "same-block", type: "sameBlock", description: "all three legs landed in one block" },
          { id: "all-succeeded", type: "allSucceeded", description: "every leg succeeded" },
          { id: "no-slash", type: "eventAbsent", event: "Sandwiched", description: "no Sandwiched event (A is unbonded)" },
          {
            id: "withheld-on-backrun",
            type: "eventEmitted",
            event: "ClampWithheld",
            step: 2,
            match: { arg: "sender", role: "A" },
            description: "ClampWithheld on A's back-run",
          },
          {
            id: "round-trip",
            type: "roundTripNonPositive",
            role: "A",
            legs: [0, 2],
            description: "A's round trip profit in ETH terms is <= 0",
          },
        ],
      };
    }
    case "unbonded-mule": {
      return {
        name,
        description:
          "The back-run is split to a second unbonded address (a mule). The clamp still withholds the " +
          "mule's gain because every clamped swap is held to the block-start price.",
        roles: ["A", "V", "M"],
        bondedRoles: [],
        calls: [
          swap("A", true, ethLeg, "0x", "A sells ETH (front-run)"),
          swap("V", true, ethLeg, "0x", "V sells ETH (victim)"),
          swap("M", false, usdcLeg, "0x", "M buys ETH (mule back-run)"),
        ],
        expectations: [
          { id: "same-block", type: "sameBlock", description: "all three legs landed in one block" },
          { id: "all-succeeded", type: "allSucceeded", description: "every leg succeeded" },
          { id: "no-slash", type: "eventAbsent", event: "Sandwiched", description: "no Sandwiched event (nobody reversed)" },
          {
            id: "withheld-on-mule",
            type: "eventEmitted",
            event: "ClampWithheld",
            step: 2,
            match: { arg: "sender", role: "M" },
            description: "ClampWithheld on M's back-run",
          },
        ],
      };
    }
    case "bonded-sandwich": {
      return {
        name,
        description:
          "A bonded attacker completes a sandwich around a victim whose router names the sim owner as " +
          "refund recipient. The detector slashes the bond, credits the victim, funds the reserve, and " +
          "the second leg is clamped because the exemption covers only the first swap of a block.",
        roles: ["A", "V"],
        bondedRoles: ["A"],
        calls: [
          bond("A", minBond),
          swap("A", true, ethLeg, "0x", "A sells ETH (front-run, exempt)"),
          swap("V", true, ethLeg, encodeVictimKey(owner), "V sells ETH (victim, refund to owner)"),
          swap("A", false, reverse, "0x", "A buys ETH back (back-run, clamped and slashed)"),
        ],
        expectations: [
          { id: "exempt-before", type: "exemptBefore", role: "A", expected: true, description: "A is exempt before the batch" },
          { id: "same-block", type: "sameBlock", description: "all three legs landed in one block" },
          { id: "all-succeeded", type: "allSucceeded", description: "every leg succeeded" },
          {
            id: "slashed",
            type: "eventEmitted",
            event: "Sandwiched",
            step: 3,
            match: { arg: "searcher", role: "A" },
            description: "Sandwiched names A",
          },
          {
            id: "refund-credited",
            type: "eventEmitted",
            event: "VictimRefundCredited",
            step: 3,
            match: { arg: "victim", owner: true },
            description: "VictimRefundCredited names the sim owner",
          },
          { id: "owner-claimable", type: "ownerRefundIncreased", description: "the owner's claimable refund grew" },
          { id: "reserve", type: "reserveIncreased", description: "the pool's insurance reserve grew" },
          { id: "bond-reduced", type: "bondReduced", role: "A", description: "A's bonded balance fell" },
          {
            id: "withheld-on-backrun",
            type: "eventEmitted",
            event: "ClampWithheld",
            step: 3,
            match: { arg: "sender", role: "A" },
            description: "ClampWithheld on A's back-run",
          },
        ],
      };
    }
    case "bonded-arb-follower": {
      return {
        name,
        description:
          "A bonded arbitrageur moves the price on its exempt first swap. An unbonded follower in the " +
          "same block is held to the block-start price, so its gain is withheld while the arbitrageur " +
          "is untouched.",
        roles: ["B", "F"],
        bondedRoles: ["B"],
        calls: [
          bond("B", minBond),
          swap("B", true, ethLeg, "0x", "B sells ETH (exempt arbitrage)"),
          swap("F", false, usdcLeg, "0x", "F buys ETH (unbonded follower)"),
        ],
        expectations: [
          { id: "exempt-before", type: "exemptBefore", role: "B", expected: true, description: "B is exempt before the batch" },
          { id: "same-block", type: "sameBlock", description: "both legs landed in one block" },
          { id: "all-succeeded", type: "allSucceeded", description: "every leg succeeded" },
          {
            id: "withheld-on-follower",
            type: "eventEmitted",
            event: "ClampWithheld",
            step: 2,
            match: { arg: "sender", role: "F" },
            description: "ClampWithheld on F",
          },
          { id: "no-slash", type: "eventAbsent", event: "Sandwiched", description: "no Sandwiched event" },
          {
            id: "b-untouched",
            type: "eventAbsent",
            event: "ClampWithheld",
            match: { arg: "sender", role: "B" },
            description: "nothing withheld from B",
          },
        ],
      };
    }
  }
}

export function rolesFor(names: readonly ScenarioName[], input: PlanInput): Role[] {
  const roles = new Set<Role>();
  for (const n of names) for (const r of planScenario(n, input).roles) roles.add(r);
  return [...roles];
}
