import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Address } from "viem";
import {
  advanceBlock,
  deserialize,
  loadState,
  newState,
  pruneExpired,
  recordFlag,
  saveState,
  serialize,
  StateFormatError,
  tempPathFor,
  type StateFs,
} from "../src/state.js";

const HOOK = "0x6d6201097d6549F9760d61019E69E599315dc0C0" as Address;
const A = "0x00000000000000000000000000000000000000aa" as Address;
const B = "0x00000000000000000000000000000000000000BB" as Address;

describe("recordFlag / advanceBlock / pruneExpired", () => {
  it("keeps the furthest flaggedUntil and lowercases the key", () => {
    const s = newState(1301, HOOK, 10n);
    expect(recordFlag(s, B, 100n)).toBe(true);
    expect(recordFlag(s, B.toLowerCase() as Address, 90n)).toBe(false);
    expect(recordFlag(s, B, 100n)).toBe(false);
    expect(recordFlag(s, B, 101n)).toBe(true);
    expect([...s.flagged.entries()]).toEqual([[B.toLowerCase(), 101n]]);
  });

  it("only moves lastBlock forward", () => {
    const s = newState(1301, HOOK, 10n);
    advanceBlock(s, 5n);
    expect(s.lastBlock).toBe(10n);
    advanceBlock(s, 12n);
    expect(s.lastBlock).toBe(12n);
  });

  it("prunes flags that expired at or before the block", () => {
    const s = newState(1301, HOOK, 0n);
    recordFlag(s, A, 100n);
    recordFlag(s, B, 200n);
    expect(pruneExpired(s, 100n)).toBe(1);
    expect([...s.flagged.keys()]).toEqual([B.toLowerCase()]);
    expect(pruneExpired(s, 100n)).toBe(0);
  });
});

describe("serialize / deserialize", () => {
  it("round-trips through JSON with bigints as strings and sorted keys", () => {
    const s = newState(1301, HOOK, 61_600_000n);
    recordFlag(s, B, 61_700_000n);
    recordFlag(s, A, 61_650_000n);
    const text = serialize(s);
    expect(text).toBe(
      JSON.stringify(
        {
          version: 1,
          chainId: 1301,
          hook: HOOK,
          lastBlock: "61600000",
          flagged: { [A]: "61650000", [B.toLowerCase()]: "61700000" },
        },
        null,
        2,
      ) + "\n",
    );
    const back = deserialize(text);
    expect(back).toEqual(s);
    expect(back.flagged.get(A)).toBe(61_650_000n);
  });

  it("rejects malformed files with StateFormatError", () => {
    expect(() => deserialize("{not json")).toThrow(StateFormatError);
    expect(() => deserialize(JSON.stringify({ version: 2 }))).toThrow(StateFormatError);
    expect(() => deserialize(JSON.stringify({ version: 1, chainId: 1301, hook: "0x1", lastBlock: "1", flagged: {} }))).toThrow(StateFormatError);
    expect(() => deserialize(JSON.stringify({ version: 1, chainId: 1301, hook: HOOK, lastBlock: 1, flagged: {} }))).toThrow(StateFormatError);
    expect(() => deserialize(JSON.stringify({ version: 1, chainId: 1301, hook: HOOK, lastBlock: "1", flagged: { nope: "1" } }))).toThrow(StateFormatError);
    expect(() => deserialize(JSON.stringify({ version: 1, chainId: 1301, hook: HOOK, lastBlock: "1", flagged: { [A]: "x" } }))).toThrow(StateFormatError);
  });
});

describe("saveState / loadState on disk", () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "vadium-keeper-"));
  });
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("returns null when no file exists", async () => {
    expect(await loadState(join(dir, "state.json"))).toBeNull();
  });

  it("writes, reads back the same state, and leaves no temp file behind", async () => {
    const file = join(dir, "state.json");
    const s = newState(1301, HOOK, 42n);
    recordFlag(s, A, 99n);
    await saveState(file, s);
    expect(await readdir(dir)).toEqual(["state.json"]);
    expect(await loadState(file)).toEqual(s);
  });

  it("replaces an existing file whole", async () => {
    const file = join(dir, "state.json");
    const s1 = newState(1301, HOOK, 1n);
    for (let i = 0; i < 50; i++) recordFlag(s1, `0x${(i + 1).toString(16).padStart(40, "0")}` as Address, 10n);
    await saveState(file, s1);
    const s2 = newState(1301, HOOK, 2n);
    await saveState(file, s2);
    expect(await readFile(file, "utf8")).toBe(serialize(s2));
  });

  it("surfaces a corrupt file as StateFormatError", async () => {
    const file = join(dir, "state.json");
    const { writeFile } = await import("node:fs/promises");
    await writeFile(file, "{", "utf8");
    await expect(loadState(file)).rejects.toThrow(StateFormatError);
  });
});

describe("saveState write order", () => {
  it("writes the temp file completely before renaming it over the target", async () => {
    const ops: string[] = [];
    const contents = new Map<string, string>();
    const io: StateFs = {
      async writeFile(path, data) {
        ops.push(`write:${path}`);
        contents.set(path, data);
      },
      async rename(from, to) {
        ops.push(`rename:${from}->${to}`);
        contents.set(to, contents.get(from)!);
        contents.delete(from);
      },
      async readFile(path) {
        return contents.get(path)!;
      },
    };
    const s = newState(130, HOOK, 7n);
    await saveState("/data/state.json", s, io);
    expect(ops).toEqual([`write:${tempPathFor("/data/state.json")}`, `rename:${tempPathFor("/data/state.json")}->/data/state.json`]);
    expect(contents.get("/data/state.json")).toBe(serialize(s));
    expect(contents.has(tempPathFor("/data/state.json"))).toBe(false);
  });

  it("does not rename when the temp write fails, so the old file survives", async () => {
    const ops: string[] = [];
    const io: StateFs = {
      async writeFile(path) {
        ops.push(`write:${path}`);
        throw new Error("ENOSPC");
      },
      async rename(from, to) {
        ops.push(`rename:${from}->${to}`);
      },
      async readFile() {
        return "";
      },
    };
    await expect(saveState("/data/state.json", newState(130, HOOK, 7n), io)).rejects.toThrow("ENOSPC");
    expect(ops).toEqual(["write:/data/state.json.tmp"]);
  });
});
