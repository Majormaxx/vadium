import { describe, expect, it } from "vitest";
import { activeChain, deploymentFor, rpcUrl } from "../src/chains";

const record = {
  "1301": { hook: "0x6d6201097d6549F9760d61019E69E599315dc0C0", poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC", poolId: `0x${"AB".repeat(32)}`, block: 61591813 },
};

describe("activeChain", () => {
  it("defaults to Unichain Sepolia", () => {
    expect(activeChain({}).id).toBe(1301);
  });
  it("selects mainnet", () => {
    expect(activeChain({ CHAIN_ID: "130" }).name).toBe("unichain");
  });
  it("rejects unknown ids", () => {
    expect(() => activeChain({ CHAIN_ID: "1" })).toThrow(/CHAIN_ID=1/);
  });
});

describe("rpcUrl", () => {
  it("prefers the env override", () => {
    expect(rpcUrl(activeChain({}), { PONDER_RPC_URL_1301: "http://x" })).toBe("http://x");
    expect(rpcUrl(activeChain({}), {})).toBe("https://sepolia.unichain.org");
  });
});

describe("deploymentFor", () => {
  it("returns a typed record with a lower-cased pool id", () => {
    const d = deploymentFor(record, activeChain({}));
    expect(d.hook).toBe(record["1301"].hook);
    expect(d.poolId).toBe(`0x${"ab".repeat(32)}`);
    expect(d.block).toBe(61591813);
  });
  it("fails loudly when the chain is missing or a field is malformed", () => {
    expect(() => deploymentFor(record, activeChain({ CHAIN_ID: "130" }))).toThrow(/no record for chain 130/);
    expect(() => deploymentFor({ "1301": { ...record["1301"], hook: "0x12" } }, activeChain({}))).toThrow(/hook/);
    expect(() => deploymentFor({ "1301": { ...record["1301"], block: -1 } }, activeChain({}))).toThrow(/block/);
  });
});
