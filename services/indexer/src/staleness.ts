// Pure price and percentile math for the block staleness metric. No Ponder imports.

const Q96 = 2 ** 96;

/** price = (sqrtPriceX96 / 2^96)^2, as a float. Precision loss above 2^53 is
 *  relative (~1e-16) and irrelevant for a deviation metric. */
export function sqrtPriceX96ToPrice(sqrtPriceX96: bigint): number {
  const ratio = Number(sqrtPriceX96) / Q96;
  return ratio * ratio;
}

/** |priceEnd - priceStart| / priceStart. Zero when the start price is zero. */
export function deviation(startSqrtPriceX96: bigint, endSqrtPriceX96: bigint): number {
  const start = sqrtPriceX96ToPrice(startSqrtPriceX96);
  if (start === 0) return 0;
  const end = sqrtPriceX96ToPrice(endSqrtPriceX96);
  return Math.abs(end - start) / start;
}

/** Percentile with linear interpolation between ranks (numpy's default).
 *  `values` need not be sorted. Returns null for an empty input. */
export function percentile(values: readonly number[], p: number): number | null {
  const n = values.length;
  if (n === 0) return null;
  if (p <= 0) return Math.min(...values);
  if (p >= 100) return Math.max(...values);
  const sorted = [...values].sort((a, b) => a - b);
  const pos = (p / 100) * (n - 1);
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  const a = sorted[lo]!;
  const b = sorted[hi]!;
  return a + (b - a) * (pos - lo);
}

export function mean(values: readonly number[]): number | null {
  if (values.length === 0) return null;
  let sum = 0;
  for (const v of values) sum += v;
  return sum / values.length;
}

export type BlockPriceSample = {
  block: bigint;
  startSqrtPriceX96: bigint;
  endSqrtPriceX96: bigint;
};

export type StalenessPoint = {
  blockNumber: number;
  startSqrtPriceX96: string;
  endSqrtPriceX96: string;
  deviation: number;
};

/** deviation, p50, p95 and mean are plain fractions (0.0012 means 0.12%). */
export type StalenessSummary = {
  window: number;
  count: number;
  p50: number | null;
  p95: number | null;
  mean: number | null;
  series: StalenessPoint[];
};

export const SERIES_LIMIT = 200;

/** Summarize the last `window` blocks that had swaps. `samples` is ascending by
 *  block and already limited to at most `window` entries by the caller. */
export function summarizeStaleness(
  samples: readonly BlockPriceSample[],
  window: number,
  seriesLimit: number = SERIES_LIMIT,
): StalenessSummary {
  const points: StalenessPoint[] = samples.map((s) => ({
    blockNumber: Number(s.block),
    startSqrtPriceX96: s.startSqrtPriceX96.toString(),
    endSqrtPriceX96: s.endSqrtPriceX96.toString(),
    deviation: deviation(s.startSqrtPriceX96, s.endSqrtPriceX96),
  }));
  const deviations = points.map((p) => p.deviation);
  return {
    window,
    count: points.length,
    p50: percentile(deviations, 50),
    p95: percentile(deviations, 95),
    mean: mean(deviations),
    series: points.slice(Math.max(0, points.length - seriesLimit)),
  };
}
