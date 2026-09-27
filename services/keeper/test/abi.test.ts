import { existsSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { Abi } from "viem";
import { abiSignature, generatedPath, hookAbi, loadHookAbi, pickHookAbi } from "../src/abi.js";

describe("abiSignature", () => {
  it("includes parameter types, mutability, outputs and indexed flags", () => {
    expect(abiSignature(hookAbi[4])).toBe("function drainFlagged(bytes32,address[],uint256) nonpayable returns (uint256)");
    expect(abiSignature(hookAbi[6])).toBe("event Flagged(address indexed,bytes32 indexed,uint256,bytes32,uint256)");
  });
});

describe("pickHookAbi", () => {
  it("returns the pinned entries in pinned order from a superset ABI", () => {
    const superset: Abi = [
      { type: "function", name: "unrelated", inputs: [], outputs: [], stateMutability: "view" },
      ...[...hookAbi].reverse(),
      { type: "error", name: "NotFlagged", inputs: [] },
    ];
    const picked = pickHookAbi(superset);
    expect(picked.map((i) => i.name)).toEqual(hookAbi.map((i) => i.name));
  });

  it("throws naming every missing or changed entry", () => {
    const changed: Abi = hookAbi.map((item) =>
      item.type === "function" && item.name === "drainFlagged"
        ? { ...item, inputs: [item.inputs[0], item.inputs[1]] }
        : item,
    ) as unknown as Abi;
    expect(() => pickHookAbi(changed.filter((i) => !(i.type === "event" && i.name === "Flagged")))).toThrow(
      /missing: function drainFlagged\(bytes32,address\[\],uint256\) nonpayable returns \(uint256\); event Flagged\(address indexed,bytes32 indexed,uint256,bytes32,uint256\)/,
    );
  });
});

// Runs only when scripts/export-artifacts.mjs has populated generated/. It is the
// drift check between the pinned interface and the compiled hook.
describe.skipIf(!existsSync(generatedPath("VadiumHook.abi.json")))("generated ABI", () => {
  it("matches the pinned hook interface", () => {
    const abi = loadHookAbi();
    expect(abi.map((i) => abiSignature(i))).toEqual(hookAbi.map((i) => abiSignature(i)));
  });
});
