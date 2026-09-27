import { describe, expect, it } from "vitest";
import type { Address, PublicClient } from "viem";
import { hookAbi } from "../src/abi.js";
import { silentLogger } from "../src/log.js";
import { backfill, startWatch, toFlagEvent, type FlagEvent } from "../src/watch.js";

const HOOK = "0x6d6201097d6549F9760d61019E69E599315dc0C0" as Address;
const A = "0x00000000000000000000000000000000000000aa" as Address;
const B = "0x00000000000000000000000000000000000000bb" as Address;

type Range = { from: bigint; to: bigint };

function fakeClient(opts: { head: () => bigint; logsAt?: Record<string, unknown[]>; failRanges?: number; failHead?: () => boolean }) {
  const ranges: Range[] = [];
  let failures = 0;
  const client = {
    async getBlockNumber() {
      if (opts.failHead?.()) throw new Error("head down");
      return opts.head();
    },
    async getLogs(p: { fromBlock: bigint; toBlock: bigint; events: unknown[]; address: Address; strict: boolean }) {
      expect(p.address).toBe(HOOK);
      expect(p.strict).toBe(true);
      expect(p.events.map((e) => (e as { name: string }).name)).toEqual(["Sandwiched", "Flagged"]);
      if (failures < (opts.failRanges ?? 0)) {
        failures++;
        throw new Error("logs down");
      }
      ranges.push({ from: p.fromBlock, to: p.toBlock });
      const out: unknown[] = [];
      for (let b = p.fromBlock; b <= p.toBlock; b++) out.push(...(opts.logsAt?.[b.toString()] ?? []));
      return out;
    },
  };
  return { client: client as unknown as PublicClient, ranges };
}

const sandwiched = (block: bigint, searcher: Address, until: bigint) => ({
  eventName: "Sandwiched",
  blockNumber: block,
  args: { poolId: "0x", searcher, slashed: 1n, isRepeat: false, remaining: 0n, flaggedUntil: until, refunded: 0n },
});
const flagged = (block: bigint, searcher: Address, until: bigint) => ({
  eventName: "Flagged",
  blockNumber: block,
  args: { searcher, poolId: "0x", slashed: 1n, evidenceHash: "0x", flaggedUntil: until },
});

describe("toFlagEvent", () => {
  it("keeps only searcher, flaggedUntil, block and event name from either event", () => {
    expect(toFlagEvent(sandwiched(5n, A, 50n) as never)).toEqual({ searcher: A, flaggedUntil: 50n, blockNumber: 5n, event: "Sandwiched" });
    expect(toFlagEvent(flagged(6n, B, 60n) as never)).toEqual({ searcher: B, flaggedUntil: 60n, blockNumber: 6n, event: "Flagged" });
  });
});

describe("backfill", () => {
  it("scans in bounded inclusive ranges and reports progress after each", async () => {
    const { client, ranges } = fakeClient({ head: () => 0n, logsAt: { "100": [sandwiched(100n, A, 500n)], "4321": [flagged(4321n, B, 9000n)] } });
    const flags: FlagEvent[] = [];
    const progress: bigint[] = [];
    const end = await backfill({ client, hook: HOOK, abi: hookAbi, fromBlock: 100n, toBlock: 4500n, step: 2000n, onFlag: (e) => flags.push(e), onProgress: (t) => void progress.push(t), log: silentLogger });
    expect(ranges).toEqual([
      { from: 100n, to: 2099n },
      { from: 2100n, to: 4099n },
      { from: 4100n, to: 4500n },
    ]);
    expect(progress).toEqual([2099n, 4099n, 4500n]);
    expect(flags.map((f) => [f.searcher, f.flaggedUntil])).toEqual([[A, 500n], [B, 9000n]]);
    expect(end).toBe(4500n);
  });

  it("is a no-op when fromBlock is past toBlock", async () => {
    const { client, ranges } = fakeClient({ head: () => 0n });
    expect(await backfill({ client, hook: HOOK, abi: hookAbi, fromBlock: 11n, toBlock: 10n, step: 2000n, onFlag: () => {}, log: silentLogger })).toBe(10n);
    expect(ranges).toEqual([]);
  });

  it("retries a failed range and gives up after the retry budget", async () => {
    const ok = fakeClient({ head: () => 0n, failRanges: 2 });
    await backfill({ client: ok.client, hook: HOOK, abi: hookAbi, fromBlock: 1n, toBlock: 10n, step: 100n, onFlag: () => {}, log: silentLogger, retries: 2, retryDelayMs: 1 });
    expect(ok.ranges).toEqual([{ from: 1n, to: 10n }]);

    const bad = fakeClient({ head: () => 0n, failRanges: 3 });
    await expect(
      backfill({ client: bad.client, hook: HOOK, abi: hookAbi, fromBlock: 1n, toBlock: 10n, step: 100n, onFlag: () => {}, log: silentLogger, retries: 2, retryDelayMs: 1 }),
    ).rejects.toThrow("logs down");
  });
});

const until = (cond: () => boolean, ms = 500) =>
  new Promise<void>((resolve, reject) => {
    const started = Date.now();
    const t = setInterval(() => {
      if (cond()) {
        clearInterval(t);
        resolve();
      } else if (Date.now() - started > ms) {
        clearInterval(t);
        reject(new Error("timeout"));
      }
    }, 2);
  });

describe("startWatch", () => {
  it("covers every new block exactly once, in step-bounded ranges, and reports coverage", async () => {
    let head = 105n;
    const { client, ranges } = fakeClient({ head: () => head, logsAt: { "103": [flagged(103n, A, 900n)], "110": [sandwiched(110n, B, 950n)] } });
    const flags: FlagEvent[] = [];
    const covered: bigint[] = [];
    const heads = new Set<bigint>();
    const w = startWatch({ client, hook: HOOK, abi: hookAbi, fromBlock: 101n, pollingIntervalMs: 1, step: 3n, onFlag: (e) => flags.push(e), onHead: (h) => void heads.add(h), onCovered: (t) => void covered.push(t), onError: () => {}, log: silentLogger });
    try {
      await until(() => covered.at(-1) === 105n);
      head = 111n;
      await until(() => covered.at(-1) === 111n);
    } finally {
      await w.stop();
    }
    expect([...heads]).toEqual([105n, 111n]);
    expect(ranges).toEqual([
      { from: 101n, to: 103n },
      { from: 104n, to: 105n },
      { from: 106n, to: 108n },
      { from: 109n, to: 111n },
    ]);
    expect(covered).toEqual([103n, 105n, 108n, 111n]);
    expect(flags.map((f) => [f.searcher, f.blockNumber])).toEqual([[A, 103n], [B, 110n]]);
  });

  it("does not advance coverage past a failed poll and retries the same range", async () => {
    const { client, ranges } = fakeClient({ head: () => 120n, failRanges: 2 });
    const errors: unknown[] = [];
    const covered: bigint[] = [];
    const w = startWatch({ client, hook: HOOK, abi: hookAbi, fromBlock: 118n, pollingIntervalMs: 1, step: 100n, onFlag: () => {}, onCovered: (t) => void covered.push(t), onError: (e) => errors.push(e), log: silentLogger });
    try {
      await until(() => covered.length === 1);
    } finally {
      await w.stop();
    }
    expect(errors).toHaveLength(2);
    expect(ranges).toEqual([{ from: 118n, to: 120n }]);
    expect(covered).toEqual([120n]);
  });

  it("reports the head on every successful poll even when nothing is new", async () => {
    const { client, ranges } = fakeClient({ head: () => 50n });
    const heads: bigint[] = [];
    const w = startWatch({ client, hook: HOOK, abi: hookAbi, fromBlock: 51n, pollingIntervalMs: 1, step: 100n, onFlag: () => {}, onHead: (h) => void heads.push(h), onCovered: () => {}, onError: () => {}, log: silentLogger });
    try {
      await until(() => heads.length >= 3);
    } finally {
      await w.stop();
    }
    expect(heads.every((h) => h === 50n)).toBe(true);
    expect(ranges).toEqual([]);
  });

  it("stops polling after stop() resolves", async () => {
    let polls = 0;
    const { client } = fakeClient({ head: () => BigInt(++polls) });
    const w = startWatch({ client, hook: HOOK, abi: hookAbi, fromBlock: 1n, pollingIntervalMs: 1, step: 100n, onFlag: () => {}, onCovered: () => {}, onError: () => {}, log: silentLogger });
    await until(() => polls >= 3);
    await w.stop();
    const after = polls;
    await new Promise((r) => setTimeout(r, 20));
    expect(polls).toBe(after);
  });
});
