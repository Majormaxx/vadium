import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { parseAbi, type Abi, type Address, type Hex } from "viem";

export const SERVICE_DIR = join(import.meta.dirname, "..");
export const GENERATED_DIR = join(SERVICE_DIR, "generated");

export interface PoolKey {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

export interface Deployment {
  chainId: number;
  hook: Address;
  poolManager: Address;
  stateView: Address;
  bondToken: Address;
  poolId: Hex;
  poolKey: PoolKey;
}

/** StateView on Unichain Sepolia, used when the deployment record omits it. */
const STATE_VIEW_BY_CHAIN: Record<number, Address> = {
  1301: "0xc199F1072a74D4e905ABa1A84d9a45E2546B6222",
};

function missing(path: string): Error {
  return new Error(`missing ${path}; run \`pnpm artifacts\` (after \`forge build\` at the repo root)`);
}

function readJson<T>(path: string): T {
  if (!existsSync(path)) throw missing(path);
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

export function loadRouterArtifact(dir: string = GENERATED_DIR): { abi: Abi; bytecode: Hex } {
  const a = readJson<{ abi: Abi; bytecode: Hex }>(join(dir, "SimSwapRouter.json"));
  if (!Array.isArray(a.abi) || typeof a.bytecode !== "string" || !a.bytecode.startsWith("0x")) {
    throw new Error("generated/SimSwapRouter.json is malformed; rerun `pnpm artifacts`");
  }
  return a;
}

export function loadHookAbi(dir: string = GENERATED_DIR): Abi {
  return readJson<Abi>(join(dir, "VadiumHook.abi.json"));
}

interface RawDeployment {
  chainId: number;
  hook: string;
  poolManager: string;
  stateView?: string;
  bondToken: string;
  poolId: string;
  poolKey: { currency0: string; currency1: string; fee: number; tickSpacing: number; hooks: string };
}

export function parseDeployment(raw: RawDeployment, chainId: number): Deployment {
  const stateView = raw.stateView ?? STATE_VIEW_BY_CHAIN[chainId];
  if (stateView === undefined) {
    throw new Error(`no StateView address for chain ${chainId}; add "stateView" to the deployment record`);
  }
  if (raw.poolKey.hooks.toLowerCase() !== raw.hook.toLowerCase()) {
    throw new Error("deployment record: poolKey.hooks does not match hook");
  }
  return {
    chainId,
    hook: raw.hook as Address,
    poolManager: raw.poolManager as Address,
    stateView: stateView as Address,
    bondToken: raw.bondToken as Address,
    poolId: raw.poolId as Hex,
    poolKey: {
      currency0: raw.poolKey.currency0 as Address,
      currency1: raw.poolKey.currency1 as Address,
      fee: raw.poolKey.fee,
      tickSpacing: raw.poolKey.tickSpacing,
      hooks: raw.poolKey.hooks as Address,
    },
  };
}

export function loadDeployment(chainId: number, dir: string = GENERATED_DIR): Deployment {
  const all = readJson<Record<string, RawDeployment>>(join(dir, "deployments.json"));
  const raw = all[String(chainId)];
  if (raw === undefined) {
    throw new Error(`no deployment record for chain ${chainId} in generated/deployments.json`);
  }
  return parseDeployment(raw, chainId);
}

export const stateViewAbi = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function getLiquidity(bytes32 poolId) view returns (uint128 liquidity)",
]);

export const erc20Abi = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
]);

/** The PoolManager events the evaluator reads. Amounts are from the swapper's side. */
export const poolManagerEventsAbi = parseAbi([
  "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)",
]);
