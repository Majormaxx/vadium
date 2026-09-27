import { describe, expect, it } from "vitest";
import { parseLimit, toBond, toPoolSummary, toRefund, toSlash } from "../src/api/dto";
import { emptyBond, mapPoolRegistered, mapSandwiched, mapVictimRefundCredited } from "../src/mappers";
import { CURRENCY0, CURRENCY1, OPERATOR, POOL, SEARCHER, SEARCHER_LC, TX, VICTIM, meta } from "./fixtures";

const key = { currency0: CURRENCY0, currency1: CURRENCY1, fee: 3000, tickSpacing: 10, hooks: OPERATOR };
const cfg = { clampEnabled: true, exemptFirstSwapOnly: false, requireVictimLoss: true, baseFee: 3000, feeDiscountBps: 0 };

describe("toPoolSummary", () => {
  it("stringifies uint256 fields and nulls a missing checkpoint", () => {
    const row = { ...mapPoolRegistered({ poolId: POOL, operator: OPERATOR, cfg }, key, meta(), 1301), reserve: 2n ** 200n };
    const s = toPoolSummary(row, 3);
    expect(s.reserve).toBe((2n ** 200n).toString());
    expect(s.lastCheckpoint).toBeNull();
    expect(s.bondedCount).toBe(3);
    expect(s.poolId).toBe(POOL);
    expect(JSON.stringify(s)).not.toContain("undefined");
  });
  it("renders the checkpoint with a numeric block", () => {
    const row = {
      ...mapPoolRegistered({ poolId: POOL, operator: OPERATOR, cfg }, key, meta(), 1301),
      lastCheckpointBlock: 61_600_001n,
      lastCheckpointSqrtPrice: 2n ** 96n,
      lastCheckpointLiquidity: 5n,
    };
    expect(toPoolSummary(row, 0).lastCheckpoint).toEqual({ blockNumber: 61_600_001, sqrtPriceX96: (2n ** 96n).toString(), liquidity: "5" });
  });
});

describe("row DTOs", () => {
  it("slash", () => {
    const row = mapSandwiched({ poolId: POOL, searcher: SEARCHER, slashed: 1n, isRepeat: true, remaining: 2n, flaggedUntil: 3n, refunded: 4n }, meta());
    expect(toSlash(row)).toEqual({ txHash: TX, blockNumber: 61_600_000, timestamp: 1_788_500_000, searcher: SEARCHER_LC, slashed: "1", isRepeat: true, remaining: "2", flaggedUntil: "3", refunded: "4" });
  });
  it("refund claimed flag follows claimedTxHash only", () => {
    const row = mapVictimRefundCredited({ poolId: POOL, victim: VICTIM, searcher: SEARCHER, amount: 9n }, meta());
    expect(toRefund(row).claimed).toBe(false);
    expect(toRefund({ ...row, sweptTxHash: TX }).claimed).toBe(false);
    expect(toRefund({ ...row, claimedTxHash: TX }).claimed).toBe(true);
  });
  it("bond", () => {
    expect(toBond({ ...emptyBond(SEARCHER), amount: 10n, depositBlock: 1n, strikeCount: 2, bannedUntil: 3n, flaggedUntil: 4n })).toEqual({
      searcher: SEARCHER_LC,
      amount: "10",
      depositBlock: "1",
      strikeCount: 2,
      bannedUntil: "3",
      flaggedUntil: "4",
    });
  });
});

describe("parseLimit", () => {
  it("defaults on missing or junk and caps at max", () => {
    expect(parseLimit(undefined, 50, 500)).toBe(50);
    expect(parseLimit("abc", 50, 500)).toBe(50);
    expect(parseLimit("0", 50, 500)).toBe(50);
    expect(parseLimit("-3", 50, 500)).toBe(50);
    expect(parseLimit("2.5", 50, 500)).toBe(50);
    expect(parseLimit("20", 50, 500)).toBe(20);
    expect(parseLimit("9999", 50, 500)).toBe(500);
  });
});
