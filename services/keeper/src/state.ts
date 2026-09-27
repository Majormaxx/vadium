// Persisted keeper state: which addresses were flagged (and until which block), and
// the last block the event scan has covered. Written atomically so a crash mid-write
// never leaves a truncated file behind.

import { promises as fs } from "node:fs";
import { getAddress, isAddress, type Address } from "viem";

export interface KeeperState {
  version: 1;
  chainId: number;
  hook: Address;
  /** Last block whose logs have been folded into `flagged`. */
  lastBlock: bigint;
  /** Lowercase searcher address -> block until which the flag is active (exclusive). */
  flagged: Map<Address, bigint>;
}

export function newState(chainId: number, hook: Address, lastBlock: bigint): KeeperState {
  return { version: 1, chainId, hook: getAddress(hook), lastBlock, flagged: new Map() };
}

/** Fold a Sandwiched/Flagged event in. Keeps the furthest `flaggedUntil`. Returns true if anything changed. */
export function recordFlag(state: KeeperState, searcher: Address, flaggedUntil: bigint): boolean {
  const key = searcher.toLowerCase() as Address;
  const current = state.flagged.get(key);
  if (current !== undefined && current >= flaggedUntil) return false;
  state.flagged.set(key, flaggedUntil);
  return true;
}

export function advanceBlock(state: KeeperState, block: bigint): void {
  if (block > state.lastBlock) state.lastBlock = block;
}

/** Drop flags that can never be active again. Returns how many were removed. */
export function pruneExpired(state: KeeperState, blockNumber: bigint): number {
  let removed = 0;
  for (const [addr, until] of state.flagged) {
    if (until <= blockNumber) {
      state.flagged.delete(addr);
      removed++;
    }
  }
  return removed;
}

interface StateFile {
  version: 1;
  chainId: number;
  hook: Address;
  lastBlock: string;
  flagged: Record<string, string>;
}

export function serialize(state: KeeperState): string {
  const flagged: Record<string, string> = {};
  for (const addr of [...state.flagged.keys()].sort()) {
    flagged[addr] = state.flagged.get(addr)!.toString();
  }
  const file: StateFile = {
    version: 1,
    chainId: state.chainId,
    hook: state.hook,
    lastBlock: state.lastBlock.toString(),
    flagged,
  };
  return JSON.stringify(file, null, 2) + "\n";
}

export class StateFormatError extends Error {
  override name = "StateFormatError";
}

function expectUint(value: unknown, what: string): bigint {
  if (typeof value !== "string" || !/^\d+$/.test(value)) throw new StateFormatError(`${what} must be a decimal string, got ${JSON.stringify(value)}`);
  return BigInt(value);
}

export function deserialize(text: string): KeeperState {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (err) {
    throw new StateFormatError("state file is not valid JSON", { cause: err });
  }
  if (typeof parsed !== "object" || parsed === null) throw new StateFormatError("state file is not an object");
  const f = parsed as Partial<StateFile>;
  if (f.version !== 1) throw new StateFormatError(`unsupported state version ${JSON.stringify(f.version)}`);
  if (typeof f.chainId !== "number" || !Number.isInteger(f.chainId)) throw new StateFormatError("chainId must be an integer");
  if (typeof f.hook !== "string" || !isAddress(f.hook)) throw new StateFormatError("hook must be an address");
  const lastBlock = expectUint(f.lastBlock, "lastBlock");
  if (typeof f.flagged !== "object" || f.flagged === null || Array.isArray(f.flagged)) throw new StateFormatError("flagged must be an object");
  const flagged = new Map<Address, bigint>();
  for (const [addr, until] of Object.entries(f.flagged)) {
    if (!isAddress(addr)) throw new StateFormatError(`flagged key is not an address: ${addr}`);
    flagged.set(addr.toLowerCase() as Address, expectUint(until, `flagged[${addr}]`));
  }
  return { version: 1, chainId: f.chainId, hook: getAddress(f.hook), lastBlock, flagged };
}

/** The subset of fs the writer needs, so tests can observe the write order. */
export interface StateFs {
  writeFile(path: string, data: string, encoding: "utf8"): Promise<void>;
  rename(from: string, to: string): Promise<void>;
  readFile(path: string, encoding: "utf8"): Promise<string>;
}

export function tempPathFor(file: string): string {
  return `${file}.tmp`;
}

/** Write to `<file>.tmp` then rename over `file`, so readers see the old or the new file, never a partial one. */
export async function saveState(file: string, state: KeeperState, io: StateFs = fs): Promise<void> {
  const tmp = tempPathFor(file);
  await io.writeFile(tmp, serialize(state), "utf8");
  await io.rename(tmp, file);
}

/** Returns null when the file does not exist. Throws StateFormatError on a corrupt file. */
export async function loadState(file: string, io: StateFs = fs): Promise<KeeperState | null> {
  let text: string;
  try {
    text = await io.readFile(file, "utf8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw err;
  }
  return deserialize(text);
}
