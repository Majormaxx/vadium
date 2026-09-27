// Pure formatting helpers. Every function is deterministic and safe to call
// with the decimal strings the indexer returns or with bigint values from viem.

const ZERO = 0n;

/** Parses a decimal string, number, or bigint into a bigint. Anything unparseable is 0n. */
export function toBigInt(value: string | number | bigint | null | undefined): bigint {
  if (value === null || value === undefined) return ZERO;
  if (typeof value === "bigint") return value;
  if (typeof value === "number") return Number.isFinite(value) ? BigInt(Math.trunc(value)) : ZERO;
  const trimmed = value.trim();
  if (!/^-?\d+$/.test(trimmed)) return ZERO;
  return BigInt(trimmed);
}

/** Inserts thousands separators into an integer string. */
export function groupThousands(digits: string): string {
  const negative = digits.startsWith("-");
  const body = negative ? digits.slice(1) : digits;
  const grouped = body.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return negative ? `-${grouped}` : grouped;
}

/** Formats an integer with thousands separators. */
export function formatInt(value: string | number | bigint | null | undefined): string {
  return groupThousands(toBigInt(value).toString());
}

export type UnitsOptions = {
  /** Fewest fraction digits shown. Zeros are padded to reach it. */
  minFraction?: number;
  /** Most fraction digits shown. Extra digits are truncated, never rounded. */
  maxFraction?: number;
};

/**
 * Formats a fixed-point integer with `decimals` decimals as a human number with
 * thousands separators. Truncates rather than rounds so a displayed balance
 * never exceeds the real one.
 */
export function formatUnits(
  value: string | number | bigint | null | undefined,
  decimals: number,
  options: UnitsOptions = {},
): string {
  const minFraction = options.minFraction ?? 2;
  const maxFraction = Math.max(minFraction, options.maxFraction ?? decimals);
  const raw = toBigInt(value);
  const negative = raw < ZERO;
  const abs = negative ? -raw : raw;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  let fraction = (abs % base).toString().padStart(decimals, "0").slice(0, maxFraction);
  fraction = fraction.replace(/0+$/, "");
  if (fraction.length < minFraction) fraction = fraction.padEnd(minFraction, "0");
  const wholeText = groupThousands(whole.toString());
  const text = fraction.length > 0 ? `${wholeText}.${fraction}` : wholeText;
  return negative ? `-${text}` : text;
}

/** USDC has 6 decimals. Shows at least 2 and at most 6 fraction digits. */
export function formatUsdc(value: string | number | bigint | null | undefined): string {
  return formatUnits(value, 6, { minFraction: 2, maxFraction: 6 });
}

/** Native ETH with 18 decimals, shown to 6 places at most. */
export function formatEth(value: string | number | bigint | null | undefined): string {
  return formatUnits(value, 18, { minFraction: 2, maxFraction: 6 });
}

/** Basis points to a percent string: 5000 -> "50%", 25 -> "0.25%", 12.5 -> "0.125%". */
export function bpsToPercent(bps: string | number | bigint | null | undefined): string {
  const n = typeof bps === "bigint" ? Number(bps) : Number(bps ?? 0);
  if (!Number.isFinite(n)) return "0%";
  const percent = n / 100;
  const text = trimFraction(percent.toFixed(4));
  return `${text}%`;
}

/**
 * Uniswap v4 pool fees are in hundredths of a basis point (pips): 3000 -> "0.30%".
 * The dynamic-fee flag (0x800000) is shown as "dynamic".
 */
export function feeToPercent(fee: string | number | bigint | null | undefined): string {
  const n = typeof fee === "bigint" ? Number(fee) : Number(fee ?? 0);
  if (!Number.isFinite(n)) return "0%";
  if (n === 0x800000) return "dynamic";
  const percent = n / 10_000;
  const fixed = percent.toFixed(4);
  const trimmed = trimFraction(fixed);
  const [whole, frac = ""] = trimmed.split(".");
  return `${whole}.${frac.padEnd(2, "0")}%`;
}

function trimFraction(fixed: string): string {
  if (!fixed.includes(".")) return fixed;
  const trimmed = fixed.replace(/0+$/, "").replace(/\.$/, "");
  return trimmed === "-0" ? "0" : trimmed;
}

/** "3 blocks ago" relative to `head`. With no head, the absolute block number. */
export function blocksAgo(
  block: string | number | bigint | null | undefined,
  head: string | number | bigint | null | undefined,
): string {
  const b = toBigInt(block);
  if (head === null || head === undefined) return `block ${formatInt(b)}`;
  const h = toBigInt(head);
  const diff = h - b;
  if (diff <= ZERO) return "this block";
  if (diff === 1n) return "1 block ago";
  return `${formatInt(diff)} blocks ago`;
}

/** 0x1234...abcd. Keeps the whole string if it is already short. */
export function shortAddress(address: string, chars = 4): string {
  if (!address) return "";
  if (address.length <= 2 + chars * 2) return address;
  return `${address.slice(0, 2 + chars)}…${address.slice(-chars)}`;
}

/** Longer form for tx hashes and pool ids: 0x12345678...abcdef12. */
export function shortHash(hash: string): string {
  return shortAddress(hash, 8);
}

const Q192 = 2n ** 192n;
const PRICE_SCALE = 10n ** 18n;

/**
 * Converts a Uniswap sqrtPriceX96 to the price of currency1 per currency0,
 * adjusted for token decimals. 2^96 -> 1, 2^97 -> 4 with equal decimals.
 */
export function sqrtPriceX96ToPrice(
  sqrtPriceX96: string | number | bigint,
  decimals0 = 18,
  decimals1 = 18,
): number {
  const sqrt = toBigInt(sqrtPriceX96);
  if (sqrt <= ZERO) return 0;
  const num = sqrt * sqrt * PRICE_SCALE * 10n ** BigInt(decimals0);
  const den = Q192 * 10n ** BigInt(decimals1);
  const scaled = num / den;
  return Number(scaled) / 1e18;
}

/** Prices get a sensible number of places: 2 above 1000, 4 above 1, 6 below. */
export function formatPrice(price: number): string {
  if (!Number.isFinite(price) || price === 0) return "0";
  const places = price >= 1000 ? 2 : price >= 1 ? 4 : 6;
  const [whole, frac] = price.toFixed(places).split(".");
  return frac ? `${groupThousands(whole)}.${frac}` : groupThousands(whole);
}

/** Unix seconds to a UTC timestamp string without locale dependence. */
export function formatTimestamp(seconds: string | number | bigint | null | undefined): string {
  const s = Number(toBigInt(seconds));
  if (s <= 0) return "";
  return new Date(s * 1000).toISOString().replace("T", " ").replace(/\.\d{3}Z$/, " UTC");
}
