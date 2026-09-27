import { readFileSync } from "node:fs";
import { isAddress, isHex, type Address, type Hex } from "viem";
import { generatedPath } from "./abi.js";
import { chainFor } from "./chains.js";

export interface DeploymentRecord {
  hook: Address;
  poolManager: Address;
  poolId: Hex;
  block: number;
  bondToken: Address;
}

export type Deployments = Record<string, DeploymentRecord>;

export interface Config {
  rpcUrl: string;
  chainId: number;
  privateKey: Hex;
  hook: Address;
  deployBlock: bigint;
  poolIds: Hex[];
  drainIntervalS: number;
  drainCap: bigint;
  minDrain: bigint;
  metricsPort: number;
  stateFile: string;
  startBlock: bigint | undefined;
  backfillStep: bigint;
}

export type Env = Record<string, string | undefined>;

export class ConfigError extends Error {
  override name = "ConfigError";
}

export const defaults = {
  CHAIN_ID: 1301,
  DRAIN_INTERVAL_S: 3600,
  DRAIN_CAP: 1_000_000_000n,
  MIN_DRAIN: 1_000_000n,
  METRICS_PORT: 9464,
  STATE_FILE: "./state.json",
  BACKFILL_STEP: 2000n,
} as const;

const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

function raw(env: Env, key: string): string | undefined {
  const v = env[key]?.trim();
  return v === undefined || v === "" ? undefined : v;
}

function intOr(env: Env, key: string, fallback: number, opts: { min: number; max?: number }): number {
  const v = raw(env, key);
  if (v === undefined) return fallback;
  if (!/^\d+$/.test(v)) throw new ConfigError(`${key} must be a non-negative integer, got "${v}"`);
  const n = Number(v);
  if (!Number.isSafeInteger(n)) throw new ConfigError(`${key} is out of range: "${v}"`);
  if (n < opts.min) throw new ConfigError(`${key} must be >= ${opts.min}, got ${n}`);
  if (opts.max !== undefined && n > opts.max) throw new ConfigError(`${key} must be <= ${opts.max}, got ${n}`);
  return n;
}

function bigintOr(env: Env, key: string, fallback: bigint | undefined, opts: { min: bigint }): bigint | undefined {
  const v = raw(env, key);
  if (v === undefined) return fallback;
  if (!/^\d+$/.test(v)) throw new ConfigError(`${key} must be a non-negative integer, got "${v}"`);
  const n = BigInt(v);
  if (n < opts.min) throw new ConfigError(`${key} must be >= ${opts.min}, got ${n}`);
  return n;
}

export function parsePoolIds(value: string): Hex[] {
  const ids = value
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s !== "");
  const out: Hex[] = [];
  for (const id of ids) {
    if (!BYTES32_RE.test(id)) throw new ConfigError(`POOL_IDS entry is not a bytes32 hex string: "${id}"`);
    const lower = id.toLowerCase() as Hex;
    if (!out.includes(lower)) out.push(lower);
  }
  return out;
}

export function parseConfig(env: Env, deployments: Deployments): Config {
  const chainId = intOr(env, "CHAIN_ID", defaults.CHAIN_ID, { min: 1 });
  const chain = chainFor(chainId);

  const record = deployments[String(chainId)];
  if (!record) {
    throw new ConfigError(`no deployment record for chain ${chainId} in generated/deployments.json (have: ${Object.keys(deployments).join(", ") || "none"})`);
  }
  if (!isAddress(record.hook)) throw new ConfigError(`deployment record for chain ${chainId} has an invalid hook address: "${record.hook}"`);
  if (!Number.isInteger(record.block) || record.block < 0) throw new ConfigError(`deployment record for chain ${chainId} has an invalid deploy block: ${record.block}`);
  if (typeof record.poolId !== "string" || !BYTES32_RE.test(record.poolId)) throw new ConfigError(`deployment record for chain ${chainId} has an invalid poolId: "${record.poolId}"`);

  const rpcUrl = raw(env, "RPC_URL") ?? chain.rpcUrls.default.http[0];
  if (!rpcUrl || !/^https?:\/\//.test(rpcUrl)) throw new ConfigError(`RPC_URL must be an http(s) URL, got "${rpcUrl}"`);

  const privateKey = raw(env, "KEEPER_PRIVATE_KEY");
  if (privateKey === undefined) throw new ConfigError("KEEPER_PRIVATE_KEY is required");
  if (!isHex(privateKey) || privateKey.length !== 66) throw new ConfigError("KEEPER_PRIVATE_KEY must be a 0x-prefixed 32-byte hex string");

  const poolIdsRaw = raw(env, "POOL_IDS");
  const poolIds = poolIdsRaw === undefined ? [record.poolId.toLowerCase() as Hex] : parsePoolIds(poolIdsRaw);
  if (poolIds.length === 0) throw new ConfigError("POOL_IDS is set but contains no pool ids");

  const drainCap = bigintOr(env, "DRAIN_CAP", defaults.DRAIN_CAP, { min: 1n }) as bigint;
  const minDrain = bigintOr(env, "MIN_DRAIN", defaults.MIN_DRAIN, { min: 1n }) as bigint;
  if (minDrain > drainCap) throw new ConfigError(`MIN_DRAIN (${minDrain}) must not exceed DRAIN_CAP (${drainCap})`);

  return {
    rpcUrl,
    chainId,
    privateKey,
    hook: record.hook,
    deployBlock: BigInt(record.block),
    poolIds,
    drainIntervalS: intOr(env, "DRAIN_INTERVAL_S", defaults.DRAIN_INTERVAL_S, { min: 1 }),
    drainCap,
    minDrain,
    metricsPort: intOr(env, "METRICS_PORT", defaults.METRICS_PORT, { min: 1, max: 65535 }),
    stateFile: raw(env, "STATE_FILE") ?? defaults.STATE_FILE,
    startBlock: bigintOr(env, "START_BLOCK", undefined, { min: 0n }),
    backfillStep: bigintOr(env, "BACKFILL_STEP", defaults.BACKFILL_STEP, { min: 1n }) as bigint,
  };
}

export function loadDeployments(path: string = generatedPath("deployments.json")): Deployments {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch (err) {
    throw new ConfigError(`cannot read ${path}; run \`node scripts/export-artifacts.mjs\` from the repo root`, { cause: err });
  }
  return JSON.parse(text) as Deployments;
}

export function loadConfig(env: Env = process.env): Config {
  return parseConfig(env, loadDeployments());
}

/** Redacted copy for logging. */
export function describeConfig(cfg: Config): Record<string, unknown> {
  const { privateKey: _pk, ...rest } = cfg;
  return rest;
}
