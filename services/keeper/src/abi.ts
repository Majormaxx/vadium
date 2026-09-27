// The keeper only uses a handful of hook functions and events. Their signatures are
// pinned here as a const ABI so viem can type every call, and at startup the same
// entries are pulled from the forge-generated ABI (generated/VadiumHook.abi.json,
// written by scripts/export-artifacts.mjs). Any drift between the two fails loudly.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { Abi, AbiEvent, AbiFunction } from "viem";

export const hookAbi = [
  {
    type: "function",
    name: "keeper",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "paused",
    inputs: [],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "insuranceReserve",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "flaggedUntil",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "drainFlagged",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "searchers", type: "address[]" },
      { name: "maxAmount", type: "uint256" },
    ],
    outputs: [{ name: "amount", type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "event",
    name: "Sandwiched",
    anonymous: false,
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "searcher", type: "address", indexed: true },
      { name: "slashed", type: "uint256", indexed: false },
      { name: "isRepeat", type: "bool", indexed: false },
      { name: "remaining", type: "uint256", indexed: false },
      { name: "flaggedUntil", type: "uint256", indexed: false },
      { name: "refunded", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Flagged",
    anonymous: false,
    inputs: [
      { name: "searcher", type: "address", indexed: true },
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "slashed", type: "uint256", indexed: false },
      { name: "evidenceHash", type: "bytes32", indexed: false },
      { name: "flaggedUntil", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "CoverageClaimed",
    anonymous: false,
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "remainingReserve", type: "uint256", indexed: false },
    ],
  },
] as const satisfies Abi;

export type HookAbi = typeof hookAbi;

export const generatedDir = new URL("../generated/", import.meta.url);

export function generatedPath(file: string): string {
  return fileURLToPath(new URL(file, generatedDir));
}

/** Canonical signature used to compare a pinned entry with a generated one. */
export function abiSignature(item: AbiFunction | AbiEvent): string {
  if (item.type === "function") {
    const ins = item.inputs.map((i) => i.type).join(",");
    const outs = item.outputs.map((o) => o.type).join(",");
    return `function ${item.name}(${ins}) ${item.stateMutability} returns (${outs})`;
  }
  const ins = item.inputs.map((i) => `${i.type}${i.indexed ? " indexed" : ""}`).join(",");
  return `event ${item.name}(${ins})`;
}

/**
 * Pick the pinned entries out of a generated ABI. Throws when any pinned entry is
 * missing or has a different signature, so a hook interface change is caught at
 * startup instead of as a confusing revert.
 */
export function pickHookAbi(generated: Abi): HookAbi {
  const bySig = new Map<string, AbiFunction | AbiEvent>();
  for (const item of generated) {
    if (item.type === "function" || item.type === "event") bySig.set(abiSignature(item), item);
  }
  const picked: (AbiFunction | AbiEvent)[] = [];
  const missing: string[] = [];
  for (const pinned of hookAbi) {
    const sig = abiSignature(pinned);
    const found = bySig.get(sig);
    if (found) picked.push(found);
    else missing.push(sig);
  }
  if (missing.length > 0) {
    throw new Error(`generated ABI does not match the keeper's pinned hook interface; missing: ${missing.join("; ")}`);
  }
  // Every pinned entry matched a generated entry with the same signature, so the
  // picked list has the pinned shape.
  return picked as unknown as HookAbi;
}

export function loadHookAbi(path: string = generatedPath("VadiumHook.abi.json")): HookAbi {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch (err) {
    throw new Error(`cannot read ${path}; run \`node scripts/export-artifacts.mjs\` from the repo root (after \`forge build\`)`, { cause: err });
  }
  return pickHookAbi(JSON.parse(text) as Abi);
}
