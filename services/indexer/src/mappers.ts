// Pure mapping from decoded event args to table rows and row patches. No Ponder
// imports, so every function here runs in plain vitest.

export type Hex = `0x${string}`;

/** Per-event metadata the handlers pass in. */
export type EventMeta = {
  block: bigint;
  timestamp: bigint;
  txHash: Hex;
  logIndex: number;
};

export const lower = (h: string): Hex => h.toLowerCase() as Hex;

export const eventId = (meta: EventMeta): string => `${meta.txHash}-${meta.logIndex}`;

export const poolBlockId = (poolId: Hex, block: bigint): string => `${lower(poolId)}-${block}`;

// ---------------------------------------------------------------------------
// Row shapes (mirror ponder.schema.ts)
// ---------------------------------------------------------------------------

export type PoolRow = {
  id: Hex;
  chainId: number;
  currency0: Hex;
  currency1: Hex;
  fee: number;
  tickSpacing: number;
  operator: Hex;
  registeredBlock: bigint;
  reserve: bigint;
  slashedPledged: bigint;
  withdrawn: bigint;
  sandwiches: number;
  refundsCredited: bigint;
  refundsClaimed: bigint;
  withheld0: bigint;
  withheld1: bigint;
  lastCheckpointBlock: bigint | null;
  lastCheckpointSqrtPrice: bigint | null;
  lastCheckpointLiquidity: bigint | null;
};

export type BondRow = {
  id: Hex;
  amount: bigint;
  depositBlock: bigint;
  strikeCount: number;
  bannedUntil: bigint;
  flaggedUntil: bigint;
  updatedBlock: bigint;
};

export type SlashRow = {
  id: string;
  poolId: Hex;
  searcher: Hex;
  slashed: bigint;
  isRepeat: boolean;
  remaining: bigint;
  flaggedUntil: bigint;
  refunded: bigint;
  block: bigint;
  timestamp: bigint;
  txHash: Hex;
};

export type RefundRow = {
  id: string;
  poolId: Hex;
  victim: Hex;
  searcher: Hex;
  amount: bigint;
  block: bigint;
  txHash: Hex;
  claimedTxHash: Hex | null;
  sweptTxHash: Hex | null;
};

export type FlagRow = {
  id: string;
  searcher: Hex;
  poolId: Hex;
  slashed: bigint;
  evidenceHash: Hex;
  flaggedUntil: bigint;
  block: bigint;
  txHash: Hex;
};

export type DrainRow = {
  id: string;
  poolId: Hex;
  amount: bigint;
  remainingReserve: bigint;
  block: bigint;
  txHash: Hex;
};

export type WithheldRow = {
  id: string;
  poolId: Hex;
  sender: Hex;
  currency: Hex;
  amount: bigint;
  block: bigint;
  txHash: Hex;
};

export type FlushRow = {
  id: string;
  poolId: Hex;
  amount0: bigint;
  amount1: bigint;
  block: bigint;
  txHash: Hex;
};

export type CheckpointRow = {
  id: string;
  poolId: Hex;
  block: bigint;
  sqrtPriceX96: bigint;
  liquidity: bigint;
};

export type SwapRow = {
  id: string;
  poolId: Hex;
  sender: Hex;
  amount0: bigint;
  amount1: bigint;
  sqrtPriceX96: bigint;
  liquidity: bigint;
  tick: number;
  fee: number;
  block: bigint;
  txHash: Hex;
};

export type BlockPriceRow = {
  id: string;
  poolId: Hex;
  block: bigint;
  startSqrtPriceX96: bigint | null;
  endSqrtPriceX96: bigint | null;
};

// ---------------------------------------------------------------------------
// Event argument shapes (match the ABI; viem decodes them this way)
// ---------------------------------------------------------------------------

export type PoolKey = {
  currency0: Hex;
  currency1: Hex;
  fee: number;
  tickSpacing: number;
  hooks: Hex;
};

export type PoolRegisteredArgs = {
  poolId: Hex;
  operator: Hex;
  cfg: {
    clampEnabled: boolean;
    exemptFirstSwapOnly: boolean;
    requireVictimLoss: boolean;
    baseFee: number;
    feeDiscountBps: number;
  };
};
export type BondedArgs = { searcher: Hex; amount: bigint; depositBlock: bigint };
export type BondWithdrawnArgs = { searcher: Hex; amount: bigint };
export type SandwichedArgs = {
  poolId: Hex;
  searcher: Hex;
  slashed: bigint;
  isRepeat: boolean;
  remaining: bigint;
  flaggedUntil: bigint;
  refunded: bigint;
};
export type VictimRefundCreditedArgs = { poolId: Hex; victim: Hex; searcher: Hex; amount: bigint };
export type RefundClaimedArgs = { victim: Hex; amount: bigint };
export type FlaggedArgs = {
  searcher: Hex;
  poolId: Hex;
  slashed: bigint;
  evidenceHash: Hex;
  flaggedUntil: bigint;
};
export type CoverageClaimedArgs = { poolId: Hex; amount: bigint; remainingReserve: bigint };
export type UnclaimedSweptArgs = { key: Hex; to: Hex; amount: bigint };
/** uint48 decodes to a JS number. */
export type CheckpointedArgs = {
  poolId: Hex;
  blockNumber: number;
  sqrtPriceX96: bigint;
  liquidity: bigint;
};
export type ClampWithheldArgs = { poolId: Hex; sender: Hex; currency: Hex; amount: bigint };
export type WithheldFlushedArgs = { poolId: Hex; amount0: bigint; amount1: bigint };
export type SwapArgs = {
  id: Hex;
  sender: Hex;
  amount0: bigint;
  amount1: bigint;
  sqrtPriceX96: bigint;
  liquidity: bigint;
  tick: number;
  fee: number;
};

// ---------------------------------------------------------------------------
// Pool
// ---------------------------------------------------------------------------

export function mapPoolRegistered(
  args: PoolRegisteredArgs,
  key: PoolKey,
  meta: EventMeta,
  chainId: number,
): PoolRow {
  return {
    id: lower(args.poolId),
    chainId,
    currency0: lower(key.currency0),
    currency1: lower(key.currency1),
    fee: key.fee,
    tickSpacing: key.tickSpacing,
    operator: lower(args.operator),
    registeredBlock: meta.block,
    reserve: 0n,
    slashedPledged: 0n,
    withdrawn: 0n,
    sandwiches: 0,
    refundsCredited: 0n,
    refundsClaimed: 0n,
    withheld0: 0n,
    withheld1: 0n,
    lastCheckpointBlock: null,
    lastCheckpointSqrtPrice: null,
    lastCheckpointLiquidity: null,
  };
}

export type PoolPatch = Partial<Omit<PoolRow, "id">>;

/** The slash net of the victim refund is credited to the pool reserve. */
export function poolAfterSandwiched(pool: PoolRow, args: SandwichedArgs): PoolPatch {
  const credited = args.slashed - args.refunded;
  return {
    reserve: pool.reserve + credited,
    slashedPledged: pool.slashedPledged + credited,
    sandwiches: pool.sandwiches + 1,
  };
}

export function poolAfterRefundCredited(pool: PoolRow, args: VictimRefundCreditedArgs): PoolPatch {
  return { refundsCredited: pool.refundsCredited + args.amount };
}

/** A watchtower flag with a slash credits the whole slash to the pool reserve. */
export function poolAfterFlagged(pool: PoolRow, args: FlaggedArgs): PoolPatch {
  if (args.slashed === 0n) return {};
  return {
    reserve: pool.reserve + args.slashed,
    slashedPledged: pool.slashedPledged + args.slashed,
  };
}

export function poolAfterCoverageClaimed(pool: PoolRow, args: CoverageClaimedArgs): PoolPatch {
  return {
    reserve: args.remainingReserve,
    withdrawn: pool.withdrawn + args.amount,
  };
}

/** Swept unclaimed refunds are credited to the target pool's reserve. */
export function poolAfterUnclaimedSwept(pool: PoolRow, args: UnclaimedSweptArgs): PoolPatch {
  return {
    reserve: pool.reserve + args.amount,
    slashedPledged: pool.slashedPledged + args.amount,
  };
}

export function poolAfterCheckpointed(args: CheckpointedArgs): PoolPatch {
  return {
    lastCheckpointBlock: BigInt(args.blockNumber),
    lastCheckpointSqrtPrice: args.sqrtPriceX96,
    lastCheckpointLiquidity: args.liquidity,
  };
}

/** Adds the withheld amount to the side matching `currency`. Unknown currency
 *  (cannot happen on a registered pool) leaves the pool untouched. */
export function poolAfterClampWithheld(pool: PoolRow, args: ClampWithheldArgs): PoolPatch {
  const currency = lower(args.currency);
  if (currency === pool.currency0) return { withheld0: pool.withheld0 + args.amount };
  if (currency === pool.currency1) return { withheld1: pool.withheld1 + args.amount };
  return {};
}

export function poolAfterWithheldFlushed(pool: PoolRow, args: WithheldFlushedArgs): PoolPatch {
  return {
    withheld0: pool.withheld0 - args.amount0,
    withheld1: pool.withheld1 - args.amount1,
  };
}

// ---------------------------------------------------------------------------
// Bond
// ---------------------------------------------------------------------------

export function emptyBond(searcher: Hex): BondRow {
  return {
    id: lower(searcher),
    amount: 0n,
    depositBlock: 0n,
    strikeCount: 0,
    bannedUntil: 0n,
    flaggedUntil: 0n,
    updatedBlock: 0n,
  };
}

/** Strikes and flags survive a withdraw-and-rebond cycle, as on chain. */
export function bondAfterBonded(prev: BondRow | undefined, args: BondedArgs, meta: EventMeta): BondRow {
  const base = prev ?? emptyBond(args.searcher);
  return { ...base, amount: args.amount, depositBlock: args.depositBlock, updatedBlock: meta.block };
}

export function bondAfterWithdrawn(prev: BondRow | undefined, args: BondWithdrawnArgs, meta: EventMeta): BondRow {
  const base = prev ?? emptyBond(args.searcher);
  return { ...base, amount: 0n, updatedBlock: meta.block };
}

/** One strike. A repeat means the searcher is banned until the flag expires. */
export function bondAfterSandwiched(prev: BondRow | undefined, args: SandwichedArgs, meta: EventMeta): BondRow {
  const base = prev ?? emptyBond(args.searcher);
  return {
    ...base,
    amount: args.remaining,
    strikeCount: base.strikeCount + 1,
    flaggedUntil: args.flaggedUntil,
    bannedUntil: args.isRepeat ? args.flaggedUntil : base.bannedUntil,
    updatedBlock: meta.block,
  };
}

/** A flag always extends flaggedUntil; only a slashing flag counts as a strike. */
export function bondAfterFlagged(prev: BondRow | undefined, args: FlaggedArgs, meta: EventMeta): BondRow {
  const base = prev ?? emptyBond(args.searcher);
  const struck = args.slashed > 0n;
  return {
    ...base,
    amount: struck ? base.amount - args.slashed : base.amount,
    strikeCount: struck ? base.strikeCount + 1 : base.strikeCount,
    flaggedUntil: args.flaggedUntil,
    updatedBlock: meta.block,
  };
}

// ---------------------------------------------------------------------------
// Event rows
// ---------------------------------------------------------------------------

export function mapSandwiched(args: SandwichedArgs, meta: EventMeta): SlashRow {
  return {
    id: eventId(meta),
    poolId: lower(args.poolId),
    searcher: lower(args.searcher),
    slashed: args.slashed,
    isRepeat: args.isRepeat,
    remaining: args.remaining,
    flaggedUntil: args.flaggedUntil,
    refunded: args.refunded,
    block: meta.block,
    timestamp: meta.timestamp,
    txHash: meta.txHash,
  };
}

export function mapVictimRefundCredited(args: VictimRefundCreditedArgs, meta: EventMeta): RefundRow {
  return {
    id: eventId(meta),
    poolId: lower(args.poolId),
    victim: lower(args.victim),
    searcher: lower(args.searcher),
    amount: args.amount,
    block: meta.block,
    txHash: meta.txHash,
    claimedTxHash: null,
    sweptTxHash: null,
  };
}

export type RefundSettlement = {
  /** Rows to mark, with the hash to write. */
  rows: RefundRow[];
  /** Amount settled per pool id, for the pool counters. */
  perPool: Map<Hex, bigint>;
};

/** Which open refund rows a RefundClaimed settles: every row for the victim
 *  that is neither claimed nor swept. The on-chain claim pays the whole credit. */
export function settleRefunds(open: readonly RefundRow[], txHash: Hex, kind: "claimed" | "swept"): RefundSettlement {
  const perPool = new Map<Hex, bigint>();
  const rows: RefundRow[] = [];
  for (const r of open) {
    if (r.claimedTxHash !== null || r.sweptTxHash !== null) continue;
    rows.push(kind === "claimed" ? { ...r, claimedTxHash: txHash } : { ...r, sweptTxHash: txHash });
    perPool.set(r.poolId, (perPool.get(r.poolId) ?? 0n) + r.amount);
  }
  return { rows, perPool };
}

export function mapFlagged(args: FlaggedArgs, meta: EventMeta): FlagRow {
  return {
    id: eventId(meta),
    searcher: lower(args.searcher),
    poolId: lower(args.poolId),
    slashed: args.slashed,
    evidenceHash: lower(args.evidenceHash),
    flaggedUntil: args.flaggedUntil,
    block: meta.block,
    txHash: meta.txHash,
  };
}

export function mapCoverageClaimed(args: CoverageClaimedArgs, meta: EventMeta): DrainRow {
  return {
    id: eventId(meta),
    poolId: lower(args.poolId),
    amount: args.amount,
    remainingReserve: args.remainingReserve,
    block: meta.block,
    txHash: meta.txHash,
  };
}

export function mapClampWithheld(args: ClampWithheldArgs, meta: EventMeta): WithheldRow {
  return {
    id: eventId(meta),
    poolId: lower(args.poolId),
    sender: lower(args.sender),
    currency: lower(args.currency),
    amount: args.amount,
    block: meta.block,
    txHash: meta.txHash,
  };
}

export function mapWithheldFlushed(args: WithheldFlushedArgs, meta: EventMeta): FlushRow {
  return {
    id: eventId(meta),
    poolId: lower(args.poolId),
    amount0: args.amount0,
    amount1: args.amount1,
    block: meta.block,
    txHash: meta.txHash,
  };
}

export function mapCheckpointed(args: CheckpointedArgs): CheckpointRow {
  const poolId = lower(args.poolId);
  const block = BigInt(args.blockNumber);
  return {
    id: poolBlockId(poolId, block),
    poolId,
    block,
    sqrtPriceX96: args.sqrtPriceX96,
    liquidity: args.liquidity,
  };
}

/** blockPrice row a Checkpointed event opens. On conflict only the start is set. */
export function blockPriceFromCheckpointed(args: CheckpointedArgs): BlockPriceRow {
  const poolId = lower(args.poolId);
  const block = BigInt(args.blockNumber);
  return {
    id: poolBlockId(poolId, block),
    poolId,
    block,
    startSqrtPriceX96: args.sqrtPriceX96,
    endSqrtPriceX96: null,
  };
}

export function mapSwap(args: SwapArgs, meta: EventMeta): SwapRow {
  return {
    id: eventId(meta),
    poolId: lower(args.id),
    sender: lower(args.sender),
    amount0: args.amount0,
    amount1: args.amount1,
    sqrtPriceX96: args.sqrtPriceX96,
    liquidity: args.liquidity,
    tick: args.tick,
    fee: args.fee,
    block: meta.block,
    txHash: meta.txHash,
  };
}

/** blockPrice row a Swap closes. On conflict only the end is set. */
export function blockPriceFromSwap(args: SwapArgs, meta: EventMeta): BlockPriceRow {
  const poolId = lower(args.id);
  return {
    id: poolBlockId(poolId, meta.block),
    poolId,
    block: meta.block,
    startSqrtPriceX96: null,
    endSqrtPriceX96: args.sqrtPriceX96,
  };
}
