import type { Metadata } from "next";
import type { Hex } from "viem";
import { indexer, describeError } from "@/lib/api";
import { addressUrl, deploymentFor, isPoolId } from "@/lib/chain";
import { formatInt, formatUsdc, shortHash } from "@/lib/format";
import { chainContext, readStatusOnchain } from "@/lib/onchain";
import { Notice } from "@/components/Notice";
import { PoolLink } from "@/components/Links";
import { Section } from "@/components/Section";
import { Stat, StatGrid } from "@/components/Stat";

export const metadata: Metadata = { title: "Status" };
export const dynamic = "force-dynamic";

export default async function StatusPage() {
  const ctx = chainContext();
  const api = indexer();

  // The pool whose reserve is shown: the indexer's first pool, else the deployment record.
  const [status, pools] = await Promise.all([api.status(), api.pools()]);
  const deployment = deploymentFor(ctx.chainId);
  const candidate = pools.ok && pools.data[0] ? pools.data[0].poolId : (deployment?.poolId ?? null);
  const poolId: Hex | null = candidate && isPoolId(candidate) ? candidate : null;
  const chain = await readStatusOnchain(poolId, ctx);

  return (
    <div>
      <h1>Status</h1>
      <p className="muted mt-1 max-w-prose text-sm">
        Indexer health and a live read of the hook on {ctx.chainName}. The chain section works without the indexer.
      </p>

      <Section title="Indexer" aside={<span className="mono">{api.baseUrl}</span>}>
        {status.ok ? (
          <>
            <StatGrid>
              <Stat label="Indexed block" value={formatInt(status.data.indexedBlock)} />
              <Stat label="Head block" value={status.data.headBlock ? formatInt(status.data.headBlock) : "unknown"} />
              <Stat label="Lag" value={status.data.lag !== null ? `${formatInt(status.data.lag)} blocks` : "unknown"} />
              <Stat label="Chain" value={formatInt(status.data.chainId)} hint={status.data.chainId === ctx.chainId ? "matches this site" : `site is configured for ${ctx.chainId}`} />
            </StatGrid>
            <pre className="json mt-3">{JSON.stringify(status.data, null, 2)}</pre>
          </>
        ) : (
          <Notice tone="error" title="Indexer unavailable">
            {describeError(status.error)}
          </Notice>
        )}
      </Section>

      <Section
        title="Hook on chain"
        aside={
          ctx.hook ? (
            <a className="mono" href={addressUrl(ctx.chainId, ctx.hook)} target="_blank" rel="noreferrer">
              {ctx.hook}
            </a>
          ) : (
            "no hook address"
          )
        }
      >
        {chain.ok ? (
          <>
            <StatGrid>
              <Stat
                label="Paused"
                value={chain.data.paused ? "yes" : "no"}
                hint={chain.data.paused ? "bonding, claims, flushes, and payouts are blocked; every exemption is off" : "all functions live"}
              />
              <Stat label="Total bonded" value={`${formatUsdc(chain.data.totalBonded)} USDC`} hint="sum of every live bond" />
              <Stat label="Total reserve" value={`${formatUsdc(chain.data.totalReserve)} USDC`} hint="all pools' insurance reserves" />
              <Stat label="Total claimable" value={`${formatUsdc(chain.data.totalClaimable)} USDC`} hint="victim refunds not yet claimed" />
            </StatGrid>
            <div className="mt-3">
              <StatGrid>
                <Stat
                  label="Pool reserve"
                  value={chain.data.insuranceReserve !== null ? `${formatUsdc(chain.data.insuranceReserve)} USDC` : "n/a"}
                  hint={chain.data.poolId ? <PoolLink poolId={chain.data.poolId} label={`insuranceReserve(${shortHash(chain.data.poolId)})`} /> : "no pool id known"}
                />
                <Stat label="RPC head" value={formatInt(chain.data.headBlock)} hint={ctx.rpcUrl} />
              </StatGrid>
            </div>
            <p className="muted mt-3 max-w-prose text-sm">
              The hook&apos;s bond token balance must cover total bonded plus total reserve plus total claimable at all
              times. That solvency invariant is enforced by the repository&apos;s invariant suite.
            </p>
          </>
        ) : (
          <Notice tone="error" title="Chain read failed">
            {chain.error}. RPC: <span className="mono">{ctx.rpcUrl}</span>
          </Notice>
        )}
      </Section>

      {deployment ? (
        <Section title="Deployment record">
          <pre className="json">{JSON.stringify(deployment, null, 2)}</pre>
        </Section>
      ) : (
        <Section title="Deployment record">
          <Notice tone="info" title="No deployment record">
            <span className="mono">src/generated/deployments.json</span> has no entry for chain {ctx.chainId}. Run{" "}
            <span className="mono">pnpm abis</span> from a checkout with forge artifacts, or set{" "}
            <span className="mono">NEXT_PUBLIC_HOOK_ADDRESS</span>.
          </Notice>
        </Section>
      )}
    </div>
  );
}
