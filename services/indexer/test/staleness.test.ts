import { describe, expect, it } from "vitest";
import { deviation, mean, percentile, sqrtPriceX96ToPrice, summarizeStaleness } from "../src/staleness";

const Q96 = 2n ** 96n;

describe("sqrtPriceX96ToPrice", () => {
  it("2^96 is price 1.0", () => {
    expect(sqrtPriceX96ToPrice(Q96)).toBe(1);
  });
  it("2 * 2^96 is price 4.0", () => {
    expect(sqrtPriceX96ToPrice(2n * Q96)).toBe(4);
  });
  it("2^96 / 2 is price 0.25", () => {
    expect(sqrtPriceX96ToPrice(Q96 / 2n)).toBe(0.25);
  });
  it("zero is zero", () => {
    expect(sqrtPriceX96ToPrice(0n)).toBe(0);
  });
});

describe("deviation", () => {
  it("is zero when start and end match", () => {
    expect(deviation(Q96, Q96)).toBe(0);
  });
  it("is relative to the start price", () => {
    // start price 1, end price 4 -> |4 - 1| / 1 = 3
    expect(deviation(Q96, 2n * Q96)).toBe(3);
    // start price 4, end price 1 -> |1 - 4| / 4 = 0.75
    expect(deviation(2n * Q96, Q96)).toBe(0.75);
  });
  it("is zero when the start price is zero", () => {
    expect(deviation(0n, Q96)).toBe(0);
  });
});

describe("percentile", () => {
  it("empty input is null", () => {
    expect(percentile([], 50)).toBeNull();
    expect(percentile([], 95)).toBeNull();
  });
  it("one element is that element at any percentile", () => {
    expect(percentile([0.4], 0)).toBe(0.4);
    expect(percentile([0.4], 50)).toBe(0.4);
    expect(percentile([0.4], 95)).toBe(0.4);
    expect(percentile([0.4], 100)).toBe(0.4);
  });
  it("odd count median is the middle element", () => {
    expect(percentile([3, 1, 2], 50)).toBe(2);
  });
  it("even count median interpolates the two middle elements", () => {
    expect(percentile([1, 3], 50)).toBe(2);
    expect(percentile([4, 1, 3, 2], 50)).toBe(2.5);
  });
  it("p95 of 1..10 interpolates like numpy", () => {
    const v = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    expect(percentile(v, 95)).toBeCloseTo(9.55, 10);
    expect(percentile(v, 0)).toBe(1);
    expect(percentile(v, 100)).toBe(10);
  });
  it("does not mutate its input", () => {
    const v = [3, 1, 2];
    percentile(v, 50);
    expect(v).toEqual([3, 1, 2]);
  });
});

describe("mean", () => {
  it("empty is null", () => {
    expect(mean([])).toBeNull();
  });
  it("averages", () => {
    expect(mean([1, 2, 3, 6])).toBe(3);
  });
});

describe("summarizeStaleness", () => {
  it("empty window yields count 0 and null stats", () => {
    expect(summarizeStaleness([], 1000)).toEqual({ window: 1000, count: 0, p50: null, p95: null, mean: null, series: [] });
  });
  it("computes deviations per block and stats over them", () => {
    const s = summarizeStaleness(
      [
        { block: 10n, startSqrtPriceX96: Q96, endSqrtPriceX96: Q96 },
        { block: 11n, startSqrtPriceX96: Q96, endSqrtPriceX96: 2n * Q96 },
        { block: 12n, startSqrtPriceX96: 2n * Q96, endSqrtPriceX96: Q96 },
      ],
      1000,
    );
    expect(s.count).toBe(3);
    expect(s.series.map((p) => p.blockNumber)).toEqual([10, 11, 12]);
    expect(s.series.map((p) => p.deviation)).toEqual([0, 3, 0.75]);
    expect(s.series[1]).toEqual({
      blockNumber: 11,
      startSqrtPriceX96: Q96.toString(),
      endSqrtPriceX96: (2n * Q96).toString(),
      deviation: 3,
    });
    expect(s.p50).toBe(0.75);
    expect(s.mean).toBe(1.25);
    expect(s.p95).toBeCloseTo(0.75 + (3 - 0.75) * 0.9, 10);
  });
  it("limits the series to the last N samples but keeps stats over the window", () => {
    const samples = Array.from({ length: 300 }, (_, i) => ({
      block: BigInt(i),
      startSqrtPriceX96: Q96,
      endSqrtPriceX96: i === 0 ? 2n * Q96 : Q96,
    }));
    const s = summarizeStaleness(samples, 1000, 200);
    expect(s.count).toBe(300);
    expect(s.series).toHaveLength(200);
    expect(s.series[0]!.blockNumber).toBe(100);
    expect(s.series[199]!.blockNumber).toBe(299);
    // the one outlier is outside the series but inside the stats
    expect(s.mean).toBeCloseTo(3 / 300, 12);
  });
});
