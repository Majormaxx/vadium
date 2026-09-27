import { ponder } from "ponder:registry";
import { and, eq, isNull } from "ponder";
import {
  blockPrice,
  bond,
  checkpoint,
  drain,
  flag,
  flush,
  pool,
  refund,
  slash,
  swap,
  withheld,
} from "ponder:schema";
import {
  type BondRow,
  type EventMeta,
  type Hex,
  type PoolRow,
  blockPriceFromCheckpointed,
  blockPriceFromSwap,
  bondAfterBonded,
  bondAfterFlagged,
  bondAfterSandwiched,
  bondAfterWithdrawn,
  lower,
  mapCheckpointed,
  mapClampWithheld,
  mapCoverageClaimed,
  mapFlagged,
  mapPoolRegistered,
  mapSandwiched,
  mapSwap,
  mapVictimRefundCredited,
  mapWithheldFlushed,
  poolAfterCheckpointed,
  poolAfterClampWithheld,
  poolAfterCoverageClaimed,
  poolAfterFlagged,
  poolAfterRefundCredited,
  poolAfterSandwiched,
  poolAfterUnclaimedSwept,
  poolAfterWithheldFlushed,
  settleRefunds,
} from "./mappers";

type Db = Parameters<Parameters<typeof ponder.on<"VadiumHook:Bonded">>[1]>[0]["context"]["db"];

const meta = (event: { block: { number: bigint; timestamp: bigint }; transaction: { hash: Hex }; log: { logIndex: number } }): EventMeta => ({
  block: event.block.number,
  timestamp: event.block.timestamp,
  txHash: event.transaction.hash,
  logIndex: event.log.logIndex,
});

async function upsertBond(db: Db, searcher: Hex, next: (prev: BondRow | undefined) => BondRow) {
  const id = lower(searcher);
  const prev = (await db.find(bond, { id })) ?? undefined;
  const row = next(prev);
  if (prev) {
    const { id: _id, ...patch } = row;
    await db.update(bond, { id }).set(patch);
  } else {
    await db.insert(bond).values(row);
  }
}

/** Patch a pool if it is registered. Flags relayed cross-chain carry a zero pool id. */
async function patchPool(db: Db, poolId: Hex, patch: (row: PoolRow) => Partial<Omit<PoolRow, "id">>) {
  const id = lower(poolId);
  const row = await db.find(pool, { id });
  if (!row) return;
  await db.update(pool, { id }).set(patch(row));
}

// ---------------------------------------------------------------------------
// Pools
// ---------------------------------------------------------------------------

ponder.on("VadiumHook:PoolRegistered", async ({ event, context }) => {
  const key = await context.client.readContract({
    abi: context.contracts.VadiumHook.abi,
    address: context.contracts.VadiumHook.address,
    functionName: "poolKeyOf",
    args: [event.args.poolId],
  });
  await context.db
    .insert(pool)
    .values(mapPoolRegistered(event.args, key, meta(event), context.chain.id))
    .onConflictDoNothing();
});

// ---------------------------------------------------------------------------
// Bonds
// ---------------------------------------------------------------------------

ponder.on("VadiumHook:Bonded", async ({ event, context }) => {
  await upsertBond(context.db, event.args.searcher, (prev) => bondAfterBonded(prev, event.args, meta(event)));
});

ponder.on("VadiumHook:BondWithdrawn", async ({ event, context }) => {
  await upsertBond(context.db, event.args.searcher, (prev) => bondAfterWithdrawn(prev, event.args, meta(event)));
});

// ---------------------------------------------------------------------------
// Penalties
// ---------------------------------------------------------------------------

ponder.on("VadiumHook:Sandwiched", async ({ event, context }) => {
  const m = meta(event);
  await context.db.insert(slash).values(mapSandwiched(event.args, m));
  await upsertBond(context.db, event.args.searcher, (prev) => bondAfterSandwiched(prev, event.args, m));
  await patchPool(context.db, event.args.poolId, (row) => poolAfterSandwiched(row, event.args));
});

ponder.on("VadiumHook:VictimRefundCredited", async ({ event, context }) => {
  await context.db.insert(refund).values(mapVictimRefundCredited(event.args, meta(event)));
  await patchPool(context.db, event.args.poolId, (row) => poolAfterRefundCredited(row, event.args));
});

ponder.on("VadiumHook:RefundClaimed", async ({ event, context }) => {
  const victim = lower(event.args.victim);
  const open = await context.db.sql
    .select()
    .from(refund)
    .where(and(eq(refund.victim, victim), isNull(refund.claimedTxHash), isNull(refund.sweptTxHash)));
  const settled = settleRefunds(open, event.transaction.hash, "claimed");
  for (const r of settled.rows) {
    await context.db.update(refund, { id: r.id }).set({ claimedTxHash: r.claimedTxHash });
  }
  for (const [poolId, amount] of settled.perPool) {
    await patchPool(context.db, poolId, (row) => ({ refundsClaimed: row.refundsClaimed + amount }));
  }
});

ponder.on("VadiumHook:UnclaimedSwept", async ({ event, context }) => {
  const key = lower(event.args.key);
  const open = await context.db.sql
    .select()
    .from(refund)
    .where(and(eq(refund.victim, key), isNull(refund.claimedTxHash), isNull(refund.sweptTxHash)));
  const settled = settleRefunds(open, event.transaction.hash, "swept");
  for (const r of settled.rows) {
    await context.db.update(refund, { id: r.id }).set({ sweptTxHash: r.sweptTxHash });
  }
  await patchPool(context.db, event.args.to, (row) => poolAfterUnclaimedSwept(row, event.args));
});

ponder.on("VadiumHook:Flagged", async ({ event, context }) => {
  const m = meta(event);
  await context.db.insert(flag).values(mapFlagged(event.args, m));
  await upsertBond(context.db, event.args.searcher, (prev) => bondAfterFlagged(prev, event.args, m));
  await patchPool(context.db, event.args.poolId, (row) => poolAfterFlagged(row, event.args));
});

ponder.on("VadiumHook:CoverageClaimed", async ({ event, context }) => {
  await context.db.insert(drain).values(mapCoverageClaimed(event.args, meta(event)));
  await patchPool(context.db, event.args.poolId, (row) => poolAfterCoverageClaimed(row, event.args));
});

// ---------------------------------------------------------------------------
// Block price clamp
// ---------------------------------------------------------------------------

ponder.on("VadiumHook:Checkpointed", async ({ event, context }) => {
  await context.db.insert(checkpoint).values(mapCheckpointed(event.args)).onConflictDoNothing();
  const bp = blockPriceFromCheckpointed(event.args);
  await context.db
    .insert(blockPrice)
    .values(bp)
    .onConflictDoUpdate({ startSqrtPriceX96: bp.startSqrtPriceX96 });
  await patchPool(context.db, event.args.poolId, () => poolAfterCheckpointed(event.args));
});

ponder.on("VadiumHook:ClampWithheld", async ({ event, context }) => {
  await context.db.insert(withheld).values(mapClampWithheld(event.args, meta(event)));
  await patchPool(context.db, event.args.poolId, (row) => poolAfterClampWithheld(row, event.args));
});

ponder.on("VadiumHook:WithheldFlushed", async ({ event, context }) => {
  await context.db.insert(flush).values(mapWithheldFlushed(event.args, meta(event)));
  await patchPool(context.db, event.args.poolId, (row) => poolAfterWithheldFlushed(row, event.args));
});

// ---------------------------------------------------------------------------
// PoolManager swaps (only for pools the hook registered)
// ---------------------------------------------------------------------------

ponder.on("PoolManager:Swap", async ({ event, context }) => {
  const registered = await context.db.find(pool, { id: lower(event.args.id) });
  if (!registered) return;
  const m = meta(event);
  await context.db.insert(swap).values(mapSwap(event.args, m));
  const bp = blockPriceFromSwap(event.args, m);
  await context.db
    .insert(blockPrice)
    .values(bp)
    .onConflictDoUpdate({ endSqrtPriceX96: bp.endSqrtPriceX96 });
});
