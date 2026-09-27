// Row to JSON shapes. Every uint256 becomes a decimal string; block numbers and
// timestamps become JS numbers. Pure, no Ponder imports.

import type { BondRow, FlagRow, PoolRow, RefundRow, SlashRow, WithheldRow } from "../mappers";
import type { StalenessSummary } from "../staleness";

export type PoolSummary = {
  poolId: string;
  chainId: number;
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  reserve: string;
  slashedPledged: string;
  withdrawn: string;
  sandwiches: number;
  refundsCredited: string;
  refundsClaimed: string;
  withheld0: string;
  withheld1: string;
  lastCheckpoint: { blockNumber: number; sqrtPriceX96: string; liquidity: string } | null;
  bondedCount: number;
};

export type PoolDetail = PoolSummary & { staleness: StalenessSummary };

export type Slash = {
  txHash: string;
  blockNumber: number;
  timestamp: number;
  searcher: string;
  slashed: string;
  isRepeat: boolean;
  remaining: string;
  flaggedUntil: string;
  refunded: string;
};

export type Refund = {
  txHash: string;
  blockNumber: number;
  victim: string;
  searcher: string;
  amount: string;
  claimed: boolean;
};

export type Bond = {
  searcher: string;
  amount: string;
  depositBlock: string;
  strikeCount: number;
  bannedUntil: string;
  flaggedUntil: string;
};

export type Withheld = {
  txHash: string;
  blockNumber: number;
  sender: string;
  currency: string;
  amount: string;
};

export type Flag = {
  txHash: string;
  blockNumber: number;
  poolId: string;
  slashed: string;
  evidenceHash: string;
  flaggedUntil: string;
};

export type Status = {
  chainId: number;
  indexedBlock: number;
  headBlock: number | null;
  hook: string;
  lag: number | null;
};

export function toPoolSummary(p: PoolRow, bondedCount: number): PoolSummary {
  return {
    poolId: p.id,
    chainId: p.chainId,
    currency0: p.currency0,
    currency1: p.currency1,
    fee: p.fee,
    tickSpacing: p.tickSpacing,
    reserve: p.reserve.toString(),
    slashedPledged: p.slashedPledged.toString(),
    withdrawn: p.withdrawn.toString(),
    sandwiches: p.sandwiches,
    refundsCredited: p.refundsCredited.toString(),
    refundsClaimed: p.refundsClaimed.toString(),
    withheld0: p.withheld0.toString(),
    withheld1: p.withheld1.toString(),
    lastCheckpoint:
      p.lastCheckpointBlock !== null && p.lastCheckpointSqrtPrice !== null && p.lastCheckpointLiquidity !== null
        ? {
            blockNumber: Number(p.lastCheckpointBlock),
            sqrtPriceX96: p.lastCheckpointSqrtPrice.toString(),
            liquidity: p.lastCheckpointLiquidity.toString(),
          }
        : null,
    bondedCount,
  };
}

export function toSlash(r: SlashRow): Slash {
  return {
    txHash: r.txHash,
    blockNumber: Number(r.block),
    timestamp: Number(r.timestamp),
    searcher: r.searcher,
    slashed: r.slashed.toString(),
    isRepeat: r.isRepeat,
    remaining: r.remaining.toString(),
    flaggedUntil: r.flaggedUntil.toString(),
    refunded: r.refunded.toString(),
  };
}

export function toRefund(r: RefundRow): Refund {
  return {
    txHash: r.txHash,
    blockNumber: Number(r.block),
    victim: r.victim,
    searcher: r.searcher,
    amount: r.amount.toString(),
    claimed: r.claimedTxHash !== null,
  };
}

export function toBond(b: BondRow): Bond {
  return {
    searcher: b.id,
    amount: b.amount.toString(),
    depositBlock: b.depositBlock.toString(),
    strikeCount: b.strikeCount,
    bannedUntil: b.bannedUntil.toString(),
    flaggedUntil: b.flaggedUntil.toString(),
  };
}

export function toWithheld(r: WithheldRow): Withheld {
  return {
    txHash: r.txHash,
    blockNumber: Number(r.block),
    sender: r.sender,
    currency: r.currency,
    amount: r.amount.toString(),
  };
}

export function toFlag(r: FlagRow): Flag {
  return {
    txHash: r.txHash,
    blockNumber: Number(r.block),
    poolId: r.poolId,
    slashed: r.slashed.toString(),
    evidenceHash: r.evidenceHash,
    flaggedUntil: r.flaggedUntil.toString(),
  };
}

/** Parse ?limit= with a default and a hard ceiling. Non-numeric falls back to the default. */
export function parseLimit(raw: string | undefined, fallback: number, max: number): number {
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) return fallback;
  return Math.min(n, max);
}

export const POOL_ID_RE = /^0x[0-9a-fA-F]{64}$/;
export const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
