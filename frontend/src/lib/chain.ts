// Chain definitions, deployment lookup, and explorer links.

import { defineChain, isAddress, type Chain } from "viem";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

export const unichainSepolia = defineChain({
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://sepolia.unichain.org"] } },
  blockExplorers: { default: { name: "Uniscan", url: "https://sepolia.uniscan.xyz" } },
  testnet: true,
});

export const unichain = defineChain({
  id: 130,
  name: "Unichain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://mainnet.unichain.org"] } },
  blockExplorers: { default: { name: "Uniscan", url: "https://uniscan.xyz" } },
});

export const chains: Record<number, Chain> = {
  [unichainSepolia.id]: unichainSepolia,
  [unichain.id]: unichain,
};

export const DEFAULT_CHAIN_ID = unichainSepolia.id;

export function chainIdFromEnv(): number {
  const raw = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? "");
  return Number.isInteger(raw) && raw > 0 ? raw : DEFAULT_CHAIN_ID;
}

export function chainFor(chainId: number): Chain | undefined {
  return chains[chainId];
}

export function rpcUrlFromEnv(chain: Chain | undefined): string {
  const env = process.env.NEXT_PUBLIC_RPC_URL?.trim();
  if (env) return env;
  return chain?.rpcUrls.default.http[0] ?? unichainSepolia.rpcUrls.default.http[0];
}

export type PoolKey = {
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
};

export type Deployment = {
  chainId: number;
  chainName?: string;
  hook: string;
  poolManager: string;
  stateView?: string;
  bondToken: string;
  poolId: string;
  poolKey: PoolKey;
  block?: number;
  commit?: string;
  note?: string;
};

let cachedDeployments: Record<string, Deployment> | null = null;

/**
 * Reads src/generated/deployments.json, written by the repo's
 * scripts/export-artifacts.mjs. The file is optional so a checkout without
 * forge artifacts still builds; NEXT_PUBLIC_HOOK_ADDRESS fills the gap.
 */
export function deployments(): Record<string, Deployment> {
  if (cachedDeployments) return cachedDeployments;
  const file = path.join(process.cwd(), "src", "generated", "deployments.json");
  let parsed: Record<string, Deployment> = {};
  try {
    if (existsSync(file)) {
      parsed = JSON.parse(readFileSync(file, "utf8")) as Record<string, Deployment>;
    }
  } catch {
    parsed = {};
  }
  cachedDeployments = parsed;
  return parsed;
}

export function deploymentFor(chainId: number): Deployment | undefined {
  return deployments()[String(chainId)];
}

/** The hook address for the configured chain: env override, then deployments.json. */
export function hookAddressFor(chainId: number): `0x${string}` | undefined {
  const env = process.env.NEXT_PUBLIC_HOOK_ADDRESS?.trim();
  if (env && isAddress(env)) return env;
  const hook = deploymentFor(chainId)?.hook;
  return hook && isAddress(hook) ? hook : undefined;
}

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

export function explorerUrl(chainId: number): string {
  return chainFor(chainId)?.blockExplorers?.default.url ?? unichainSepolia.blockExplorers.default.url;
}

export function addressUrl(chainId: number, address: string): string {
  return `${explorerUrl(chainId)}/address/${address}`;
}

export function txUrl(chainId: number, hash: string): string {
  return `${explorerUrl(chainId)}/tx/${hash}`;
}

export function blockUrl(chainId: number, block: string | number | bigint): string {
  return `${explorerUrl(chainId)}/block/${block.toString()}`;
}

export type TokenInfo = { symbol: string; decimals: number };

/** Symbol and decimals for the currencies this hook deals in. */
export function tokenInfo(chainId: number, address: string): TokenInfo {
  const lower = address.toLowerCase();
  if (lower === ZERO_ADDRESS) return { symbol: "ETH", decimals: 18 };
  const bond = deploymentFor(chainId)?.bondToken?.toLowerCase();
  if (bond && lower === bond) return { symbol: "USDC", decimals: 6 };
  return { symbol: `${address.slice(0, 6)}…${address.slice(-4)}`, decimals: 18 };
}

export function pairLabel(chainId: number, currency0: string, currency1: string): string {
  return `${tokenInfo(chainId, currency0).symbol}/${tokenInfo(chainId, currency1).symbol}`;
}

export function isPoolId(value: string): value is `0x${string}` {
  return /^0x[0-9a-fA-F]{64}$/.test(value);
}
