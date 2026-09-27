import { describe, expect, it } from "vitest";
import { formatDeviation, seriesValues, sparklinePath } from "@/lib/staleness";

describe("sparklinePath", () => {
  it("is empty for no points", () => {
    expect(sparklinePath([])).toBe("");
  });
  it("draws a flat line for one point", () => {
    expect(sparklinePath([7], 160, 40, 2)).toBe("M2,20 L158,20");
  });
  it("draws n-1 segments for n points, min at the bottom, max at the top", () => {
    const path = sparklinePath([0, 10, 5], 100, 50, 0);
    expect(path).toBe("M0,50 L50,0 L100,25");
    expect(path.split(" ").filter((p) => p.startsWith("L"))).toHaveLength(2);
  });
  it("centres a constant series", () => {
    expect(sparklinePath([3, 3, 3, 3], 30, 10, 0)).toBe("M0,5 L10,5 L20,5 L30,5");
  });
  it("respects padding", () => {
    expect(sparklinePath([0, 1], 12, 12, 2)).toBe("M2,10 L10,2");
  });
  it("is deterministic for many points", () => {
    const values = Array.from({ length: 1000 }, (_, i) => (i * 37) % 101);
    const a = sparklinePath(values);
    const b = sparklinePath(values);
    expect(a).toBe(b);
    expect(a.startsWith("M")).toBe(true);
    expect(a.split(" L")).toHaveLength(1000);
  });
});

describe("formatDeviation", () => {
  it("renders fractions as percent", () => {
    expect(formatDeviation(0)).toBe("0.00%");
    expect(formatDeviation(0.0012)).toBe("0.12%");
    expect(formatDeviation("0.025")).toBe("2.50%");
    expect(formatDeviation(0.0003456)).toBe("0.03%");
  });
  it("handles missing values", () => {
    expect(formatDeviation(null)).toBe("n/a");
    expect(formatDeviation(undefined)).toBe("n/a");
    expect(formatDeviation("abc")).toBe("n/a");
  });
});

describe("seriesValues", () => {
  it("reads deviation as a number and drops garbage to zero", () => {
    const series = [
      { blockNumber: "1", startSqrtPriceX96: "1", endSqrtPriceX96: "1", deviation: "12" },
      { blockNumber: "2", startSqrtPriceX96: "1", endSqrtPriceX96: "1", deviation: 3 },
      { blockNumber: "3", startSqrtPriceX96: "1", endSqrtPriceX96: "1", deviation: "x" },
    ];
    expect(seriesValues(series)).toEqual([12, 3, 0]);
  });
});
