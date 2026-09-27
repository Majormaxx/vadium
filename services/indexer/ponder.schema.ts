import { index, onchainTable } from "ponder";

export const pool = onchainTable("pool", (t) => ({
  id: t.hex().primaryKey(),
  chainId: t.integer().notNull(),
  currency0: t.hex().notNull(),
  currency1: t.hex().notNull(),
  fee: t.integer().notNull(),
  tickSpacing: t.integer().notNull(),
  operator: t.hex().notNull(),
  registeredBlock: t.bigint().notNull(),
  reserve: t.bigint().notNull(),
  slashedPledged: t.bigint().notNull(),
  withdrawn: t.bigint().notNull(),
  sandwiches: t.integer().notNull(),
  refundsCredited: t.bigint().notNull(),
  refundsClaimed: t.bigint().notNull(),
  withheld0: t.bigint().notNull(),
  withheld1: t.bigint().notNull(),
  lastCheckpointBlock: t.bigint(),
  lastCheckpointSqrtPrice: t.bigint(),
  lastCheckpointLiquidity: t.bigint(),
}));

export const bond = onchainTable("bond", (t) => ({
  id: t.hex().primaryKey(),
  amount: t.bigint().notNull(),
  depositBlock: t.bigint().notNull(),
  strikeCount: t.integer().notNull(),
  bannedUntil: t.bigint().notNull(),
  flaggedUntil: t.bigint().notNull(),
  updatedBlock: t.bigint().notNull(),
}));

export const slash = onchainTable(
  "slash",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    searcher: t.hex().notNull(),
    slashed: t.bigint().notNull(),
    isRepeat: t.boolean().notNull(),
    remaining: t.bigint().notNull(),
    flaggedUntil: t.bigint().notNull(),
    refunded: t.bigint().notNull(),
    block: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({
    poolIdx: index().on(table.poolId),
    searcherIdx: index().on(table.searcher),
  }),
);

export const refund = onchainTable(
  "refund",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    victim: t.hex().notNull(),
    searcher: t.hex().notNull(),
    amount: t.bigint().notNull(),
    block: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    claimedTxHash: t.hex(),
    sweptTxHash: t.hex(),
  }),
  (table) => ({
    poolIdx: index().on(table.poolId),
    victimIdx: index().on(table.victim),
  }),
);

export const flag = onchainTable(
  "flag",
  (t) => ({
    id: t.text().primaryKey(),
    searcher: t.hex().notNull(),
    poolId: t.hex().notNull(),
    slashed: t.bigint().notNull(),
    evidenceHash: t.hex().notNull(),
    flaggedUntil: t.bigint().notNull(),
    block: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({
    searcherIdx: index().on(table.searcher),
  }),
);

export const drain = onchainTable(
  "drain",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    amount: t.bigint().notNull(),
    remainingReserve: t.bigint().notNull(),
    block: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ poolIdx: index().on(table.poolId) }),
);

export const withheld = onchainTable(
  "withheld",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    sender: t.hex().notNull(),
    currency: t.hex().notNull(),
    amount: t.bigint().notNull(),
    block: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ poolIdx: index().on(table.poolId) }),
);

export const flush = onchainTable(
  "flush",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    amount0: t.bigint().notNull(),
    amount1: t.bigint().notNull(),
    block: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ poolIdx: index().on(table.poolId) }),
);

export const checkpoint = onchainTable(
  "checkpoint",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    block: t.bigint().notNull(),
    sqrtPriceX96: t.bigint().notNull(),
    liquidity: t.bigint().notNull(),
  }),
  (table) => ({ poolIdx: index().on(table.poolId) }),
);

export const swap = onchainTable(
  "swap",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    sender: t.hex().notNull(),
    amount0: t.bigint().notNull(),
    amount1: t.bigint().notNull(),
    sqrtPriceX96: t.bigint().notNull(),
    liquidity: t.bigint().notNull(),
    tick: t.integer().notNull(),
    fee: t.integer().notNull(),
    block: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({ poolIdx: index().on(table.poolId) }),
);

// One row per (pool, block) that had a Checkpointed or Swap event. Start comes
// from Checkpointed, end from the last Swap in the block. Either side is null
// until its event arrives.
export const blockPrice = onchainTable(
  "block_price",
  (t) => ({
    id: t.text().primaryKey(),
    poolId: t.hex().notNull(),
    block: t.bigint().notNull(),
    startSqrtPriceX96: t.bigint(),
    endSqrtPriceX96: t.bigint(),
  }),
  (table) => ({ poolBlockIdx: index().on(table.poolId, table.block) }),
);
