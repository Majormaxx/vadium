// Chains the indexer knows how to run against. The active one is picked by CHAIN_ID.

export type ChainInfo = {
  /** Ponder chain name, also the key of `publicClients` in the API. */
  name: string;
  id: number;
  defaultRpc: string;
};

export const CHAINS: Record<number, ChainInfo> = {
  1301: { name: "unichainSepolia", id: 1301, defaultRpc: "https://sepolia.unichain.org" },
  130: { name: "unichain", id: 130, defaultRpc: "https://mainnet.unichain.org" },
};

export type Deployment = {
  chainId: number;
  block: number;
  hook: `0x${string}`;
  poolManager: `0x${string}`;
  poolId: `0x${string}`;
};

/** Resolve the active chain from CHAIN_ID (default 1301). Throws on an unknown id. */
export function activeChain(env: NodeJS.ProcessEnv = process.env): ChainInfo {
  const raw = env.CHAIN_ID ?? "1301";
  const id = Number(raw);
  const chain = CHAINS[id];
  if (!chain) {
    throw new Error(`CHAIN_ID=${raw} is not supported; known chain ids: ${Object.keys(CHAINS).join(", ")}`);
  }
  return chain;
}

/** RPC URL for a chain: PONDER_RPC_URL_<id>, else the public default. */
export function rpcUrl(chain: ChainInfo, env: NodeJS.ProcessEnv = process.env): string {
  return env[`PONDER_RPC_URL_${chain.id}`] ?? chain.defaultRpc;
}

/** Loose shape of one record in generated/deployments.json. */
export type DeploymentRecord = {
  hook?: string;
  poolManager?: string;
  poolId?: string;
  block?: number;
};

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const BYTES32 = /^0x[0-9a-fA-F]{64}$/;

/** Pick and validate the deployment record for a chain out of generated/deployments.json. */
export function deploymentFor(deployments: Record<string, DeploymentRecord>, chain: ChainInfo): Deployment {
  const d = deployments[String(chain.id)];
  const hint = "run `node scripts/export-artifacts.mjs` from the repo root";
  if (!d) throw new Error(`generated/deployments.json has no record for chain ${chain.id}; ${hint}`);
  if (!d.hook || !ADDRESS.test(d.hook)) throw new Error(`deployments.json[${chain.id}].hook is not an address; ${hint}`);
  if (!d.poolManager || !ADDRESS.test(d.poolManager)) {
    throw new Error(`deployments.json[${chain.id}].poolManager is not an address; ${hint}`);
  }
  if (!d.poolId || !BYTES32.test(d.poolId)) throw new Error(`deployments.json[${chain.id}].poolId is not bytes32; ${hint}`);
  if (!Number.isInteger(d.block) || (d.block as number) < 0) {
    throw new Error(`deployments.json[${chain.id}].block is not a block number; ${hint}`);
  }
  return {
    chainId: chain.id,
    block: d.block as number,
    hook: d.hook as `0x${string}`,
    poolManager: d.poolManager as `0x${string}`,
    poolId: d.poolId.toLowerCase() as `0x${string}`,
  };
}
