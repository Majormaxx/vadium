import { describe, expect, it } from "vitest";
import { ConfigError, defaults, parseConfig, parsePoolIds, type Deployments } from "../src/config.js";

const PK = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const POOL = "0x8e04e9c3fd9137cdc79ef352d1b1af9c5b3c5384cca2d8641c754bd6a2000304";
const deployments: Deployments = {
  "1301": {
    hook: "0x6d6201097d6549F9760d61019E69E599315dc0C0",
    poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",
    poolId: POOL,
    block: 61591813,
    bondToken: "0x31d0220469e10c4E71834a79b1f276d740d3768F",
  },
};

describe("parseConfig", () => {
  it("applies every default and takes the hook, pool id and deploy block from the deployment record", () => {
    const cfg = parseConfig({ KEEPER_PRIVATE_KEY: PK }, deployments);
    expect(cfg).toEqual({
      rpcUrl: "https://sepolia.unichain.org",
      chainId: 1301,
      privateKey: PK,
      hook: "0x6d6201097d6549F9760d61019E69E599315dc0C0",
      deployBlock: 61591813n,
      poolIds: [POOL],
      drainIntervalS: defaults.DRAIN_INTERVAL_S,
      drainCap: 1_000_000_000n,
      minDrain: 1_000_000n,
      metricsPort: 9464,
      stateFile: "./state.json",
      startBlock: undefined,
      backfillStep: 2000n,
    });
  });

  it("reads every override", () => {
    const cfg = parseConfig(
      {
        KEEPER_PRIVATE_KEY: PK,
        RPC_URL: "http://localhost:8545",
        CHAIN_ID: "1301",
        POOL_IDS: `${POOL}, 0x${"ab".repeat(32)}`,
        DRAIN_INTERVAL_S: "60",
        DRAIN_CAP: "5000000",
        MIN_DRAIN: "2500000",
        METRICS_PORT: "9999",
        STATE_FILE: "/var/lib/keeper/state.json",
        START_BLOCK: "61600000",
        BACKFILL_STEP: "5000",
      },
      deployments,
    );
    expect(cfg.rpcUrl).toBe("http://localhost:8545");
    expect(cfg.poolIds).toEqual([POOL, `0x${"ab".repeat(32)}`]);
    expect(cfg.drainIntervalS).toBe(60);
    expect(cfg.drainCap).toBe(5_000_000n);
    expect(cfg.minDrain).toBe(2_500_000n);
    expect(cfg.metricsPort).toBe(9999);
    expect(cfg.stateFile).toBe("/var/lib/keeper/state.json");
    expect(cfg.startBlock).toBe(61_600_000n);
    expect(cfg.backfillStep).toBe(5000n);
  });

  it("defaults RPC_URL per chain and requires a deployment record for the chain", () => {
    const withMainnet: Deployments = { ...deployments, "130": { ...deployments["1301"]!, block: 1 } };
    expect(parseConfig({ KEEPER_PRIVATE_KEY: PK, CHAIN_ID: "130" }, withMainnet).rpcUrl).toBe("https://mainnet.unichain.org");
    expect(() => parseConfig({ KEEPER_PRIVATE_KEY: PK, CHAIN_ID: "130" }, deployments)).toThrow(/no deployment record for chain 130/);
    expect(() => parseConfig({ KEEPER_PRIVATE_KEY: PK, CHAIN_ID: "1" }, deployments)).toThrow(/unsupported CHAIN_ID 1/);
  });

  it("rejects bad values with ConfigError", () => {
    const ok = { KEEPER_PRIVATE_KEY: PK };
    expect(() => parseConfig({}, deployments)).toThrow(ConfigError);
    expect(() => parseConfig({ KEEPER_PRIVATE_KEY: "0x1234" }, deployments)).toThrow(/KEEPER_PRIVATE_KEY/);
    expect(() => parseConfig({ ...ok, RPC_URL: "ws://x" }, deployments)).toThrow(/RPC_URL/);
    expect(() => parseConfig({ ...ok, DRAIN_INTERVAL_S: "0" }, deployments)).toThrow(/DRAIN_INTERVAL_S/);
    expect(() => parseConfig({ ...ok, DRAIN_INTERVAL_S: "1.5" }, deployments)).toThrow(/DRAIN_INTERVAL_S/);
    expect(() => parseConfig({ ...ok, DRAIN_CAP: "-1" }, deployments)).toThrow(/DRAIN_CAP/);
    expect(() => parseConfig({ ...ok, MIN_DRAIN: "0" }, deployments)).toThrow(/MIN_DRAIN/);
    expect(() => parseConfig({ ...ok, MIN_DRAIN: "10", DRAIN_CAP: "9" }, deployments)).toThrow(/MIN_DRAIN \(10\) must not exceed DRAIN_CAP \(9\)/);
    expect(() => parseConfig({ ...ok, METRICS_PORT: "70000" }, deployments)).toThrow(/METRICS_PORT/);
    expect(() => parseConfig({ ...ok, POOL_IDS: "0x12" }, deployments)).toThrow(/POOL_IDS/);
    expect(() => parseConfig({ ...ok, POOL_IDS: " , " }, deployments)).toThrow(/POOL_IDS is set but contains no pool ids/);
    expect(() => parseConfig({ ...ok, START_BLOCK: "abc" }, deployments)).toThrow(/START_BLOCK/);
    expect(() => parseConfig(ok, { "1301": { ...deployments["1301"]!, hook: "0xnope" } })).toThrow(/invalid hook address/);
  });
});

describe("parsePoolIds", () => {
  it("trims, lowercases and dedupes", () => {
    const upper = POOL.toUpperCase().replace("0X", "0x");
    expect(parsePoolIds(` ${POOL} ,${upper},, `)).toEqual([POOL]);
  });
});
