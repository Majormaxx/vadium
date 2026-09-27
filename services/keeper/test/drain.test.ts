import { describe, expect, it } from "vitest";
import type { Address, Hex } from "viem";
import { activeFlagged, runDrainTick, selectDrain, type DrainDeps, type ReadCall, type ReadResult } from "../src/drain.js";
import { silentLogger } from "../src/log.js";
import { Metrics } from "../src/metrics.js";

const A = "0x00000000000000000000000000000000000000aa" as Address;
const B = "0x00000000000000000000000000000000000000bb" as Address;
const C = "0x00000000000000000000000000000000000000cc" as Address;
const POOL = "0x8e04e9c3fd9137cdc79ef352d1b1af9c5b3c5384cca2d8641c754bd6a2000304" as Hex;
const POOL2 = "0x1111111111111111111111111111111111111111111111111111111111111111" as Hex;
const HASH = "0xabcdef0000000000000000000000000000000000000000000000000000000001" as Hex;

describe("selectDrain", () => {
  const base = { activeFlagged: [A, B], cap: 1_000_000_000n, min: 1_000_000n };

  it("returns null when the reserve is below min", () => {
    expect(selectDrain({ ...base, reserve: 999_999n })).toBeNull();
  });

  it("returns null when nobody is actively flagged", () => {
    expect(selectDrain({ ...base, activeFlagged: [], reserve: 5_000_000_000n })).toBeNull();
  });

  it("caps the amount at cap when the reserve is larger", () => {
    expect(selectDrain({ ...base, reserve: 5_000_000_000n })).toEqual({ amount: 1_000_000_000n, searchers: [A, B] });
  });

  it("drains the whole reserve when it is smaller than cap", () => {
    expect(selectDrain({ ...base, reserve: 250_000_000n })).toEqual({ amount: 250_000_000n, searchers: [A, B] });
  });

  it("drains exactly min when reserve equals min", () => {
    expect(selectDrain({ ...base, reserve: 1_000_000n })).toEqual({ amount: 1_000_000n, searchers: [A, B] });
  });

  it("copies the searcher list instead of aliasing it", () => {
    const active = [A];
    const sel = selectDrain({ ...base, activeFlagged: active, reserve: 5_000_000n })!;
    sel.searchers.push(B);
    expect(active).toEqual([A]);
  });
});

describe("activeFlagged", () => {
  const state = { flagged: new Map<Address, bigint>([[B, 100n], [A, 200n], [C, 150n]]) };

  it("keeps only flags with flaggedUntil strictly greater than the block", () => {
    expect(activeFlagged(state, 99n)).toEqual([A, B, C]);
    expect(activeFlagged(state, 100n)).toEqual([A, C]);
    expect(activeFlagged(state, 150n)).toEqual([A]);
    expect(activeFlagged(state, 200n)).toEqual([]);
  });

  it("returns addresses in sorted order regardless of insertion order", () => {
    expect(activeFlagged(state, 0n)).toEqual([A, B, C]);
  });

  it("handles an empty map", () => {
    expect(activeFlagged({ flagged: new Map() }, 5n)).toEqual([]);
  });
});

interface FakeOptions {
  block?: bigint;
  paused?: boolean;
  reserves?: Partial<Record<Hex, bigint>>;
  simulatedResult?: bigint;
  failGetBlockNumber?: boolean;
  failReserveRead?: boolean;
  failSimulate?: boolean;
  failWrite?: boolean;
}

function fakeDeps(o: FakeOptions = {}) {
  const calls: string[] = [];
  const simulated: { functionName: string; args: readonly unknown[] }[] = [];
  const written: unknown[] = [];
  const deps: DrainDeps<{ tag: string }> = {
    async getBlockNumber() {
      calls.push("getBlockNumber");
      if (o.failGetBlockNumber) throw new Error("rpc down");
      return o.block ?? 1000n;
    },
    async readContract<Call extends ReadCall>(call: Call): Promise<ReadResult<Call>> {
      calls.push(call.functionName);
      if (call.functionName === "paused") return (o.paused ?? false) as ReadResult<Call>;
      if (o.failReserveRead) throw new Error("rpc down");
      return (o.reserves?.[call.args[0]] ?? 0n) as ReadResult<Call>;
    },
    async simulateContract(call) {
      calls.push("simulateContract");
      simulated.push(call);
      if (o.failSimulate) throw new Error("execution reverted: NotFlagged()");
      return { request: { tag: `req-${simulated.length}` }, result: o.simulatedResult ?? call.args[2] };
    },
    async writeContract(request) {
      calls.push("writeContract");
      written.push(request);
      if (o.failWrite) throw new Error("nonce too low");
      return HASH;
    },
    log: silentLogger,
  };
  return { deps, calls, simulated, written };
}

function ctx(metrics: Metrics, flagged: [Address, bigint][], poolIds: Hex[] = [POOL]) {
  return { poolIds, cap: 1_000_000_000n, min: 1_000_000n, state: { flagged: new Map(flagged) }, metrics };
}

describe("runDrainTick", () => {
  it("simulates before writing and records the tx hash and counters", async () => {
    const metrics = new Metrics([POOL]);
    const f = fakeDeps({ block: 1000n, reserves: { [POOL]: 5_000_000_000n } });
    const res = await runDrainTick(f.deps, ctx(metrics, [[A, 2000n], [B, 3000n]]));

    expect(f.calls).toEqual(["getBlockNumber", "paused", "insuranceReserve", "simulateContract", "writeContract"]);
    expect(f.simulated).toEqual([{ functionName: "drainFlagged", args: [POOL, [A, B], 1_000_000_000n] }]);
    expect(f.written).toEqual([{ tag: "req-1" }]);
    expect(res.errors).toBe(0);
    expect(res.paused).toBe(false);
    expect(res.blockNumber).toBe(1000n);
    expect(res.activeFlagged).toBe(2);
    expect(res.drains).toEqual([{ poolId: POOL, amount: 1_000_000_000n, searchers: [A, B], hash: HASH }]);
    expect(metrics.drainsTotal).toBe(1);
    expect(metrics.drainedTotal.get(POOL)).toBe(1_000_000_000n);
    expect(metrics.lastDrainBlock).toBe(1000n);
    expect(metrics.lastDrainHash).toBe(HASH);
    expect(metrics.reserve.get(POOL)).toBe(5_000_000_000n);
    expect(metrics.flaggedActive.get(POOL)).toBe(2);
    expect(metrics.rpcErrorsTotal).toBe(0);
    expect(metrics.drainErrorsTotal).toBe(0);
  });

  it("uses the simulated payout as the drained amount when the hook pays out less than requested", async () => {
    const metrics = new Metrics([POOL]);
    const f = fakeDeps({ reserves: { [POOL]: 5_000_000n }, simulatedResult: 4_000_000n });
    const res = await runDrainTick(f.deps, ctx(metrics, [[A, 2000n]]));
    expect(res.drains[0]?.amount).toBe(4_000_000n);
    expect(metrics.drainedTotal.get(POOL)).toBe(4_000_000n);
  });

  it("skips everything while the hook is paused", async () => {
    const metrics = new Metrics([POOL]);
    const f = fakeDeps({ paused: true, reserves: { [POOL]: 5_000_000_000n } });
    const res = await runDrainTick(f.deps, ctx(metrics, [[A, 2000n]]));
    expect(f.calls).toEqual(["getBlockNumber", "paused"]);
    expect(res.paused).toBe(true);
    expect(res.drains).toEqual([]);
    expect(metrics.paused).toBe(true);
    expect(metrics.drainsTotal).toBe(0);
  });

  it("clears the paused gauge once the hook is unpaused again", async () => {
    const metrics = new Metrics([POOL]);
    await runDrainTick(fakeDeps({ paused: true }).deps, ctx(metrics, []));
    expect(metrics.paused).toBe(true);
    await runDrainTick(fakeDeps({ paused: false }).deps, ctx(metrics, []));
    expect(metrics.paused).toBe(false);
  });

  it("skips when no flag is active, even with a large reserve", async () => {
    const metrics = new Metrics([POOL]);
    const f = fakeDeps({ block: 1000n, reserves: { [POOL]: 5_000_000_000n } });
    const res = await runDrainTick(f.deps, ctx(metrics, [[A, 1000n], [B, 500n]]));
    expect(f.calls).toEqual(["getBlockNumber", "paused", "insuranceReserve"]);
    expect(res.drains).toEqual([]);
    expect(res.activeFlagged).toBe(0);
    expect(metrics.reserve.get(POOL)).toBe(5_000_000_000n);
    expect(metrics.flaggedActive.get(POOL)).toBe(0);
  });

  it("skips when the reserve is below min", async () => {
    const metrics = new Metrics([POOL]);
    const f = fakeDeps({ reserves: { [POOL]: 999_999n } });
    const res = await runDrainTick(f.deps, ctx(metrics, [[A, 5000n]]));
    expect(f.calls).toEqual(["getBlockNumber", "paused", "insuranceReserve"]);
    expect(res.drains).toEqual([]);
  });

  it("leaves out flags that expire inside the safety window", async () => {
    const metrics = new Metrics([POOL]);
    const f = fakeDeps({ block: 1000n, reserves: { [POOL]: 5_000_000n } });
    // Default safety is 3 blocks: a flag good through block 1003 is treated as expired at tick 1000.
    await runDrainTick(f.deps, ctx(metrics, [[A, 1003n], [B, 1004n]]));
    expect(f.simulated[0]?.args[1]).toEqual([B]);
  });

  it("counts a failed reserve read as an rpc error without throwing and continues to the next pool", async () => {
    const metrics = new Metrics([POOL, POOL2]);
    let n = 0;
    const f = fakeDeps({ reserves: { [POOL2]: 5_000_000n } });
    const flaky = {
      ...f.deps,
      readContract: async <Call extends ReadCall>(call: Call): Promise<ReadResult<Call>> => {
        if (call.functionName === "insuranceReserve" && n++ === 0) throw new Error("rpc down");
        return f.deps.readContract(call);
      },
    };
    const res = await runDrainTick(flaky, ctx(metrics, [[A, 5000n]], [POOL, POOL2]));
    expect(res.errors).toBe(1);
    expect(metrics.rpcErrorsTotal).toBe(1);
    expect(metrics.drainErrorsTotal).toBe(0);
    expect(res.drains.map((d) => d.poolId)).toEqual([POOL2]);
  });

  it("counts a failed getBlockNumber and returns early", async () => {
    const metrics = new Metrics([POOL]);
    const f = fakeDeps({ failGetBlockNumber: true });
    const res = await runDrainTick(f.deps, ctx(metrics, [[A, 5000n]]));
    expect(res.blockNumber).toBeNull();
    expect(res.errors).toBe(1);
    expect(metrics.rpcErrorsTotal).toBe(1);
    expect(f.calls).toEqual(["getBlockNumber"]);
  });

  it("counts a reverted simulation as a drain error and does not write", async () => {
    const metrics = new Metrics([POOL]);
    const f = fakeDeps({ reserves: { [POOL]: 5_000_000n }, failSimulate: true });
    const res = await runDrainTick(f.deps, ctx(metrics, [[A, 5000n]]));
    expect(f.calls).toEqual(["getBlockNumber", "paused", "insuranceReserve", "simulateContract"]);
    expect(res.errors).toBe(1);
    expect(metrics.rpcErrorsTotal).toBe(1);
    expect(metrics.drainErrorsTotal).toBe(1);
    expect(metrics.drainsTotal).toBe(0);
  });

  it("counts a failed write as a drain error", async () => {
    const metrics = new Metrics([POOL]);
    const f = fakeDeps({ reserves: { [POOL]: 5_000_000n }, failWrite: true });
    const res = await runDrainTick(f.deps, ctx(metrics, [[A, 5000n]]));
    expect(res.errors).toBe(1);
    expect(metrics.drainErrorsTotal).toBe(1);
    expect(metrics.drainsTotal).toBe(0);
    expect(metrics.lastDrainHash).toBeNull();
  });

  it("drains each configured pool independently", async () => {
    const metrics = new Metrics([POOL, POOL2]);
    const f = fakeDeps({ reserves: { [POOL]: 2_000_000n, [POOL2]: 500_000n } });
    const res = await runDrainTick(f.deps, ctx(metrics, [[A, 5000n]], [POOL, POOL2]));
    expect(res.drains.map((d) => [d.poolId, d.amount])).toEqual([[POOL, 2_000_000n]]);
    expect(metrics.reserve.get(POOL2)).toBe(500_000n);
    expect(metrics.drainsTotal).toBe(1);
  });
});
