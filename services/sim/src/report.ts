import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Address, Hex } from "viem";

import type { ExpectationResult, Outcome, StepOutcome, StateSnapshot } from "./evaluate.js";
import type { PlannedCall, Role, ScenarioName, ScenarioPlan } from "./scenarios.js";
import type { Sizing } from "./sizing.js";

export const REPORT_VERSION = 1;

export interface Report {
  version: typeof REPORT_VERSION;
  kind: "scenario";
  scenario: ScenarioName;
  description: string;
  generatedAt: string;
  chainId: number;
  hook: Address;
  poolId: Hex;
  owner: Address;
  routers: Partial<Record<Role, Address>>;
  sizing: Sizing;
  calls: PlannedCall[];
  steps: StepOutcome[];
  pre: StateSnapshot;
  post: StateSnapshot;
  expectations: ExpectationResult[];
  pass: boolean;
  needsRetry: boolean;
  notes: string[];
}

export interface PlannedTx {
  index: number;
  phase: PlannedCall["phase"];
  role: Role;
  router: Address | "not deployed yet";
  function: string;
  args: Record<string, unknown>;
  value: bigint;
  label: string;
}

export interface PlanFile {
  version: typeof REPORT_VERSION;
  kind: "plan";
  generatedAt: string;
  mode: "offline" | "online";
  chainId: number;
  hook: Address;
  poolId: Hex;
  owner: Address | "unset";
  snapshot: { liquidity: bigint; sqrtPriceX96: bigint; lpFeePips: number };
  sizing: Sizing;
  minBond: bigint;
  scenarios: Array<{
    name: ScenarioName;
    description: string;
    roles: Role[];
    txs: PlannedTx[];
    expectations: Array<{ id: string; description: string }>;
  }>;
  totals: { txCount: number; ethIn: bigint; usdcIn: bigint; bonds: bigint };
  notes: string[];
}

/** JSON with bigints as decimal strings. Stable key order is the insertion order. */
export function serialize(value: unknown): string {
  return JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n";
}

export function timestampSlug(date: Date = new Date()): string {
  return date.toISOString().replace(/[:.]/g, "-");
}

export function reportFileName(scenario: string, date: Date = new Date()): string {
  return `${timestampSlug(date)}-${scenario}.json`;
}

export function buildReport(input: {
  plan: ScenarioPlan;
  outcome: Outcome;
  expectations: ExpectationResult[];
  chainId: number;
  hook: Address;
  poolId: Hex;
  sizing: Sizing;
  notes?: string[];
  now?: Date;
}): Report {
  const pass = input.expectations.every((e) => e.pass);
  const needsRetry = input.expectations.some((e) => e.id === "same-block" && !e.pass);
  return {
    version: REPORT_VERSION,
    kind: "scenario",
    scenario: input.plan.name,
    description: input.plan.description,
    generatedAt: (input.now ?? new Date()).toISOString(),
    chainId: input.chainId,
    hook: input.hook,
    poolId: input.poolId,
    owner: input.outcome.owner,
    routers: input.outcome.routers,
    sizing: input.sizing,
    calls: input.plan.calls,
    steps: input.outcome.steps,
    pre: input.outcome.pre,
    post: input.outcome.post,
    expectations: input.expectations,
    pass,
    needsRetry,
    notes: input.notes ?? [],
  };
}

export function writeJson(dir: string, fileName: string, value: unknown): string {
  mkdirSync(dir, { recursive: true });
  const path = join(dir, fileName);
  writeFileSync(path, serialize(value));
  return path;
}

export function plannedTx(index: number, call: PlannedCall, router: Address | undefined): PlannedTx {
  const base = { index, phase: call.phase, role: call.role, router: router ?? ("not deployed yet" as const), label: call.label };
  if (call.kind === "bond") {
    return { ...base, function: "bond(hook,uint256)", args: { amount: call.amount }, value: 0n };
  }
  return {
    ...base,
    function: "swap(PoolKey,SwapParams,bytes)",
    args: {
      zeroForOne: call.zeroForOne,
      amountSpecified: call.amountSpecified,
      sqrtPriceLimitX96: call.sqrtPriceLimitX96,
      hookData: call.hookData,
    },
    value: call.value,
  };
}

export function planTotals(plans: ScenarioPlan[]): PlanFile["totals"] {
  let txCount = 0;
  let ethIn = 0n;
  let usdcIn = 0n;
  let bonds = 0n;
  for (const p of plans) {
    for (const c of p.calls) {
      txCount += 1;
      if (c.kind === "bond") bonds += c.amount;
      else if (c.zeroForOne) ethIn += -c.amountSpecified;
      else usdcIn += -c.amountSpecified;
    }
  }
  return { txCount, ethIn, usdcIn, bonds };
}

export function summarize(results: ExpectationResult[]): string {
  return results.map((r) => `  [${r.pass ? "PASS" : "FAIL"}] ${r.id}: ${r.description} (${r.detail})`).join("\n");
}
