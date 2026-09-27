// Helpers for the pool staleness card. The indexer reports how far the block
// start price drifted from the block end price, one point per block.

export type StalenessPoint = {
  blockNumber: string;
  startSqrtPriceX96: string;
  endSqrtPriceX96: string;
  /** Drift between block start and block end, in basis points. */
  deviation: number | string;
};

export type StalenessSummary = {
  window: number;
  count: number;
  p50: number | string | null;
  p95: number | string | null;
  mean: number | string | null;
  series: StalenessPoint[];
};

export function seriesValues(series: StalenessPoint[]): number[] {
  return series.map((p) => {
    const n = Number(p.deviation);
    return Number.isFinite(n) ? n : 0;
  });
}

function num(n: number): string {
  return Number.isInteger(n) ? n.toString() : n.toFixed(2).replace(/\.?0+$/, "");
}

/**
 * Builds an SVG path for a sparkline. An empty series gives an empty path,
 * a single point a flat line across the width, and n points n-1 segments
 * scaled so the min sits at the bottom and the max at the top.
 */
export function sparklinePath(values: number[], width = 160, height = 40, pad = 2): string {
  if (values.length === 0) return "";
  const innerW = width - pad * 2;
  const innerH = height - pad * 2;
  if (values.length === 1) {
    const y = num(height / 2);
    return `M${num(pad)},${y} L${num(width - pad)},${y}`;
  }
  let min = Infinity;
  let max = -Infinity;
  for (const v of values) {
    if (v < min) min = v;
    if (v > max) max = v;
  }
  const range = max - min;
  const step = innerW / (values.length - 1);
  const parts: string[] = [];
  values.forEach((v, i) => {
    const x = pad + i * step;
    const y = range === 0 ? height / 2 : pad + (1 - (v - min) / range) * innerH;
    parts.push(`${i === 0 ? "M" : "L"}${num(x)},${num(y)}`);
  });
  return parts.join(" ");
}

/** Fraction to a percent string with two places: 0.0012 -> "0.12%". */
export function formatDeviation(value: number | string | null | undefined): string {
  if (value === null || value === undefined) return "n/a";
  const n = Number(value);
  if (!Number.isFinite(n)) return "n/a";
  return `${(n * 100).toFixed(2)}%`;
}
