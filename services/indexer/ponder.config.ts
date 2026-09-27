import { createConfig } from "ponder";
import deployments from "./generated/deployments.json";
import { VadiumHookAbi } from "./generated/VadiumHook.abi";
import { PoolManagerAbi } from "./src/abis/poolManager";
import { activeChain, deploymentFor, rpcUrl } from "./src/chains";

const chain = activeChain();
const deployment = deploymentFor(deployments, chain);

// Pool ids whose PoolManager Swap events are fetched. The deployment's first pool
// plus any extra ids from POOL_IDS (comma separated). Swaps for pools the hook has
// not registered are dropped in the handler.
const poolIds = Array.from(
  new Set(
    [deployment.poolId, ...(process.env.POOL_IDS ?? "").split(",")]
      .map((id) => id.trim().toLowerCase())
      .filter((id) => /^0x[0-9a-f]{64}$/.test(id)),
  ),
) as `0x${string}`[];

export default createConfig({
  database: process.env.DATABASE_URL
    ? { kind: "postgres", connectionString: process.env.DATABASE_URL }
    : { kind: "pglite" },
  chains: {
    [chain.name]: {
      id: chain.id,
      rpc: rpcUrl(chain),
      pollingInterval: 1_000,
    },
  },
  contracts: {
    VadiumHook: {
      abi: VadiumHookAbi,
      chain: chain.name,
      address: deployment.hook,
      startBlock: deployment.block,
    },
    PoolManager: {
      abi: PoolManagerAbi,
      chain: chain.name,
      address: deployment.poolManager,
      startBlock: deployment.block,
      filter: { event: "Swap", args: { id: poolIds } },
    },
  },
});
