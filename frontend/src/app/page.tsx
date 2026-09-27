import type { Metadata } from "next";
import { indexer, describeError, type PoolSummary } from "@/lib/api";
import { pairLabel } from "@/lib/chain";
import { blocksAgo, feeToPercent, formatInt, formatUsdc, toBigInt } from "@/lib/format";
import { chainContext, readHookTotals } from "@/lib/onchain";
import { DataTable, type Column } from "@/components/DataTable";
import { Notice } from "@/components/Notice";
import { PoolLink, BlockLink } from "@/components/Links";
import { Stat, StatGrid } from "@/components/Stat";
import { Section } from "@/components/Section";

export const metadata: Metadata = { title: "Pools" };
export const dynamic = "force-dynamic";

export default async function HomePage() {
  const ctx = chainContext();
  const api = indexer();
  const [pools, status, totals] = await Promise.all([api.pools(), api.status(), readHookTotals(ctx)]);

  const head = status.ok ? status.data.headBlock : totals.ok ? totals.data.headBlock.toString() : null;
  const indexerDown = !pools.ok || !status.ok;

  const columns: Column<PoolSummary>[] = [
    {
      key: "pair",
      label: "Pair",
      render: (p) => <PoolLink poolId={p.poolId} label={pairLabel(p.chainId, p.currency0, p.currency1)} />,
    },
    { key: "fee", label: "Fee", align: "right", render: (p) => feeToPercent(p.fee) },
    { key: "reserve", label: "Reserve (USDC)", align: "right", render: (p) => formatUsdc(p.reserve) },
    { key: "sandwiches", label: "Sandwiches caught", align: "right", render: (p) => formatInt(p.sandwiches) },
    {
      key: "refunds",
      label: "Refunds credited / claimed",
      align: "right",
      render: (p) => `${formatUsdc(p.refundsCredited)} / ${formatUsdc(p.refundsClaimed)}`,
    },
    {
      key: "withheld",
      label: "Withheld",
      align: "right",
      render: (p) => (
        <span title="Raw units of currency0 / currency1 withheld from clamped swaps">
          {formatInt(p.withheld0)} / {formatInt(p.withheld1)}
        </span>
      ),
    },
    { key: "bonded", label: "Bonded", align: "right", render: (p) => formatInt(p.bondedCount) },
    {
      key: "checkpoint",
      label: "Last checkpoint",
      align: "right",
      render: (p) =>
        p.lastCheckpoint ? (
          <span>
            <BlockLink chainId={p.chainId} block={p.lastCheckpoint.blockNumber} />
            <span className="muted"> {blocksAgo(p.lastCheckpoint.blockNumber, head)}</span>
          </span>
        ) : (
          <span className="muted">none</span>
        ),
    },
  ];

  return (
    <div>
      <h1>Pools</h1>
      <p className="muted mt-1 max-w-prose text-sm">
        Every pool registered with the hook on {ctx.chainName}. Unbonded swaps are held to the block start price;
        bonded searchers trade at the real price and are slashed if they sandwich.
      </p>

      <div className="mt-5">
        <StatGrid>
          <Stat
            label="Indexed block"
            value={status.ok ? formatInt(status.data.indexedBlock) : "n/a"}
            hint={status.ok ? "from the indexer" : describeError(status.error)}
          />
          <Stat
            label="Head block"
            value={head ? formatInt(head) : "n/a"}
            hint={status.ok && status.data.headBlock ? "from the indexer" : totals.ok ? "from the RPC" : "unavailable"}
          />
          <Stat
            label="Indexer lag"
            value={status.ok && status.data.lag !== null ? `${formatInt(status.data.lag)} blocks` : "n/a"}
            hint={status.ok ? lagHint(status.data.lag) : "indexer unavailable"}
          />
          <Stat
            label="Hook"
            value={totals.ok ? (totals.data.paused ? "paused" : "live") : "n/a"}
            hint={
              totals.ok
                ? `${formatUsdc(totals.data.totalBonded)} USDC bonded, ${formatUsdc(totals.data.totalReserve)} in reserves`
                : totals.error
            }
          />
        </StatGrid>
      </div>

      {indexerDown ? (
        <div className="mt-5">
          <Notice title="Indexer unavailable">
            {!pools.ok ? describeError(pools.error) : status.ok ? "" : describeError(status.error)}. The pool list
            comes from the indexer at <span className="mono">{api.baseUrl}</span>. Hook-wide totals above are read
            from the chain and stay current.
          </Notice>
        </div>
      ) : null}

      <Section
        title="Registered pools"
        aside={pools.ok ? `${pools.data.length} pool${pools.data.length === 1 ? "" : "s"}` : undefined}
      >
        <DataTable
          columns={columns}
          rows={pools.ok ? pools.data : []}
          rowKey={(p) => p.poolId}
          empty={pools.ok ? "No pools registered yet." : "Pool list unavailable while the indexer is down."}
        />
      </Section>
    </div>
  );
}

function lagHint(lag: string | null): string {
  if (lag === null) return "head block unknown";
  const n = toBigInt(lag);
  if (n <= 2n) return "caught up";
  if (n <= 60n) return "catching up";
  return "behind";
}
