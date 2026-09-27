import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { isAddress } from "viem";
import { indexer, describeError, type FlagItem, type SlashItem } from "@/lib/api";
import { blocksAgo, formatInt, formatTimestamp, formatUsdc, shortAddress, toBigInt } from "@/lib/format";
import { chainContext, readSearcherOnchain } from "@/lib/onchain";
import { DataTable, type Column } from "@/components/DataTable";
import { AddressLink, BlockLink, PoolLink, TxLink } from "@/components/Links";
import { Notice } from "@/components/Notice";
import { Section } from "@/components/Section";
import { Stat, StatGrid } from "@/components/Stat";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ address: string }> };

export async function generateMetadata({ params }: Params): Promise<Metadata> {
  const { address } = await params;
  return { title: `Searcher ${shortAddress(address)}` };
}

export default async function SearcherPage({ params }: Params) {
  const { address } = await params;
  if (!isAddress(address)) notFound();

  const ctx = chainContext();
  const api = indexer();
  const [searcher, status, chain] = await Promise.all([
    api.searcher(address),
    api.status(),
    readSearcherOnchain(address, ctx),
  ]);

  const indexed = searcher.ok ? searcher.data : null;
  const indexerDown = !searcher.ok && searcher.error.kind !== "not_found";
  const head = status.ok ? status.data.headBlock : chain.ok ? chain.data.headBlock.toString() : null;
  const chainId = ctx.chainId;

  // Prefer the live bond from chain; fall back to the indexer's view.
  const bond = chain.ok
    ? chain.data.amount > 0n
      ? {
          amount: chain.data.amount.toString(),
          depositBlock: chain.data.depositBlock.toString(),
          strikeCount: chain.data.strikeCount,
          bannedUntil: chain.data.bannedUntil.toString(),
          flaggedUntil: chain.data.flaggedUntil.toString(),
        }
      : null
    : (indexed?.bond ?? null);
  const bondSource = chain.ok ? "read from the chain" : indexed ? "from the indexer" : "unavailable";

  const strikes = chain.ok ? chain.data.strikeCount : (bond?.strikeCount ?? 0);
  const bannedUntil = chain.ok ? chain.data.bannedUntil.toString() : (bond?.bannedUntil ?? "0");
  const flaggedUntil = chain.ok ? chain.data.flaggedUntil.toString() : (bond?.flaggedUntil ?? "0");

  const slashColumns: Column<SlashItem>[] = [
    { key: "tx", label: "Tx", render: (s) => <TxLink chainId={chainId} hash={s.txHash} /> },
    { key: "block", label: "Block", align: "right", render: (s) => <BlockLink chainId={chainId} block={s.blockNumber} /> },
    { key: "time", label: "Time", render: (s) => formatTimestamp(s.timestamp) || "n/a" },
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

  const flagColumns: Column<FlagItem>[] = [
    { key: "tx", label: "Tx", render: (f) => <TxLink chainId={chainId} hash={f.txHash} /> },
    { key: "block", label: "Block", align: "right", render: (f) => <BlockLink chainId={chainId} block={f.blockNumber} /> },
    { key: "pool", label: "Pool", render: (f) => <PoolLink poolId={f.poolId} /> },
    { key: "slashed", label: "Slashed (USDC)", align: "right", render: (f) => formatUsdc(f.slashed) },
    {
      key: "evidence",
      label: "Evidence hash",
      render: (f) => (
        <span className="mono" title={f.evidenceHash}>
          {shortAddress(f.evidenceHash, 8)}
        </span>
      ),
    },
    { key: "until", label: "Flagged until", align: "right", render: (f) => formatInt(f.flaggedUntil) },
  ];

  return (
    <div>
      <h1>Searcher</h1>
      <div className="mt-1 text-sm">
        <AddressLink chainId={chainId} address={address} full />
        <span className="muted"> on {ctx.chainName}. This is the router address the hook sees, not a wallet.</span>
      </div>

      {indexerDown ? (
        <div className="mt-4">
          <Notice title="Indexer unavailable">
            {describeError(searcher.error)}. The bond card is read from the chain{chain.ok ? "" : `, which also failed: ${chain.error}`}. Slash and flag history need the indexer.
          </Notice>
        </div>
      ) : null}

      <div className="mt-5">
        <StatGrid>
          <Stat label="Bond" value={bond ? `${formatUsdc(bond.amount)} USDC` : "none"} hint={bondSource} />
          <Stat
            label="Deposited"
            value={bond ? <BlockLink chainId={chainId} block={bond.depositBlock} /> : "n/a"}
            hint={bond ? blocksAgo(bond.depositBlock, head) : "no live bond"}
          />
          <Stat label="Strikes" value={formatInt(strikes)} hint="never decreases, even across re-bonds" />
          <Stat
            label="Exempt from clamp"
            value={exemptLabel(bond, bannedUntil, flaggedUntil, head)}
            hint={exemptHint(bannedUntil, flaggedUntil, head)}
          />
        </StatGrid>
      </div>

      {chain.ok && chain.data.claimableRefund > 0n ? (
        <div className="mt-4">
          <Notice tone="info" title={`${formatUsdc(chain.data.claimableRefund)} USDC claimable`}>
            This address holds an unclaimed victim refund credit. It is claimable by calling <span className="mono">claimRefund</span> on the hook.
          </Notice>
        </div>
      ) : null}

      <Section title="Slash history" aside={indexed ? `${formatInt(indexed.slashes.length)} slashes` : undefined}>
        <DataTable
          columns={slashColumns}
          rows={indexed?.slashes ?? []}
          rowKey={(s, i) => `${s.txHash}-${i}`}
          empty={indexed || (!searcher.ok && searcher.error.kind === "not_found") ? "This address has never been slashed." : "Slash history unavailable while the indexer is down."}
        />
      </Section>

      <Section title="Flags" aside={indexed ? `${formatInt(indexed.flags.length)} flags` : undefined}>
        <DataTable
          columns={flagColumns}
          rows={indexed?.flags ?? []}
          rowKey={(f, i) => `${f.txHash}-${i}`}
          empty={indexed || (!searcher.ok && searcher.error.kind === "not_found") ? "No watchtower or relay flag on this address." : "Flag history unavailable while the indexer is down."}
        />
        <p className="muted mt-2 max-w-prose text-sm">
          A flag strips the clamp exemption until the block shown. The hook flags on every slash; the watchtower flags
          with an evidence hash for patterns the detector cannot see, such as a sandwich split across two bonded
          addresses.
        </p>
      </Section>
    </div>
  );
}

function isActive(until: string, head: string | null): boolean {
  const u = toBigInt(until);
  if (u === 0n) return false;
  if (head === null) return true;
  return toBigInt(head) < u;
}

function exemptLabel(
  bond: { amount: string } | null,
  bannedUntil: string,
  flaggedUntil: string,
  head: string | null,
): string {
  if (!bond) return "no";
  if (isActive(bannedUntil, head)) return "no, banned";
  if (isActive(flaggedUntil, head)) return "no, flagged";
  return "yes";
}

function exemptHint(bannedUntil: string, flaggedUntil: string, head: string | null): string {
  const parts: string[] = [];
  if (toBigInt(bannedUntil) > 0n) parts.push(`banned until ${formatInt(bannedUntil)}${isActive(bannedUntil, head) ? "" : " (expired)"}`);
  if (toBigInt(flaggedUntil) > 0n) parts.push(`flagged until ${formatInt(flaggedUntil)}${isActive(flaggedUntil, head) ? "" : " (expired)"}`);
  return parts.length ? parts.join(", ") : "first swap of each block trades at the real price";
}
