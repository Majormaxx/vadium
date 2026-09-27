// Direct reads from the hook through viem. Used so every page shows live
// numbers even when the indexer is down. Each reader returns a result object
// rather than throwing.

import { createPublicClient, http, parseAbi, type Address, type Hex } from "viem";
import { chainFor, chainIdFromEnv, hookAddressFor, rpcUrlFromEnv } from "./chain";

export const hookAbi = parseAbi([
  "function insuranceReserve(bytes32 poolId) view returns (uint256)",
  "function slashedPledged(bytes32 poolId) view returns (uint256)",
  "function totalWithdrawn(bytes32 poolId) view returns (uint256)",
  "function totalBonded() view returns (uint256)",
  "function totalReserve() view returns (uint256)",
  "function totalClaimable() view returns (uint256)",
  "function paused() view returns (bool)",
  "function checkpoint(bytes32 poolId) view returns ((uint48 blockNumber, uint160 sqrtPriceX96, uint128 liquidity, uint24 fee, uint24 protocolFee))",
  "function bonds(address searcher) view returns (uint128 amount, uint48 depositBlock, uint48 bannedUntil, uint32 strikeCount, uint48 lastStrikeBlock)",
  "function flaggedUntil(address searcher) view returns (uint256)",
  "function isBanned(address searcher) view returns (bool)",
  "function isBonded(address searcher) view returns (bool)",
  "function claimableRefund(address searcher) view returns (uint256)",
]);

export type ChainResult<T> = { ok: true; data: T } | { ok: false; error: string };

export type ChainContext = {
  chainId: number;
  chainName: string;
  rpcUrl: string;
  hook: Address | undefined;
};

export function chainContext(): ChainContext {
  const chainId = chainIdFromEnv();
  const chain = chainFor(chainId);
  return {
    chainId,
    chainName: chain?.name ?? `chain ${chainId}`,
    rpcUrl: rpcUrlFromEnv(chain),
    hook: hookAddressFor(chainId),
  };
}

function client(ctx: ChainContext) {
  return createPublicClient({
    chain: chainFor(ctx.chainId),
    transport: http(ctx.rpcUrl, { timeout: 8_000, retryCount: 1 }),
  });
}

function fail(err: unknown): { ok: false; error: string } {
  const message = err instanceof Error ? err.message.split("\n")[0] : String(err);
  return { ok: false, error: message };
}

export type HookTotals = {
  totalBonded: bigint;
  totalReserve: bigint;
  totalClaimable: bigint;
  paused: boolean;
  headBlock: bigint;
};

export async function readHookTotals(ctx = chainContext()): Promise<ChainResult<HookTotals>> {
  if (!ctx.hook) return { ok: false, error: "no hook address configured for this chain" };
  const c = client(ctx);
  const hook = ctx.hook;
  try {
    const [totalBonded, totalReserve, totalClaimable, paused, headBlock] = await Promise.all([
      c.readContract({ address: hook, abi: hookAbi, functionName: "totalBonded" }),
      c.readContract({ address: hook, abi: hookAbi, functionName: "totalReserve" }),
      c.readContract({ address: hook, abi: hookAbi, functionName: "totalClaimable" }),
      c.readContract({ address: hook, abi: hookAbi, functionName: "paused" }),
      c.getBlockNumber(),
    ]);
    return { ok: true, data: { totalBonded, totalReserve, totalClaimable, paused, headBlock } };
  } catch (err) {
    return fail(err);
  }
}

export type PoolOnchain = {
  insuranceReserve: bigint;
  slashedPledged: bigint;
  withdrawn: bigint;
  checkpoint: { blockNumber: bigint; sqrtPriceX96: bigint; liquidity: bigint };
  headBlock: bigint;
};

export async function readPoolOnchain(
  poolId: Hex,
  ctx = chainContext(),
): Promise<ChainResult<PoolOnchain>> {
  if (!ctx.hook) return { ok: false, error: "no hook address configured for this chain" };
  const c = client(ctx);
  const hook = ctx.hook;
  try {
    const [insuranceReserve, slashedPledged, withdrawn, cp, headBlock] = await Promise.all([
      c.readContract({ address: hook, abi: hookAbi, functionName: "insuranceReserve", args: [poolId] }),
      c.readContract({ address: hook, abi: hookAbi, functionName: "slashedPledged", args: [poolId] }),
      c.readContract({ address: hook, abi: hookAbi, functionName: "totalWithdrawn", args: [poolId] }),
      c.readContract({ address: hook, abi: hookAbi, functionName: "checkpoint", args: [poolId] }),
      c.getBlockNumber(),
    ]);
    return {
      ok: true,
      data: {
        insuranceReserve,
        slashedPledged,
        withdrawn,
        checkpoint: {
          blockNumber: BigInt(cp.blockNumber),
          sqrtPriceX96: cp.sqrtPriceX96,
          liquidity: cp.liquidity,
        },
        headBlock,
      },
    };
  } catch (err) {
    return fail(err);
  }
}

export type SearcherOnchain = {
  amount: bigint;
  depositBlock: bigint;
  bannedUntil: bigint;
  strikeCount: number;
  lastStrikeBlock: bigint;
  flaggedUntil: bigint;
  isBanned: boolean;
  isBonded: boolean;
  claimableRefund: bigint;
  headBlock: bigint;
};

export async function readSearcherOnchain(
  address: Address,
  ctx = chainContext(),
): Promise<ChainResult<SearcherOnchain>> {
  if (!ctx.hook) return { ok: false, error: "no hook address configured for this chain" };
  const c = client(ctx);
  const hook = ctx.hook;
  try {
    const [bond, flaggedUntil, isBanned, isBonded, claimableRefund, headBlock] = await Promise.all([
      c.readContract({ address: hook, abi: hookAbi, functionName: "bonds", args: [address] }),
      c.readContract({ address: hook, abi: hookAbi, functionName: "flaggedUntil", args: [address] }),
      c.readContract({ address: hook, abi: hookAbi, functionName: "isBanned", args: [address] }),
      c.readContract({ address: hook, abi: hookAbi, functionName: "isBonded", args: [address] }),
      c.readContract({ address: hook, abi: hookAbi, functionName: "claimableRefund", args: [address] }),
      c.getBlockNumber(),
    ]);
    const [amount, depositBlock, bannedUntil, strikeCount, lastStrikeBlock] = bond;
    return {
      ok: true,
      data: {
        amount,
        depositBlock: BigInt(depositBlock),
        bannedUntil: BigInt(bannedUntil),
        strikeCount,
        lastStrikeBlock: BigInt(lastStrikeBlock),
        flaggedUntil,
        isBanned,
        isBonded,
        claimableRefund,
        headBlock,
      },
    };
  } catch (err) {
    return fail(err);
  }
}

export type PoolStatusOnchain = HookTotals & { poolId: Hex | null; insuranceReserve: bigint | null };

/** Everything the status page shows from chain: hook-wide totals plus one pool's reserve. */
export async function readStatusOnchain(
  poolId: Hex | null,
  ctx = chainContext(),
): Promise<ChainResult<PoolStatusOnchain>> {
  const totals = await readHookTotals(ctx);
  if (!totals.ok) return totals;
  if (!poolId || !ctx.hook) return { ok: true, data: { ...totals.data, poolId: null, insuranceReserve: null } };
  try {
    const insuranceReserve = await client(ctx).readContract({
      address: ctx.hook,
      abi: hookAbi,
      functionName: "insuranceReserve",
      args: [poolId],
    });
    return { ok: true, data: { ...totals.data, poolId, insuranceReserve } };
  } catch (err) {
    return fail(err);
  }
}
