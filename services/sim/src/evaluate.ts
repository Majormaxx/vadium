// Pure evaluation of a scenario's expectations against decoded receipts and the state
// read before and after the batch. Nothing here touches the network.

import type { Address, Hex } from "viem";

import type { EventMatch, Expectation, Role, ScenarioPlan } from "./scenarios.js";
import { toCurrency0 } from "./sizing.js";

export interface DecodedEvent {
  name: string;
  /** Emitting contract. */
  address: Address;
  args: Record<string, unknown>;
}

export interface StepOutcome {
  /** Index into `plan.calls`. */
  index: number;
  txHash: Hex | null;
  blockNumber: bigint | null;
  status: "success" | "reverted" | "skipped" | "missing";
  gasUsed: bigint | null;
  events: DecodedEvent[];
  note?: string;
}

export interface StateSnapshot {
  blockNumber: bigint;
  sqrtPriceX96: bigint;
  liquidity: bigint;
  insuranceReserve: bigint;
  withheld0: bigint;
  withheld1: bigint;
  ownerClaimable: bigint;
  bondedBalance: Partial<Record<Role, bigint>>;
  isExempt: Partial<Record<Role, boolean>>;
}

export interface Outcome {
  owner: Address;
  routers: Partial<Record<Role, Address>>;
  steps: StepOutcome[];
  pre: StateSnapshot;
  post: StateSnapshot;
}

export interface ExpectationResult {
  id: string;
  description: string;
  pass: boolean;
  detail: string;
}

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

function same(a: unknown, b: string): boolean {
  return typeof a === "string" && a.toLowerCase() === b.toLowerCase();
}

function batchSteps(plan: ScenarioPlan, outcome: Outcome): StepOutcome[] {
  return outcome.steps.filter((s) => plan.calls[s.index]?.phase === "batch");
}

function matchTarget(match: EventMatch, outcome: Outcome): Address | undefined {
  if (match.owner) return outcome.owner;
  if (match.role !== undefined) return outcome.routers[match.role];
  return undefined;
}

function eventMatches(ev: DecodedEvent, name: string, match: EventMatch | undefined, outcome: Outcome): boolean {
  if (ev.name !== name) return false;
  if (match === undefined) return true;
  const target = matchTarget(match, outcome);
  if (target === undefined) return false;
  return same(ev.args[match.arg], target);
}

function describeMatch(match: EventMatch | undefined, outcome: Outcome): string {
  if (match === undefined) return "";
  const target = matchTarget(match, outcome);
  const who = match.owner ? "owner" : match.role;
  return ` with ${match.arg} = ${who} (${target ?? "unresolved"})`;
}

/** Block-start price for the batch: the hook's own checkpoint when it was emitted, else the pre-state read. */
export function blockStartPrice(plan: ScenarioPlan, outcome: Outcome): bigint {
  for (const step of batchSteps(plan, outcome)) {
    for (const ev of step.events) {
      if (ev.name === "Checkpointed" && typeof ev.args.sqrtPriceX96 === "bigint") return ev.args.sqrtPriceX96;
    }
  }
  return outcome.pre.sqrtPriceX96;
}

/** Realized (amount0, amount1) for a router in a step: the PoolManager Swap delta minus anything withheld. */
export function realizedDelta(step: StepOutcome, router: Address): { amount0: bigint; amount1: bigint } | undefined {
  const swap = step.events.find((e) => e.name === "Swap" && same(e.args.sender, router));
  if (swap === undefined) return undefined;
  const a0 = swap.args.amount0;
  const a1 = swap.args.amount1;
  if (typeof a0 !== "bigint" || typeof a1 !== "bigint") return undefined;
  let amount0 = a0;
  let amount1 = a1;
  for (const ev of step.events) {
    if (ev.name !== "ClampWithheld" || !same(ev.args.sender, router)) continue;
    const amount = ev.args.amount;
    if (typeof amount !== "bigint") continue;
    if (same(ev.args.currency, ZERO_ADDRESS)) amount0 -= amount;
    else amount1 -= amount;
  }
  return { amount0, amount1 };
}

function evaluateOne(exp: Expectation, plan: ScenarioPlan, outcome: Outcome): ExpectationResult {
  const base = { id: exp.id, description: exp.description };
  switch (exp.type) {
    case "sameBlock": {
      const blocks = batchSteps(plan, outcome).map((s) => s.blockNumber);
      if (blocks.length === 0) return { ...base, pass: false, detail: "no batch steps" };
      if (blocks.some((b) => b === null)) return { ...base, pass: false, detail: "a batch step has no receipt" };
      const distinct = new Set(blocks.map((b) => String(b)));
      return distinct.size === 1
        ? { ...base, pass: true, detail: `block ${blocks[0]}` }
        : { ...base, pass: false, detail: `blocks ${blocks.join(", ")}; retry the scenario` };
    }
    case "allSucceeded": {
      const bad = outcome.steps.filter((s) => s.status === "reverted" || s.status === "missing");
      return bad.length === 0
        ? { ...base, pass: true, detail: `${outcome.steps.length} steps` }
        : { ...base, pass: false, detail: bad.map((s) => `step ${s.index} ${s.status}`).join(", ") };
    }
    case "eventEmitted": {
      const step = outcome.steps.find((s) => s.index === exp.step);
      if (step === undefined) return { ...base, pass: false, detail: `no outcome for step ${exp.step}` };
      const hit = step.events.find((e) => eventMatches(e, exp.event, exp.match, outcome));
      const where = `${exp.event}${describeMatch(exp.match, outcome)} in step ${exp.step}`;
      return hit !== undefined
        ? { ...base, pass: true, detail: `${where}: ${formatArgs(hit.args)}` }
        : { ...base, pass: false, detail: `missing ${where}; saw [${step.events.map((e) => e.name).join(", ")}]` };
    }
    case "eventAbsent": {
      const hits = outcome.steps.flatMap((s) =>
        s.events.filter((e) => eventMatches(e, exp.event, exp.match, outcome)).map((e) => ({ step: s.index, e })),
      );
      const where = `${exp.event}${describeMatch(exp.match, outcome)}`;
      return hits.length === 0
        ? { ...base, pass: true, detail: `no ${where}` }
        : { ...base, pass: false, detail: `${where} emitted in step ${hits.map((h) => h.step).join(", ")}` };
    }
    case "reserveIncreased": {
      const { pre, post } = outcome;
      return post.insuranceReserve > pre.insuranceReserve
        ? { ...base, pass: true, detail: `${pre.insuranceReserve} -> ${post.insuranceReserve}` }
        : { ...base, pass: false, detail: `${pre.insuranceReserve} -> ${post.insuranceReserve}` };
    }
    case "ownerRefundIncreased": {
      const { pre, post } = outcome;
      return post.ownerClaimable > pre.ownerClaimable
        ? { ...base, pass: true, detail: `${pre.ownerClaimable} -> ${post.ownerClaimable}` }
        : { ...base, pass: false, detail: `${pre.ownerClaimable} -> ${post.ownerClaimable}` };
    }
    case "bondReduced": {
      const before = outcome.pre.bondedBalance[exp.role];
      const after = outcome.post.bondedBalance[exp.role];
      if (before === undefined || after === undefined) {
        return { ...base, pass: false, detail: `bonded balance of ${exp.role} not read` };
      }
      return after < before
        ? { ...base, pass: true, detail: `${before} -> ${after}` }
        : { ...base, pass: false, detail: `${before} -> ${after}` };
    }
    case "exemptBefore": {
      const v = outcome.pre.isExempt[exp.role];
      if (v === undefined) return { ...base, pass: false, detail: `exemption of ${exp.role} not read` };
      return v === exp.expected
        ? { ...base, pass: true, detail: `isExempt(${exp.role}) = ${v}` }
        : { ...base, pass: false, detail: `isExempt(${exp.role}) = ${v}, expected ${exp.expected}` };
    }
    case "roundTripNonPositive": {
      const router = outcome.routers[exp.role];
      if (router === undefined) return { ...base, pass: false, detail: `no router for ${exp.role}` };
      let sum0 = 0n;
      let sum1 = 0n;
      for (const i of exp.legs) {
        const step = outcome.steps.find((s) => s.index === i);
        if (step === undefined) return { ...base, pass: false, detail: `no outcome for step ${i}` };
        const d = realizedDelta(step, router);
        if (d === undefined) return { ...base, pass: false, detail: `no Swap event for ${exp.role} in step ${i}` };
        sum0 += d.amount0;
        sum1 += d.amount1;
      }
      const price = blockStartPrice(plan, outcome);
      const profit0 = sum0 + toCurrency0(sum1, price);
      const detail = `net currency0 ${sum0}, net currency1 ${sum1}, profit in currency0 at block start ${profit0}`;
      return profit0 <= 0n ? { ...base, pass: true, detail } : { ...base, pass: false, detail };
    }
  }
}

function formatArgs(args: Record<string, unknown>): string {
  return Object.entries(args)
    .map(([k, v]) => `${k}=${typeof v === "bigint" ? v.toString() : String(v)}`)
    .join(" ");
}

export function evaluate(plan: ScenarioPlan, outcome: Outcome): ExpectationResult[] {
  return plan.expectations.map((e) => evaluateOne(e, plan, outcome));
}

/** A scenario needs a retry when its legs did not share a block; other failures are real. */
export function needsRetry(results: ExpectationResult[]): boolean {
  return results.some((r) => r.id === "same-block" && !r.pass);
}
