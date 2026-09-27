import { existsSync } from "node:fs";
import { join } from "node:path";
import type { Address, Hex } from "viem";

import { SCENARIO_NAMES, type ScenarioName } from "./scenarios.js";

export interface SimConfig {
  rpcUrl: string;
  chainId: number;
  /** Signing key. Absent for read-only plans and dry runs when SIM_ADDRESS is set. */
  privateKey: Hex | undefined;
  /** Owner address used when no key is present (read-only). */
  address: Address | undefined;
  /** Total USDC (raw, 6 decimals) the selected scenarios may spend on swap inputs. */
  usdcBudget: bigint;
  /** Total wei the selected scenarios may spend on swap inputs (gas excluded). */
  ethBudgetWei: bigint;
  /** Fraction of the virtual reserve each leg moves, in basis points. */
  swapFractionBps: number;
  scenarios: ScenarioName[];
  /** Fixed gas limit per swap in a same-block batch. */
  swapGasLimit: bigint;
}

export const DEFAULTS = {
  rpcUrl: "https://sepolia.unichain.org",
  chainId: 1301,
  usdcBudget: 20_000_000n,
  ethBudgetWei: 1_000_000_000_000_000n,
  swapFractionBps: 500,
  swapGasLimit: 1_500_000n,
} as const;

/** Loads `.env` next to package.json when present. Never throws on a missing file. */
export function loadDotEnv(dir: string): void {
  const file = join(dir, ".env");
  if (!existsSync(file)) return;
  try {
    process.loadEnvFile(file);
  } catch {
    // A malformed .env is reported by the caller when the values it needs are missing.
  }
}

function bigintEnv(env: NodeJS.ProcessEnv, key: string, fallback: bigint): bigint {
  const raw = env[key];
  if (raw === undefined || raw === "") return fallback;
  if (!/^\d+$/.test(raw)) throw new Error(`${key} must be a non-negative integer, got "${raw}"`);
  return BigInt(raw);
}

function intEnv(env: NodeJS.ProcessEnv, key: string, fallback: number): number {
  const raw = env[key];
  if (raw === undefined || raw === "") return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0) throw new Error(`${key} must be a non-negative integer, got "${raw}"`);
  return n;
}

export function parseScenarioList(raw: string | undefined): ScenarioName[] {
  if (raw === undefined || raw.trim() === "") return [...SCENARIO_NAMES];
  const names = raw
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  for (const n of names) {
    if (!(SCENARIO_NAMES as readonly string[]).includes(n)) {
      throw new Error(`unknown scenario "${n}"; known: ${SCENARIO_NAMES.join(", ")}`);
    }
  }
  return [...new Set(names)] as ScenarioName[];
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): SimConfig {
  const pk = env.SIM_PRIVATE_KEY?.trim();
  let privateKey: Hex | undefined;
  if (pk !== undefined && pk !== "") {
    const normalized = pk.startsWith("0x") ? pk : `0x${pk}`;
    if (!/^0x[0-9a-fA-F]{64}$/.test(normalized)) {
      throw new Error("SIM_PRIVATE_KEY must be a 32-byte hex key");
    }
    privateKey = normalized as Hex;
  }
  const addr = env.SIM_ADDRESS?.trim();
  let address: Address | undefined;
  if (addr !== undefined && addr !== "") {
    if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) throw new Error("SIM_ADDRESS must be an address");
    address = addr as Address;
  }
  const swapFractionBps = intEnv(env, "SWAP_FRACTION_BPS", DEFAULTS.swapFractionBps);
  if (swapFractionBps === 0 || swapFractionBps > 5_000) {
    throw new Error("SWAP_FRACTION_BPS must be between 1 and 5000");
  }
  return {
    rpcUrl: env.RPC_URL?.trim() || DEFAULTS.rpcUrl,
    chainId: intEnv(env, "CHAIN_ID", DEFAULTS.chainId),
    privateKey,
    address,
    usdcBudget: bigintEnv(env, "USDC_BUDGET", DEFAULTS.usdcBudget),
    ethBudgetWei: bigintEnv(env, "ETH_BUDGET_WEI", DEFAULTS.ethBudgetWei),
    swapFractionBps,
    scenarios: parseScenarioList(env.SCENARIOS),
    swapGasLimit: bigintEnv(env, "SWAP_GAS_LIMIT", DEFAULTS.swapGasLimit),
  };
}
