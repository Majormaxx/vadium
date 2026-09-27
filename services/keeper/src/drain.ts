// Drain logic. The pure functions decide what to drain; runDrainTick talks to the
// chain through a small dependency interface so tests can inject fakes.

import type { Address, Hex } from "viem";
import type { Logger } from "./log.js";
import type { Metrics } from "./metrics.js";
import type { KeeperState } from "./state.js";

export interface DrainSelection {
  amount: bigint;
  searchers: Address[];
}

/**
 * Addresses whose flag is still active at `blockNumber`, sorted for determinism.
 * The hook's check is `flaggedUntil(a) > block.number`, so equality means expired.
 */
export function activeFlagged(state: Pick<KeeperState, "flagged">, blockNumber: bigint): Address[] {
  const out: Address[] = [];
  for (const [addr, until] of state.flagged) {
    if (until > blockNumber) out.push(addr);
  }
  return out.sort();
}

/** Returns null when there is nothing worth draining or nobody to attribute the drain to. */
export function selectDrain(p: { reserve: bigint; activeFlagged: readonly Address[]; cap: bigint; min: bigint }): DrainSelection | null {
  if (p.activeFlagged.length === 0) return null;
  if (p.reserve < p.min) return null;
  const amount = p.reserve < p.cap ? p.reserve : p.cap;
  if (amount <= 0n) return null;
  return { amount, searchers: [...p.activeFlagged] };
}

export type ReadCall =
  | { functionName: "paused"; args: readonly [] }
  | { functionName: "insuranceReserve"; args: readonly [Hex] };

export type ReadResult<C extends ReadCall> = C extends { functionName: "paused" } ? boolean : bigint;

export interface DrainCall {
  functionName: "drainFlagged";
  args: readonly [Hex, readonly Address[], bigint];
}

/** Everything runDrainTick needs from the outside world. `R` is the opaque simulated request handed back to writeContract. */
export interface DrainDeps<R = unknown> {
  getBlockNumber(): Promise<bigint>;
  readContract<C extends ReadCall>(call: C): Promise<ReadResult<C>>;
  simulateContract(call: DrainCall): Promise<{ request: R; result: bigint }>;
  writeContract(request: R): Promise<Hex>;
  log: Logger;
}

export interface DrainContext {
  poolIds: readonly Hex[];
  cap: bigint;
  min: bigint;
  state: Pick<KeeperState, "flagged">;
  metrics: Metrics;
  /**
   * A flag that expires within this many blocks of the tick is left out, so a
   * transaction mined a few blocks after simulation cannot revert with NotFlagged.
   */
  safetyBlocks?: bigint;
}

export const DEFAULT_SAFETY_BLOCKS = 3n;

export interface DrainRecord {
  poolId: Hex;
  amount: bigint;
  searchers: Address[];
  hash: Hex;
}

export interface DrainTickResult {
  blockNumber: bigint | null;
  paused: boolean;
  activeFlagged: number;
  drains: DrainRecord[];
  errors: number;
}

/** One drain pass over every configured pool. Never throws; failures are logged and counted. */
export async function runDrainTick<R>(deps: DrainDeps<R>, ctx: DrainContext): Promise<DrainTickResult> {
  const { metrics, log } = { metrics: ctx.metrics, log: deps.log };
  const result: DrainTickResult = { blockNumber: null, paused: false, activeFlagged: 0, drains: [], errors: 0 };

  let blockNumber: bigint;
  try {
    blockNumber = await deps.getBlockNumber();
  } catch (err) {
    result.errors++;
    metrics.incRpcErrors();
    log.error("drain tick: getBlockNumber failed", { error: err });
    return result;
  }
  result.blockNumber = blockNumber;

  let paused: boolean;
  try {
    paused = await deps.readContract({ functionName: "paused", args: [] });
  } catch (err) {
    result.errors++;
    metrics.incRpcErrors();
    log.error("drain tick: paused() failed", { error: err, blockNumber });
    return result;
  }
  metrics.setPaused(paused);
  result.paused = paused;
  if (paused) {
    log.warn("hook is paused, skipping drain tick", { blockNumber });
    return result;
  }

  const safety = ctx.safetyBlocks ?? DEFAULT_SAFETY_BLOCKS;
  const active = activeFlagged(ctx.state, blockNumber + safety);
  result.activeFlagged = active.length;

  for (const poolId of ctx.poolIds) {
    let reserve: bigint;
    try {
      reserve = await deps.readContract({ functionName: "insuranceReserve", args: [poolId] });
    } catch (err) {
      result.errors++;
      metrics.incRpcErrors();
      log.error("drain tick: insuranceReserve() failed", { error: err, poolId, blockNumber });
      continue;
    }
    metrics.setReserve(poolId, reserve);
    metrics.setFlaggedActive(poolId, active.length);

    const sel = selectDrain({ reserve, activeFlagged: active, cap: ctx.cap, min: ctx.min });
    if (!sel) {
      log.info("nothing to drain", { poolId, blockNumber, reserve, activeFlagged: active.length, min: ctx.min });
      continue;
    }

    try {
      const sim = await deps.simulateContract({ functionName: "drainFlagged", args: [poolId, sel.searchers, sel.amount] });
      const hash = await deps.writeContract(sim.request);
      metrics.recordDrain(poolId, sim.result, blockNumber, hash);
      result.drains.push({ poolId, amount: sim.result, searchers: sel.searchers, hash });
      log.info("drain submitted", { poolId, blockNumber, hash, amount: sim.result, requested: sel.amount, reserve, searchers: sel.searchers });
    } catch (err) {
      result.errors++;
      metrics.incRpcErrors();
      metrics.incDrainErrors();
      log.error("drain failed", { error: err, poolId, blockNumber, reserve, requested: sel.amount, searchers: sel.searchers });
    }
  }
  return result;
}
