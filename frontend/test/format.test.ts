import { describe, expect, it } from "vitest";
import {
  blocksAgo,
  bpsToPercent,
  feeToPercent,
  formatEth,
  formatInt,
  formatPrice,
  formatTimestamp,
  formatUnits,
  formatUsdc,
  shortAddress,
  shortHash,
  sqrtPriceX96ToPrice,
  toBigInt,
} from "@/lib/format";

describe("toBigInt", () => {
  it("parses decimal strings, numbers, and bigints", () => {
    expect(toBigInt("123")).toBe(123n);
    expect(toBigInt("-5")).toBe(-5n);
    expect(toBigInt(42)).toBe(42n);
    expect(toBigInt(7n)).toBe(7n);
  });
  it("maps garbage to zero", () => {
    expect(toBigInt("")).toBe(0n);
    expect(toBigInt("0x10")).toBe(0n);
    expect(toBigInt("1.5")).toBe(0n);
    expect(toBigInt(null)).toBe(0n);
    expect(toBigInt(undefined)).toBe(0n);
    expect(toBigInt(Number.NaN)).toBe(0n);
  });
});

describe("formatUsdc", () => {
  it("formats zero", () => {
    expect(formatUsdc("0")).toBe("0.00");
    expect(formatUsdc(0n)).toBe("0.00");
    expect(formatUsdc(null)).toBe("0.00");
  });
  it("formats whole and fractional units", () => {
    expect(formatUsdc("1000000")).toBe("1.00");
    expect(formatUsdc("1234567")).toBe("1.234567");
    expect(formatUsdc("100000000")).toBe("100.00");
    expect(formatUsdc("1")).toBe("0.000001");
    expect(formatUsdc("500000")).toBe("0.50");
  });
  it("adds thousands separators to large values", () => {
    expect(formatUsdc("123456789012345678")).toBe("123,456,789,012.345678");
    expect(formatUsdc(10n ** 30n)).toBe("1,000,000,000,000,000,000,000,000.00");
  });
  it("truncates instead of rounding", () => {
    expect(formatUnits("1999999", 6, { maxFraction: 2 })).toBe("1.99");
  });
  it("keeps the sign", () => {
    expect(formatUsdc("-2500000")).toBe("-2.50");
  });
});

describe("formatEth and formatInt", () => {
  it("formats 18 decimal values to six places", () => {
    expect(formatEth("1000000000000000000")).toBe("1.00");
    expect(formatEth("1234567890123456789")).toBe("1.234567");
  });
  it("groups integers", () => {
    expect(formatInt("61591813")).toBe("61,591,813");
    expect(formatInt(0)).toBe("0");
    expect(formatInt(999n)).toBe("999");
  });
});

describe("percent helpers", () => {
  it("converts basis points", () => {
    expect(bpsToPercent(5000)).toBe("50%");
    expect(bpsToPercent("25")).toBe("0.25%");
    expect(bpsToPercent(0)).toBe("0%");
    expect(bpsToPercent(10_000)).toBe("100%");
    expect(bpsToPercent(12.5)).toBe("0.125%");
  });
  it("converts v4 pool fees in pips", () => {
    expect(feeToPercent(3000)).toBe("0.30%");
    expect(feeToPercent(500)).toBe("0.05%");
    expect(feeToPercent(10_000)).toBe("1.00%");
    expect(feeToPercent(0)).toBe("0.00%");
    expect(feeToPercent(0x800000)).toBe("dynamic");
  });
});

describe("blocksAgo", () => {
  it("describes the distance to head", () => {
    expect(blocksAgo("100", "100")).toBe("this block");
    expect(blocksAgo("99", "100")).toBe("1 block ago");
    expect(blocksAgo("50", "1050")).toBe("1,000 blocks ago");
    expect(blocksAgo(105n, 100n)).toBe("this block");
  });
  it("falls back to the absolute block with no head", () => {
    expect(blocksAgo("61591813", null)).toBe("block 61,591,813");
  });
});

describe("address shortening", () => {
  const addr = "0x6d6201097d6549F9760d61019E69E599315dc0C0";
  it("keeps 4 chars either side", () => {
    expect(shortAddress(addr)).toBe("0x6d62…c0C0");
  });
  it("keeps 8 chars for hashes", () => {
    expect(shortHash("0x8e04e9c3fd9137cdc79ef352d1b1af9c5b3c5384cca2d8641c754bd6a2000304")).toBe(
      "0x8e04e9c3…2000304".replace("…2000304", "…a2000304"),
    );
  });
  it("leaves short strings alone", () => {
    expect(shortAddress("0xabcd")).toBe("0xabcd");
    expect(shortAddress("")).toBe("");
  });
});

describe("sqrtPriceX96ToPrice", () => {
  const Q96 = 2n ** 96n;
  it("is 1 at 2^96", () => {
    expect(sqrtPriceX96ToPrice(Q96)).toBe(1);
    expect(sqrtPriceX96ToPrice(Q96.toString())).toBe(1);
  });
  it("is 4 at 2 * 2^96", () => {
    expect(sqrtPriceX96ToPrice(2n * Q96)).toBe(4);
  });
  it("adjusts for token decimals", () => {
    // 1 raw unit of an 18-decimal token per 1 raw unit of a 6-decimal token
    expect(sqrtPriceX96ToPrice(Q96, 18, 6)).toBe(1e12);
    expect(sqrtPriceX96ToPrice(Q96, 6, 18)).toBe(1e-12);
  });
  it("returns 0 for a zero price", () => {
    expect(sqrtPriceX96ToPrice("0")).toBe(0);
  });
  it("formats prices with a scale-aware number of places", () => {
    expect(formatPrice(3123.456)).toBe("3,123.46");
    expect(formatPrice(1.23456789)).toBe("1.2346");
    expect(formatPrice(0.000123456)).toBe("0.000123");
    expect(formatPrice(0)).toBe("0");
  });
});

describe("formatTimestamp", () => {
  it("prints UTC without locale", () => {
    expect(formatTimestamp("1788444240")).toBe("2026-09-03 14:04:00 UTC");
    expect(formatTimestamp("0")).toBe("");
  });
});
