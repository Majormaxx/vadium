import { describe, expect, it } from "vitest";

import {
  BudgetTooSmallError,
  MIN_LEG,
  Q96,
  ZeroLiquidityError,
  estimateOut,
  sizeLegs,
  toCurrency0,
  virtualReserves,
} from "../src/sizing.js";

const oneToOne = { sqrtPriceX96: Q96, lpFeePips: 3000 };
const bigBudget = { usdc: 10n ** 12n, ethWei: 10n ** 24n };
const legs = { eth: 2, usdc: 1 };

describe("virtualReserves", () => {
  it("equals liquidity on both sides at a 1:1 price", () => {
    const r = virtualReserves({ liquidity: 1_000_000n, ...oneToOne });
    expect(r).toEqual({ reserve0: 1_000_000n, reserve1: 1_000_000n });
  });

  it("splits by price", () => {
    // sqrtP = 2 * Q96 -> price 4: reserve0 = L/2, reserve1 = 2L
    const r = virtualReserves({ liquidity: 1_000_000n, sqrtPriceX96: 2n * Q96, lpFeePips: 3000 });
    expect(r).toEqual({ reserve0: 500_000n, reserve1: 2_000_000n });
  });

  it("rejects zero liquidity with the seeding hint", () => {
    expect(() => virtualReserves({ liquidity: 0n, ...oneToOne })).toThrow(ZeroLiquidityError);
    expect(() => virtualReserves({ liquidity: 0n, ...oneToOne })).toThrow(/make add-liquidity/);
  });
});

describe("sizeLegs", () => {
  it("moves the configured fraction of the reserve", () => {
    const s = sizeLegs({ liquidity: 1_000_000n, ...oneToOne }, bigBudget, 500, legs);
    expect(s.ethLeg).toBe(50_000n);
    expect(s.usdcLeg).toBe(50_000n);
    expect(s.reverseUsdcLeg).toBe(estimateOut(50_000n, 1_000_000n, 1_000_000n, 3000));
    expect(s.reverseUsdcLeg).toBeLessThan(50_000n);
    expect(s.reverseUsdcLeg).toBeGreaterThan(0n);
  });

  it("scales linearly with liquidity", () => {
    const a = sizeLegs({ liquidity: 1_000_000n, ...oneToOne }, bigBudget, 500, legs);
    const b = sizeLegs({ liquidity: 10_000_000n, ...oneToOne }, bigBudget, 500, legs);
    expect(b.ethLeg).toBe(a.ethLeg * 10n);
    expect(b.usdcLeg).toBe(a.usdcLeg * 10n);
  });

  it("never lets the legs exceed the budget", () => {
    const budget = { usdc: 30_000n, ethWei: 40_000n };
    const s = sizeLegs({ liquidity: 10n ** 12n, ...oneToOne }, budget, 500, { eth: 4, usdc: 3 });
    expect(s.ethLeg * 4n).toBeLessThanOrEqual(budget.ethWei);
    expect(s.usdcLeg * 3n).toBeLessThanOrEqual(budget.usdc);
    expect(s.ethLeg).toBe(10_000n);
    expect(s.usdcLeg).toBe(10_000n);
    expect(s.reverseUsdcLeg).toBeLessThanOrEqual(s.usdcLeg);
  });

  it("ignores a budget side with no legs", () => {
    const s = sizeLegs({ liquidity: 1_000_000n, ...oneToOne }, { usdc: 0n, ethWei: 10n ** 18n }, 500, { eth: 2, usdc: 0 });
    expect(s.ethLeg).toBe(50_000n);
  });

  it("rejects a budget that sizes a leg below the measurable minimum", () => {
    expect(() =>
      sizeLegs({ liquidity: 1_000_000n, ...oneToOne }, { usdc: MIN_LEG - 1n, ethWei: 10n ** 18n }, 500, legs),
    ).toThrow(BudgetTooSmallError);
    expect(() =>
      sizeLegs({ liquidity: 1_000_000n, ...oneToOne }, { usdc: 10n ** 9n, ethWei: 100n }, 500, legs),
    ).toThrow(/ETH_BUDGET_WEI/);
  });

  it("rejects zero liquidity", () => {
    expect(() => sizeLegs({ liquidity: 0n, ...oneToOne }, bigBudget, 500, legs)).toThrow(ZeroLiquidityError);
  });

  it("rejects an out-of-range fraction", () => {
    expect(() => sizeLegs({ liquidity: 1_000_000n, ...oneToOne }, bigBudget, 0, legs)).toThrow();
    expect(() => sizeLegs({ liquidity: 1_000_000n, ...oneToOne }, bigBudget, 5001, legs)).toThrow();
  });
});

describe("estimateOut", () => {
  it("charges the fee and the price impact", () => {
    // 5% of the reserve at 0.30%: out < in * (1 - fee) and out < in
    const out = estimateOut(50_000n, 1_000_000n, 1_000_000n, 3000);
    expect(out).toBeLessThan(50_000n * 997n / 1000n);
    expect(out).toBe(47_482n);
  });

  it("is zero for zero input", () => {
    expect(estimateOut(0n, 1n, 1n, 3000)).toBe(0n);
  });
});

describe("toCurrency0", () => {
  it("is the identity at 1:1", () => {
    expect(toCurrency0(12_345n, Q96)).toBe(12_345n);
    expect(toCurrency0(-12_345n, Q96)).toBe(-12_345n);
  });

  it("divides by the price", () => {
    expect(toCurrency0(4_000n, 2n * Q96)).toBe(1_000n);
  });
});
