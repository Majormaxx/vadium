import type { EventMeta, Hex } from "../src/mappers";

export const POOL: Hex = "0x8e04e9c3fd9137cdc79ef352d1b1af9c5b3c5384cca2d8641c754bd6a2000304";
export const POOL_UPPER = POOL.toUpperCase().replace("0X", "0x") as Hex;
export const SEARCHER: Hex = "0xAbCdEf0000000000000000000000000000000001";
export const SEARCHER_LC = SEARCHER.toLowerCase() as Hex;
export const VICTIM: Hex = "0x00000000000000000000000000000000000000A2";
export const VICTIM_LC = VICTIM.toLowerCase() as Hex;
export const OPERATOR: Hex = "0x4e36ee389458856E79945a07Bf1bE36261E7b6a2";
export const CURRENCY0: Hex = "0x0000000000000000000000000000000000000000";
export const CURRENCY1: Hex = "0x31d0220469e10c4E71834a79b1f276d740d3768F";
export const TX: Hex = "0x1111111111111111111111111111111111111111111111111111111111111111";
export const TX2: Hex = "0x2222222222222222222222222222222222222222222222222222222222222222";

export const meta = (over: Partial<EventMeta> = {}): EventMeta => ({
  block: 61_600_000n,
  timestamp: 1_788_500_000n,
  txHash: TX,
  logIndex: 7,
  ...over,
});
