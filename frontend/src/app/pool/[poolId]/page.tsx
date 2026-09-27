import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { indexer, describeError, type BondedItem, type RefundItem, type SlashItem, type WithheldItem } from "@/lib/api";
import { isPoolId, pairLabel, tokenInfo } from "@/lib/chain";
import {
  blocksAgo,
  feeToPercent,
  formatInt,
  formatPrice,
  formatTimestamp,
  formatUnits,
  formatUsdc,
  shortHash,
  sqrtPriceX96ToPrice,
  toBigInt,
} from "@/lib/format";
import { formatDeviation, seriesValues } from "@/lib/staleness";
import { chainContext, readPoolOnchain } from "@/lib/onchain";
import { DataTable, type Column } from "@/components/DataTable";
import { AddressLink, BlockLink, SearcherLink, TxLink } from "@/components/Links";
import { Notice } from "@/components/Notice";
import { Section } from "@/components/Section";
import { Sparkline } from "@/components/Sparkline";
import { Stat, StatGrid } from "@/components/Stat";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ poolId: string }> };

export async function generateMetadata({ params }: Params): Promise<Metadata> {
  const { poolId } = await params;
  return { title: `Pool ${shortHash(poolId)}` };
}

const STALENESS_WINDOW = 1000;

export default async function PoolPage({ params }: Params) {
  const { poolId } = await params;
  if (!isPoolId(poolId)) notFound();

  const ctx = chainContext();
  const api = indexer();
  const [pool, slashes, refunds, bonded, withheld, staleness, status, chain] = await Promise.all([
    api.pool(poolId),
    api.slashes(poolId, 50),
    api.refunds(poolId),
    api.bonded(poolId),
    api.withheld(poolId),
    api.staleness(poolId, STALENESS_WINDOW),
    api.status(),
    readPoolOnchain(poolId, ctx),
  ]);

  if (!pool.ok && pool.error.kind === "not_found") notFound();

  const chainId = pool.ok ? pool.data.chainId : ctx.chainId;
  const head = status.ok ? status.data.headBlock : chain.ok ? chain.data.headBlock.toString() : null;
  const indexerDown = !pool.ok;

  const title = pool.ok ? pairLabel(chainId, pool.data.currency0, pool.data.currency1) : `Pool ${shortHash(poolId)}`;
  const token0 = pool.ok ? tokenInfo(chainId, pool.data.currency0) : null;
  const token1 = pool.ok ? tokenInfo(chainId, pool.data.currency1) : null;

  const reserve = pool.ok ? pool.data.reserve : chain.ok ? chain.data.insuranceReserve : null;
  const slashedPledged = pool.ok ? pool.data.slashedPledged : chain.ok ? chain.data.slashedPledged : null;
  const withdrawn = pool.ok ? pool.data.withdrawn : chain.ok ? chain.data.withdrawn : null;
  const checkpoint = pool.ok
    ? pool.data.lastCheckpoint
    : chain.ok && chain.data.checkpoint.blockNumber > 0n
      ? {
          blockNumber: chain.data.checkpoint.blockNumber.toString(),
          sqrtPriceX96: chain.data.checkpoint.sqrtPriceX96.toString(),
          liquidity: chain.data.checkpoint.liquidity.toString(),
        }
      : null;
  const source = pool.ok ? "from the indexer" : chain.ok ? "read from the chain" : "unavailable";

  const price =
    checkpoint && token0 && token1
      ? formatPrice(sqrtPriceX96ToPrice(checkpoint.sqrtPriceX96, token0.decimals, token1.decimals))
      : checkpoint
        ? formatPrice(sqrtPriceX96ToPrice(checkpoint.sqrtPriceX96, 18, 6))
        : null;

  const stale = staleness.ok ? staleness.data : pool.ok ? pool.data.staleness : null;
  const series = stale ? seriesValues(stale.series) : [];

  const slashColumns: Column<SlashItem>[] = [
    { key: "tx", label: "Tx", render: (s) => <TxLink chainId={chainId} hash={s.txHash} /> },
    { key: "block", label: "Block", align: "right", render: (s) => <BlockLink chainId={chainId} block={s.blockNumber} /> },
    { key: "time", label: "Time", render: (s) => formatTimestamp(s.timestamp) || "n/a" },
    { key: "searcher", label: "Searcher", render: (s) => <SearcherLink address={s.searcher} /> },
    { key: "slashed", label: "Slashed (USDC)", align: "right", render: (s) => formatUsdc(s.slashed) },
    { key: "refunded", label: "Refunded (USDC)", align: "right", render: (s) => formatUsdc(s.refunded) },
    { key: "remaining", label: "Bond left (USDC)", align: "right", render: (s) => formatUsdc(s.remaining) },
    {
      key: "repeat",
      label: "Strike",
      render: (s) => (s.isRepeat ? <span className="pill" data-tone="bad">repeat, banned</span> : <span className="pill" data-tone="warn">first</span>),
    },
    { key: "flagged", label: "Flagged until", align: "right", render: (s) => formatInt(s.flaggedUntil) },
  ];

  const refundColumns: Column<RefundItem>[] = [
    { key: "tx", label: "Tx", render: (r) => <TxLink chainId={chainId} hash={r.txHash} /> },
    { key: "block", label: "Block", align: "right", render: (r) => <BlockLink chainId={chainId} block={r.blockNumber} /> },
    { key: "victim", label: "Victim", render: (r) => <AddressLink chainId={chainId} address={r.victim} /> },
    { key: "searcher", label: "Searcher", render: (r) => <SearcherLink address={r.searcher} /> },
    { key: "amount", label: "Amount (USDC)", align: "right", render: (r) => formatUsdc(r.amount) },
    {
      key: "claimed",
      label: "Status",
      render: (r) => (r.claimed ? <span className="pill" data-tone="ok">claimed</span> : <span className="pill">claimable</span>),
    },
  ];

  const bondedColumns: Column<BondedItem>[] = [
    { key: "searcher", label: "Searcher", render: (b) => <SearcherLink address={b.searcher} /> },
    { key: "amount", label: "Bond (USDC)", align: "right", render: (b) => formatUsdc(b.amount) },
    {
      key: "deposit",
      label: "Deposited",
      align: "right",
      render: (b) => (
        <span>
          <BlockLink chainId={chainId} block={b.depositBlock} />
          <span className="muted"> {blocksAgo(b.depositBlock, head)}</span>
        </span>
      ),
    },
    { key: "strikes", label: "Strikes", align: "right", render: (b) => formatInt(b.strikeCount) },
    { key: "banned", label: "Banned until", align: "right", render: (b) => untilLabel(b.bannedUntil, head) },
    { key: "flagged", label: "Flagged until", align: "right", render: (b) => untilLabel(b.flaggedUntil, head) },
  ];

  const withheldColumns: Column<WithheldItem>[] = [
    { key: "tx", label: "Tx", render: (w) => <TxLink chainId={chainId} hash={w.txHash} /> },
    { key: "block", label: "Block", align: "right", render: (w) => <BlockLink chainId={chainId} block={w.blockNumber} /> },
    { key: "sender", label: "Sender", render: (w) => <AddressLink chainId={chainId} address={w.sender} /> },
    { key: "currency", label: "Currency", render: (w) => tokenInfo(chainId, w.currency).symbol },
    {
      key: "amount",
      label: "Amount",
      align: "right",
      render: (w) => {
        const info = tokenInfo(chainId, w.currency);
        return `${formatUnits(w.amount, info.decimals, { minFraction: 2, maxFraction: 6 })} ${info.symbol}`;
      },
    },
  ];

  return (
    <div>
      <h1>{title}</h1>
      <div className="muted mt-1 text-sm">
        <span className="mono">{poolId}</span>
        {pool.ok ? (
          <span>
            {" "}
            fee {feeToPercent(pool.data.fee)}, tick spacing {pool.data.tickSpacing}, {formatInt(pool.data.bondedCount)}{" "}
            bonded
          </span>
        ) : null}
      </div>

      {indexerDown ? (
        <div className="mt-4">
          <Notice title="Indexer unavailable">
            {describeError(pool.error)}. Reserve, slashed, withdrawn, and the checkpoint below are read from the chain
            {chain.ok ? "" : `, which also failed: ${chain.error}`}. History tables need the indexer.
          </Notice>
        </div>
      ) : null}

      <div className="mt-5">
        <StatGrid>
          <Stat label="Insurance reserve" value={reserve !== null ? `${formatUsdc(reserve)} USDC` : "n/a"} hint={source} />
          <Stat label="Slashed pledged" value={slashedPledged !== null ? `${formatUsdc(slashedPledged)} USDC` : "n/a"} hint="total ever slashed into this pool" />
          <Stat label="Withdrawn to LPs" value={withdrawn !== null ? `${formatUsdc(withdrawn)} USDC` : "n/a"} hint="drained or claimed as coverage" />
          <Stat
            label="Last checkpoint"
            value={checkpoint ? <BlockLink chainId={chainId} block={checkpoint.blockNumber} /> : "none"}
            hint={
              checkpoint
                ? `${blocksAgo(checkpoint.blockNumber, head)}${price ? `, price ${price} ${token1?.symbol ?? ""} per ${token0?.symbol ?? ""}`.trimEnd() : ""}`
                : "no swap has checkpointed this pool yet"
            }
          />
        </StatGrid>
      </div>

      <Section title="Block start staleness" aside={stale ? `last ${formatInt(stale.window)} blocks, ${formatInt(stale.count)} with swaps` : undefined}>
        <div className="card">
          {stale ? (
            <div className="grid grid-cols-1 gap-4 md:grid-cols-[1fr_2fr]">
              <dl className="kv">
                <dt>p50</dt>
                <dd>{formatDeviation(stale.p50)}</dd>
                <dt>p95</dt>
                <dd>{formatDeviation(stale.p95)}</dd>
                <dt>mean</dt>
                <dd>{formatDeviation(stale.mean)}</dd>
                <dt>points</dt>
                <dd>{formatInt(series.length)}</dd>
              </dl>
              <div>
                <Sparkline values={series} label={`Per-block price drift over the last ${stale.window} blocks`} />
                {series.length === 0 ? <div className="muted text-sm">No blocks with a swap in this window.</div> : null}
              </div>
            </div>
          ) : (
            <div className="muted text-sm">
              {staleness.ok ? "No staleness data yet." : describeError(staleness.error)}
            </div>
          )}
          <p className="muted mt-3 text-sm">
            Drift between the block start price the clamp used and the price at the end of that block. Low drift means
            bonded arbitrage is keeping the checkpoint near market; high drift means unbonded flow was clamped to a
            stale price.
          </p>
        </div>
      </Section>

      <Section title="Slashes" aside={slashes.ok ? `${formatInt(slashes.data.length)} shown` : undefined}>
        <DataTable columns={slashColumns} rows={slashes.ok ? slashes.data : []} rowKey={(s, i) => `${s.txHash}-${i}`} empty={slashes.ok ? "No sandwich has been slashed in this pool." : describeError(slashes.error)} />
      </Section>

      <Section title="Refunds" aside={refunds.ok ? `${formatInt(refunds.data.length)} credited` : undefined}>
        <DataTable columns={refundColumns} rows={refunds.ok ? refunds.data : []} rowKey={(r, i) => `${r.txHash}-${i}`} empty={refunds.ok ? "No victim has been credited yet." : describeError(refunds.error)} />
      </Section>

      <Section title="Bonded addresses" aside={bonded.ok ? `${formatInt(bonded.data.length)} live` : undefined}>
        <DataTable columns={bondedColumns} rows={bonded.ok ? bonded.data : []} rowKey={(b) => b.searcher} empty={bonded.ok ? "Nobody has bonded yet." : describeError(bonded.error)} />
      </Section>

      <Section title="Withheld from clamped swaps" aside={withheld.ok ? `${formatInt(withheld.data.length)} events` : undefined}>
        <DataTable columns={withheldColumns} rows={withheld.ok ? withheld.data : []} rowKey={(w, i) => `${w.txHash}-${i}`} empty={withheld.ok ? "No clamped swap has beaten the block start price yet." : describeError(withheld.error)} />
      </Section>

      <Section title="What these numbers mean">
        <div className="prose text-sm">
          <ul>
            <li>
              <strong>Insurance reserve</strong> is the bond token this pool holds from slashes after victims were
              credited. The keeper drains it to in-range LPs, capped per call; the owner can also pay it out as
              coverage. Reserve equals slashed pledged minus withdrawn.
            </li>
            <li>
              <strong>Slashed pledged</strong> is everything ever slashed into this pool, victim share included.
              <strong> Withdrawn</strong> is the part already paid out to LPs.
            </li>
            <li>
              <strong>Last checkpoint</strong> is the block start price and in-range liquidity snapshot the clamp
              compares later swaps against. It is taken at the first swap of a block; a pool with no swaps keeps its
              last one.
            </li>
            <li>
              <strong>Staleness</strong> is the drift between that snapshot and the price at block end, one point per
              block with a swap. Bonded arbitrage moves the price; unbonded flow is held to the snapshot.
            </li>
            <li>
              <strong>Slashes</strong> list every detector hit: a bonded address swapped, another address got a worse
              price than block start, and the bonded address reversed direction in the same block. First strike takes
              half the bond; a repeat inside the escalation window takes the rest and bans the address.
            </li>
            <li>
              <strong>Refunds</strong> are victim credits, the smaller of the measured loss and half the slash,
              claimable by whoever the victim&apos;s router named. Unclaimed credits can be swept into the reserve after
              the claim window.
            </li>
            <li>
              <strong>Bonded addresses</strong> are routers with a live bond. A bonded address is exempt from the clamp
              on its first swap of each block unless it is banned, flagged, or the hook is paused.
            </li>
            <li>
              <strong>Withheld</strong> events record a clamped swap that did better than the block start target; the
              difference is held as ERC-6909 claims and anyone can flush it to the pool&apos;s LPs.
            </li>
          </ul>
        </div>
      </Section>
    </div>
  );
}

function untilLabel(until: string, head: string | null) {
  const u = toBigInt(until);
  if (u === 0n) return <span className="muted">no</span>;
  if (head !== null && toBigInt(head) >= u) return <span className="muted">expired ({formatInt(u)})</span>;
  return <span>{formatInt(u)}</span>;
}
