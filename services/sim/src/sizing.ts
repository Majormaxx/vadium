// Pure sizing: how much each leg moves, derived from live pool liquidity and the actor
// budgets. Nothing here touches the network.

export const Q96 = 1n << 96n;
export const BPS = 10_000n;
export const PIPS = 1_000_000n;

/** Below this many raw units a leg is too small for the clamp to measure anything. */
export const MIN_LEG = 1_000n;

export interface PoolSnapshot {
  liquidity: bigint;
  sqrtPriceX96: bigint;
  /** LP fee in pips (3000 = 0.30%). */
  lpFeePips: number;
}

export interface Budget {
  usdc: bigint;
  ethWei: bigint;
}

export interface LegCounts {
  /** Legs that pay currency0 (native ETH). */
  eth: number;
  /** Legs that pay currency1 (USDC). */
  usdc: number;
}

export interface Sizing {
  /** Raw wei paid by each zeroForOne leg. */
  ethLeg: bigint;
  /** Raw USDC paid by each independent oneForZero leg. */
  usdcLeg: bigint;
  /** Raw USDC the attacker spends to reverse one ethLeg (about what the first leg returned). */
  reverseUsdcLeg: bigint;
  reserve0: bigint;
  reserve1: bigint;
}

export class ZeroLiquidityError extends Error {
  constructor() {
    super(
      "pool has zero in-range liquidity; seed it first from the repo root with " +
        "`LIQUIDITY_DELTA=1000000 make add-liquidity`",
    );
    this.name = "ZeroLiquidityError";
  }
}

export class BudgetTooSmallError extends Error {
  constructor(which: "ETH_BUDGET_WEI" | "USDC_BUDGET", leg: bigint) {
    super(`${which} sizes a leg of ${leg} raw units, below the ${MIN_LEG} minimum; raise it`);
    this.name = "BudgetTooSmallError";
  }
}

/** Virtual reserves of a full-range position with the given liquidity and price. */
export function virtualReserves(snapshot: PoolSnapshot): { reserve0: bigint; reserve1: bigint } {
  if (snapshot.liquidity <= 0n) throw new ZeroLiquidityError();
  if (snapshot.sqrtPriceX96 <= 0n) throw new Error("sqrtPriceX96 must be positive");
  return {
    reserve0: (snapshot.liquidity * Q96) / snapshot.sqrtPriceX96,
    reserve1: (snapshot.liquidity * snapshot.sqrtPriceX96) / Q96,
  };
}

/** Constant-product output for an exact input after the LP fee. Rounds down. */
export function estimateOut(amountIn: bigint, reserveIn: bigint, reserveOut: bigint, feePips: number): bigint {
  if (amountIn <= 0n) return 0n;
  const inAfterFee = amountIn * (PIPS - BigInt(feePips));
  return (reserveOut * inAfterFee) / (reserveIn * PIPS + inAfterFee);
}

function min(a: bigint, b: bigint): bigint {
  return a < b ? a : b;
}

/**
 * Size the legs. Each leg moves `fractionBps` of the virtual reserve on its input side,
 * capped so that all legs of the selected scenarios fit the budget.
 */
export function sizeLegs(snapshot: PoolSnapshot, budget: Budget, fractionBps: number, legs: LegCounts): Sizing {
  if (!Number.isInteger(fractionBps) || fractionBps <= 0 || fractionBps > 5_000) {
    throw new Error("fractionBps must be an integer in 1..5000");
  }
  const { reserve0, reserve1 } = virtualReserves(snapshot);
  const fraction = BigInt(fractionBps);

  let ethLeg = (reserve0 * fraction) / BPS;
  let usdcLeg = (reserve1 * fraction) / BPS;
  if (legs.eth > 0) ethLeg = min(ethLeg, budget.ethWei / BigInt(legs.eth));
  if (legs.usdc > 0) usdcLeg = min(usdcLeg, budget.usdc / BigInt(legs.usdc));

  if (legs.eth > 0 && ethLeg < MIN_LEG) throw new BudgetTooSmallError("ETH_BUDGET_WEI", ethLeg);
  if (legs.usdc > 0 && usdcLeg < MIN_LEG) throw new BudgetTooSmallError("USDC_BUDGET", usdcLeg);

  const reverseUsdcLeg = min(estimateOut(ethLeg, reserve0, reserve1, snapshot.lpFeePips), usdcLeg);
  return { ethLeg, usdcLeg, reverseUsdcLeg, reserve0, reserve1 };
}

/** Convert a currency1 amount to currency0 units at `sqrtPriceX96`. Signed; rounds toward zero. */
export function toCurrency0(amount1: bigint, sqrtPriceX96: bigint): bigint {
  if (sqrtPriceX96 <= 0n) throw new Error("sqrtPriceX96 must be positive");
  return (amount1 * Q96 * Q96) / (sqrtPriceX96 * sqrtPriceX96);
}
