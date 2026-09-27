import { describe, expect, it } from "vitest";
import {
  type PoolRow,
  type RefundRow,
  blockPriceFromCheckpointed,
  blockPriceFromSwap,
  bondAfterBonded,
  bondAfterFlagged,
  bondAfterSandwiched,
  bondAfterWithdrawn,
  emptyBond,
  eventId,
  mapCheckpointed,
  mapClampWithheld,
  mapCoverageClaimed,
  mapFlagged,
  mapPoolRegistered,
  mapSandwiched,
  mapSwap,
  mapVictimRefundCredited,
  mapWithheldFlushed,
  poolAfterCheckpointed,
  poolAfterClampWithheld,
  poolAfterCoverageClaimed,
  poolAfterFlagged,
  poolAfterRefundCredited,
  poolAfterSandwiched,
  poolAfterUnclaimedSwept,
  poolAfterWithheldFlushed,
  poolBlockId,
  settleRefunds,
} from "../src/mappers";
import { CURRENCY0, CURRENCY1, OPERATOR, POOL, POOL_UPPER, SEARCHER, SEARCHER_LC, TX, TX2, VICTIM, VICTIM_LC, meta } from "./fixtures";

const key = { currency0: CURRENCY0, currency1: CURRENCY1, fee: 3000, tickSpacing: 10, hooks: OPERATOR };
const cfg = { clampEnabled: true, exemptFirstSwapOnly: false, requireVictimLoss: true, baseFee: 3000, feeDiscountBps: 500 };

const registeredPool = (): PoolRow => mapPoolRegistered({ poolId: POOL_UPPER, operator: OPERATOR, cfg }, key, meta(), 1301);

describe("ids", () => {
  it("eventId is txHash-logIndex", () => {
    expect(eventId(meta({ logIndex: 3 }))).toBe(`${TX}-3`);
  });
  it("poolBlockId lower-cases the pool id", () => {
    expect(poolBlockId(POOL_UPPER, 5n)).toBe(`${POOL}-5`);
  });
});

describe("PoolRegistered", () => {
  it("builds a zeroed pool row with lower-cased hex", () => {
    const row = registeredPool();
    expect(row).toEqual({
      id: POOL,
      chainId: 1301,
      currency0: CURRENCY0,
      currency1: CURRENCY1.toLowerCase(),
      fee: 3000,
      tickSpacing: 10,
      operator: OPERATOR.toLowerCase(),
      registeredBlock: 61_600_000n,
      reserve: 0n,
      slashedPledged: 0n,
      withdrawn: 0n,
      sandwiches: 0,
      refundsCredited: 0n,
      refundsClaimed: 0n,
      withheld0: 0n,
      withheld1: 0n,
      lastCheckpointBlock: null,
      lastCheckpointSqrtPrice: null,
      lastCheckpointLiquidity: null,
    });
  });
});

describe("Bonded / BondWithdrawn", () => {
  it("creates a bond row on first bond", () => {
    const b = bondAfterBonded(undefined, { searcher: SEARCHER, amount: 5_000n, depositBlock: 100n }, meta({ block: 100n }));
    expect(b).toEqual({ id: SEARCHER_LC, amount: 5_000n, depositBlock: 100n, strikeCount: 0, bannedUntil: 0n, flaggedUntil: 0n, updatedBlock: 100n });
  });
  it("re-bonding keeps strikes and flags", () => {
    const prev = { ...emptyBond(SEARCHER), strikeCount: 2, flaggedUntil: 900n, bannedUntil: 800n };
    const b = bondAfterBonded(prev, { searcher: SEARCHER, amount: 7n, depositBlock: 950n }, meta({ block: 950n }));
    expect(b.amount).toBe(7n);
    expect(b.depositBlock).toBe(950n);
    expect(b.strikeCount).toBe(2);
    expect(b.flaggedUntil).toBe(900n);
    expect(b.bannedUntil).toBe(800n);
  });
  it("withdraw zeroes the amount and keeps history", () => {
    const prev = { ...emptyBond(SEARCHER), amount: 7n, strikeCount: 1, depositBlock: 10n };
    const b = bondAfterWithdrawn(prev, { searcher: SEARCHER, amount: 7n }, meta({ block: 20n }));
    expect(b).toEqual({ ...prev, amount: 0n, updatedBlock: 20n });
  });
  it("withdraw without a known bond still yields a zero row", () => {
    const b = bondAfterWithdrawn(undefined, { searcher: SEARCHER, amount: 7n }, meta());
    expect(b.amount).toBe(0n);
    expect(b.id).toBe(SEARCHER_LC);
  });
});

describe("Sandwiched", () => {
  const args = { poolId: POOL_UPPER, searcher: SEARCHER, slashed: 1_000n, isRepeat: false, remaining: 4_000n, flaggedUntil: 61_700_000n, refunded: 300n };

  it("maps the slash row", () => {
    expect(mapSandwiched(args, meta())).toEqual({
      id: `${TX}-7`,
      poolId: POOL,
      searcher: SEARCHER_LC,
      slashed: 1_000n,
      isRepeat: false,
      remaining: 4_000n,
      flaggedUntil: 61_700_000n,
      refunded: 300n,
      block: 61_600_000n,
      timestamp: 1_788_500_000n,
      txHash: TX,
    });
  });
  it("credits slashed minus refunded to the pool and counts the sandwich", () => {
    const p = { ...registeredPool(), reserve: 10n, slashedPledged: 10n, sandwiches: 2 };
    expect(poolAfterSandwiched(p, args)).toEqual({ reserve: 710n, slashedPledged: 710n, sandwiches: 3 });
  });
  it("first strike: strikeCount +1, bond = remaining, flag set, no ban", () => {
    const prev = { ...emptyBond(SEARCHER), amount: 5_000n, depositBlock: 1n };
    const b = bondAfterSandwiched(prev, args, meta());
    expect(b.strikeCount).toBe(1);
    expect(b.amount).toBe(4_000n);
    expect(b.flaggedUntil).toBe(61_700_000n);
    expect(b.bannedUntil).toBe(0n);
    expect(b.updatedBlock).toBe(61_600_000n);
  });
  it("repeat strike: banned until flaggedUntil", () => {
    const prev = { ...emptyBond(SEARCHER), amount: 4_000n, strikeCount: 1, flaggedUntil: 61_650_000n };
    const b = bondAfterSandwiched(prev, { ...args, isRepeat: true, remaining: 0n, flaggedUntil: 61_900_000n }, meta());
    expect(b.strikeCount).toBe(2);
    expect(b.amount).toBe(0n);
    expect(b.bannedUntil).toBe(61_900_000n);
    expect(b.flaggedUntil).toBe(61_900_000n);
  });
  it("a slash on an unknown bond row still records the strike", () => {
    const b = bondAfterSandwiched(undefined, args, meta());
    expect(b.strikeCount).toBe(1);
    expect(b.amount).toBe(4_000n);
  });
});

describe("VictimRefundCredited / RefundClaimed / UnclaimedSwept", () => {
  const credited = (id: string, poolId = POOL, amount = 300n): RefundRow => ({
    ...mapVictimRefundCredited({ poolId, victim: VICTIM, searcher: SEARCHER, amount }, meta()),
    id,
  });

  it("maps the refund row as unclaimed", () => {
    expect(mapVictimRefundCredited({ poolId: POOL_UPPER, victim: VICTIM, searcher: SEARCHER, amount: 300n }, meta())).toEqual({
      id: `${TX}-7`,
      poolId: POOL,
      victim: VICTIM_LC,
      searcher: SEARCHER_LC,
      amount: 300n,
      block: 61_600_000n,
      txHash: TX,
      claimedTxHash: null,
      sweptTxHash: null,
    });
  });
  it("adds the credit to the pool counter", () => {
    const p = { ...registeredPool(), refundsCredited: 5n };
    expect(poolAfterRefundCredited(p, { poolId: POOL, victim: VICTIM, searcher: SEARCHER, amount: 300n })).toEqual({ refundsCredited: 305n });
  });
  it("claim marks every open row and sums per pool", () => {
    const otherPool = `0x${"ab".repeat(32)}` as const;
    const open = [credited("a"), credited("b", otherPool, 50n), credited("c", POOL, 20n)];
    const s = settleRefunds(open, TX2, "claimed");
    expect(s.rows.map((r) => r.id)).toEqual(["a", "b", "c"]);
    expect(s.rows.every((r) => r.claimedTxHash === TX2 && r.sweptTxHash === null)).toBe(true);
    expect(s.perPool.get(POOL)).toBe(320n);
    expect(s.perPool.get(otherPool)).toBe(50n);
  });
  it("claim skips rows already claimed or swept", () => {
    const open = [
      { ...credited("a"), claimedTxHash: TX },
      { ...credited("b"), sweptTxHash: TX },
      credited("c"),
    ];
    const s = settleRefunds(open, TX2, "claimed");
    expect(s.rows.map((r) => r.id)).toEqual(["c"]);
    expect(s.perPool.get(POOL)).toBe(300n);
  });
  it("sweep marks rows as swept, not claimed, and credits the target pool", () => {
    const s = settleRefunds([credited("a")], TX2, "swept");
    expect(s.rows[0]!.sweptTxHash).toBe(TX2);
    expect(s.rows[0]!.claimedTxHash).toBeNull();
    const p = { ...registeredPool(), reserve: 1n, slashedPledged: 2n };
    expect(poolAfterUnclaimedSwept(p, { key: VICTIM, to: POOL, amount: 300n })).toEqual({ reserve: 301n, slashedPledged: 302n });
  });
});

describe("Flagged", () => {
  const evidence = `0x${"cd".repeat(32)}` as const;
  const args = { searcher: SEARCHER, poolId: POOL_UPPER, slashed: 0n, evidenceHash: evidence, flaggedUntil: 61_800_000n };

  it("maps the flag row", () => {
    expect(mapFlagged(args, meta())).toEqual({
      id: `${TX}-7`,
      searcher: SEARCHER_LC,
      poolId: POOL,
      slashed: 0n,
      evidenceHash: evidence,
      flaggedUntil: 61_800_000n,
      block: 61_600_000n,
      txHash: TX,
    });
  });
  it("a flag without a slash extends the flag only", () => {
    const prev = { ...emptyBond(SEARCHER), amount: 9n, strikeCount: 1 };
    const b = bondAfterFlagged(prev, args, meta());
    expect(b.strikeCount).toBe(1);
    expect(b.amount).toBe(9n);
    expect(b.flaggedUntil).toBe(61_800_000n);
    expect(poolAfterFlagged(registeredPool(), args)).toEqual({});
  });
  it("a slashing flag is a strike, reduces the bond and credits the whole slash to the reserve", () => {
    const prev = { ...emptyBond(SEARCHER), amount: 9n, strikeCount: 1 };
    const slashing = { ...args, slashed: 4n };
    const b = bondAfterFlagged(prev, slashing, meta());
    expect(b.strikeCount).toBe(2);
    expect(b.amount).toBe(5n);
    const p = { ...registeredPool(), reserve: 1n, slashedPledged: 1n };
    expect(poolAfterFlagged(p, slashing)).toEqual({ reserve: 5n, slashedPledged: 5n });
  });
  it("a flag on an address that never bonded yields a zero bond with the flag", () => {
    const b = bondAfterFlagged(undefined, args, meta());
    expect(b).toEqual({ ...emptyBond(SEARCHER), flaggedUntil: 61_800_000n, updatedBlock: 61_600_000n });
  });
});

describe("CoverageClaimed", () => {
  const args = { poolId: POOL_UPPER, amount: 40n, remainingReserve: 60n };
  it("maps the drain row", () => {
    expect(mapCoverageClaimed(args, meta())).toEqual({ id: `${TX}-7`, poolId: POOL, amount: 40n, remainingReserve: 60n, block: 61_600_000n, txHash: TX });
  });
  it("sets reserve from the event and accumulates withdrawn", () => {
    const p = { ...registeredPool(), reserve: 100n, withdrawn: 10n };
    expect(poolAfterCoverageClaimed(p, args)).toEqual({ reserve: 60n, withdrawn: 50n });
  });
});

describe("Checkpointed", () => {
  const args = { poolId: POOL_UPPER, blockNumber: 61_600_001, sqrtPriceX96: 2n ** 96n, liquidity: 12_345n };
  it("maps the checkpoint row with a poolId-block id", () => {
    expect(mapCheckpointed(args)).toEqual({ id: `${POOL}-61600001`, poolId: POOL, block: 61_600_001n, sqrtPriceX96: 2n ** 96n, liquidity: 12_345n });
  });
  it("updates the pool's last checkpoint", () => {
    expect(poolAfterCheckpointed(args)).toEqual({ lastCheckpointBlock: 61_600_001n, lastCheckpointSqrtPrice: 2n ** 96n, lastCheckpointLiquidity: 12_345n });
  });
  it("opens the block price row with only the start side", () => {
    expect(blockPriceFromCheckpointed(args)).toEqual({ id: `${POOL}-61600001`, poolId: POOL, block: 61_600_001n, startSqrtPriceX96: 2n ** 96n, endSqrtPriceX96: null });
  });
});

describe("ClampWithheld / WithheldFlushed", () => {
  it("maps the withheld row", () => {
    expect(mapClampWithheld({ poolId: POOL_UPPER, sender: SEARCHER, currency: CURRENCY1, amount: 9n }, meta())).toEqual({
      id: `${TX}-7`,
      poolId: POOL,
      sender: SEARCHER_LC,
      currency: CURRENCY1.toLowerCase(),
      amount: 9n,
      block: 61_600_000n,
      txHash: TX,
    });
  });
  it("routes the amount to the matching currency side regardless of case", () => {
    const p = { ...registeredPool(), withheld0: 1n, withheld1: 2n };
    expect(poolAfterClampWithheld(p, { poolId: POOL, sender: SEARCHER, currency: CURRENCY0, amount: 5n })).toEqual({ withheld0: 6n });
    expect(poolAfterClampWithheld(p, { poolId: POOL, sender: SEARCHER, currency: CURRENCY1.toUpperCase().replace("0X", "0x") as `0x${string}`, amount: 5n })).toEqual({ withheld1: 7n });
    expect(poolAfterClampWithheld(p, { poolId: POOL, sender: SEARCHER, currency: OPERATOR, amount: 5n })).toEqual({});
  });
  it("flush maps the row and zeroes both sides", () => {
    expect(mapWithheldFlushed({ poolId: POOL_UPPER, amount0: 6n, amount1: 7n }, meta())).toEqual({ id: `${TX}-7`, poolId: POOL, amount0: 6n, amount1: 7n, block: 61_600_000n, txHash: TX });
    const p = { ...registeredPool(), withheld0: 6n, withheld1: 7n };
    expect(poolAfterWithheldFlushed(p, { poolId: POOL, amount0: 6n, amount1: 7n })).toEqual({ withheld0: 0n, withheld1: 0n });
  });
});

describe("Swap", () => {
  const args = { id: POOL_UPPER, sender: SEARCHER, amount0: -1_000n, amount1: 990n, sqrtPriceX96: 3n * 2n ** 96n, liquidity: 55n, tick: -12, fee: 3000 };
  it("maps the swap row", () => {
    expect(mapSwap(args, meta())).toEqual({
      id: `${TX}-7`,
      poolId: POOL,
      sender: SEARCHER_LC,
      amount0: -1_000n,
      amount1: 990n,
      sqrtPriceX96: 3n * 2n ** 96n,
      liquidity: 55n,
      tick: -12,
      fee: 3000,
      block: 61_600_000n,
      txHash: TX,
    });
  });
  it("closes the block price row with only the end side, keyed by the event block", () => {
    expect(blockPriceFromSwap(args, meta())).toEqual({ id: `${POOL}-61600000`, poolId: POOL, block: 61_600_000n, startSqrtPriceX96: null, endSqrtPriceX96: 3n * 2n ** 96n });
  });
});
