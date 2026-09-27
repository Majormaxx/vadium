import { Hono } from "hono";
import { cors } from "hono/cors";
import { db, publicClients } from "ponder:api";
import { and, count, desc, eq, gt, isNotNull, sql } from "ponder";
import { blockPrice, bond, flag, pool, refund, slash, withheld } from "ponder:schema";
import deployments from "../../generated/deployments.json";
import { activeChain, deploymentFor } from "../chains";
import { summarizeStaleness } from "../staleness";
import {
  ADDRESS_RE,
  POOL_ID_RE,
  type Status,
  parseLimit,
  toBond,
  toFlag,
  toPoolSummary,
  toRefund,
  toSlash,
  toWithheld,
} from "./dto";

const chain = activeChain();
const deployment = deploymentFor(deployments, chain);

const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 500;
const DEFAULT_WINDOW = 1000;
const MAX_WINDOW = 10_000;

const app = new Hono();

app.use("*", cors({ origin: "*", allowMethods: ["GET", "OPTIONS"], maxAge: 86_400 }));

async function bondedCount(): Promise<number> {
  const [row] = await db.select({ n: count() }).from(bond).where(gt(bond.amount, 0n));
  return row?.n ?? 0;
}

async function staleness(poolId: `0x${string}`, window: number) {
  const rows = await db
    .select()
    .from(blockPrice)
    .where(and(eq(blockPrice.poolId, poolId), isNotNull(blockPrice.startSqrtPriceX96), isNotNull(blockPrice.endSqrtPriceX96)))
    .orderBy(desc(blockPrice.block))
    .limit(window);
  const samples = rows
    .reverse()
    .map((r) => ({ block: r.block, startSqrtPriceX96: r.startSqrtPriceX96!, endSqrtPriceX96: r.endSqrtPriceX96! }));
  return summarizeStaleness(samples, window);
}

/** Validate and lower-case a pool id path param, or answer 404. */
function poolIdParam(raw: string): `0x${string}` | null {
  return POOL_ID_RE.test(raw) ? (raw.toLowerCase() as `0x${string}`) : null;
}

app.get("/pools", async (c) => {
  const [rows, bonded] = await Promise.all([db.select().from(pool).orderBy(pool.registeredBlock), bondedCount()]);
  return c.json({ pools: rows.map((p) => toPoolSummary(p, bonded)) });
});

app.get("/pools/:id", async (c) => {
  const id = poolIdParam(c.req.param("id"));
  const row = id ? await db.query.pool.findFirst({ where: eq(pool.id, id) }) : undefined;
  if (!id || !row) return c.json({ error: "pool not found" }, 404);
  const [bonded, stale] = await Promise.all([bondedCount(), staleness(id, DEFAULT_WINDOW)]);
  return c.json({ ...toPoolSummary(row, bonded), staleness: stale });
});

app.get("/pools/:id/slashes", async (c) => {
  const id = poolIdParam(c.req.param("id"));
  const row = id ? await db.query.pool.findFirst({ where: eq(pool.id, id) }) : undefined;
  if (!id || !row) return c.json({ error: "pool not found" }, 404);
  const limit = parseLimit(c.req.query("limit"), DEFAULT_LIMIT, MAX_LIMIT);
  const rows = await db.select().from(slash).where(eq(slash.poolId, id)).orderBy(desc(slash.block), desc(slash.id)).limit(limit);
  return c.json({ items: rows.map(toSlash) });
});

app.get("/pools/:id/refunds", async (c) => {
  const id = poolIdParam(c.req.param("id"));
  const row = id ? await db.query.pool.findFirst({ where: eq(pool.id, id) }) : undefined;
  if (!id || !row) return c.json({ error: "pool not found" }, 404);
  const limit = parseLimit(c.req.query("limit"), DEFAULT_LIMIT, MAX_LIMIT);
  const rows = await db.select().from(refund).where(eq(refund.poolId, id)).orderBy(desc(refund.block), desc(refund.id)).limit(limit);
  return c.json({ items: rows.map(toRefund) });
});

// Bonds are hook-wide, so every registered pool lists the same set.
app.get("/pools/:id/bonded", async (c) => {
  const id = poolIdParam(c.req.param("id"));
  const row = id ? await db.query.pool.findFirst({ where: eq(pool.id, id) }) : undefined;
  if (!id || !row) return c.json({ error: "pool not found" }, 404);
  const rows = await db.select().from(bond).where(gt(bond.amount, 0n)).orderBy(desc(bond.amount));
  return c.json({ items: rows.map(toBond) });
});

app.get("/pools/:id/withheld", async (c) => {
  const id = poolIdParam(c.req.param("id"));
  const row = id ? await db.query.pool.findFirst({ where: eq(pool.id, id) }) : undefined;
  if (!id || !row) return c.json({ error: "pool not found" }, 404);
  const limit = parseLimit(c.req.query("limit"), DEFAULT_LIMIT, MAX_LIMIT);
  const rows = await db.select().from(withheld).where(eq(withheld.poolId, id)).orderBy(desc(withheld.block), desc(withheld.id)).limit(limit);
  return c.json({ items: rows.map(toWithheld) });
});

app.get("/pools/:id/staleness", async (c) => {
  const id = poolIdParam(c.req.param("id"));
  const row = id ? await db.query.pool.findFirst({ where: eq(pool.id, id) }) : undefined;
  if (!id || !row) return c.json({ error: "pool not found" }, 404);
  const window = parseLimit(c.req.query("window"), DEFAULT_WINDOW, MAX_WINDOW);
  return c.json(await staleness(id, window));
});

app.get("/searchers/:address", async (c) => {
  const raw = c.req.param("address");
  if (!ADDRESS_RE.test(raw)) return c.json({ error: "invalid address" }, 400);
  const searcher = raw.toLowerCase() as `0x${string}`;
  const [bondRow, slashes, flags] = await Promise.all([
    db.query.bond.findFirst({ where: eq(bond.id, searcher) }),
    db.select().from(slash).where(eq(slash.searcher, searcher)).orderBy(desc(slash.block), desc(slash.id)).limit(MAX_LIMIT),
    db.select().from(flag).where(eq(flag.searcher, searcher)).orderBy(desc(flag.block), desc(flag.id)).limit(MAX_LIMIT),
  ]);
  return c.json({
    searcher,
    bond: bondRow ? toBond(bondRow) : null,
    slashes: slashes.map(toSlash),
    flags: flags.map(toFlag),
  });
});

// Ponder reserves GET /status for its own per-chain progress payload and answers
// it before user routes, so the app-level status lives here.
app.get("/indexer/status", async (c) => {
  // Ponder's checkpoint string: 10 digits timestamp, 16 chain id, 16 block number, ...
  const rows = await db.execute(
    sql`select latest_checkpoint from _ponder_checkpoint where chain_id = ${chain.id}`,
  );
  const checkpointRow = (rows as { rows?: { latest_checkpoint: string }[] }).rows?.[0]
    ?? (Array.isArray(rows) ? (rows as { latest_checkpoint: string }[])[0] : undefined);
  const indexedBlock = checkpointRow ? Number(checkpointRow.latest_checkpoint.slice(26, 42)) : 0;

  let headBlock: number | null = null;
  try {
    headBlock = Number(await publicClients[chain.name]!.getBlockNumber());
  } catch {
    headBlock = null;
  }

  const body: Status = {
    chainId: chain.id,
    indexedBlock,
    headBlock,
    hook: deployment.hook.toLowerCase(),
    lag: headBlock === null ? null : headBlock - indexedBlock,
  };
  return c.json(body);
});

export default app;
