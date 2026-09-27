import { describe, expect, it } from "vitest";
import type { Hex } from "viem";
import { silentLogger } from "../src/log.js";
import { Metrics, startMetricsServer } from "../src/metrics.js";

const POOL = "0x8e04e9c3fd9137cdc79ef352d1b1af9c5b3c5384cca2d8641c754bd6a2000304" as Hex;
const POOL_B = "0x0000000000000000000000000000000000000000000000000000000000000002" as Hex;
const HASH = "0xabcdef0000000000000000000000000000000000000000000000000000000001" as Hex;

describe("Metrics.render", () => {
  it("renders zeroed families for registered pools at start", () => {
    const m = new Metrics([POOL]);
    expect(m.render()).toBe(
      [
        "# HELP vadium_reserve Insurance reserve per pool, bond-token raw units.",
        "# TYPE vadium_reserve gauge",
        `vadium_reserve{pool="${POOL}"} 0`,
        "# HELP vadium_flagged_active Flagged addresses whose flag was active at the last tick, per pool.",
        "# TYPE vadium_flagged_active gauge",
        `vadium_flagged_active{pool="${POOL}"} 0`,
        "# HELP vadium_drains_total Drain transactions submitted since start.",
        "# TYPE vadium_drains_total counter",
        "vadium_drains_total 0",
        "# HELP vadium_drained_total Bond-token raw units paid out since start, per pool.",
        "# TYPE vadium_drained_total counter",
        `vadium_drained_total{pool="${POOL}"} 0`,
        "# HELP vadium_last_drain_block Block number at which the last drain was submitted.",
        "# TYPE vadium_last_drain_block gauge",
        "vadium_last_drain_block 0",
        "# HELP vadium_keeper_balance_wei Native balance of the keeper signer, wei.",
        "# TYPE vadium_keeper_balance_wei gauge",
        "vadium_keeper_balance_wei 0",
        "# HELP vadium_rpc_errors_total Failed chain calls since start.",
        "# TYPE vadium_rpc_errors_total counter",
        "vadium_rpc_errors_total 0",
        "# HELP vadium_drain_errors_total Drain simulations or submissions that failed since start.",
        "# TYPE vadium_drain_errors_total counter",
        "vadium_drain_errors_total 0",
        "# HELP vadium_paused 1 when the hook is paused, else 0.",
        "# TYPE vadium_paused gauge",
        "vadium_paused 0",
        "",
      ].join("\n"),
    );
  });

  it("renders live values, sorts pools, and keeps bigints exact", () => {
    const m = new Metrics([POOL, POOL_B]);
    m.setReserve(POOL, 123_456_789_012_345_678_901n);
    m.setFlaggedActive(POOL, 3);
    m.recordDrain(POOL, 1_000_000_000n, 61_700_123n, HASH);
    m.recordDrain(POOL, 5n, 61_700_200n, HASH);
    m.setKeeperBalance(987_654_321_000_000_000n);
    m.incRpcErrors();
    m.incRpcErrors();
    m.incDrainErrors();
    m.setPaused(true);
    const text = m.render();
    expect(text).toContain(`vadium_reserve{pool="${POOL_B}"} 0\nvadium_reserve{pool="${POOL}"} 123456789012345678901\n`);
    expect(text).toContain(`vadium_flagged_active{pool="${POOL_B}"} 0\nvadium_flagged_active{pool="${POOL}"} 3\n`);
    expect(text).toContain("\nvadium_drains_total 2\n");
    expect(text).toContain(`vadium_drained_total{pool="${POOL_B}"} 0\nvadium_drained_total{pool="${POOL}"} 1000000005\n`);
    expect(text).toContain("\nvadium_last_drain_block 61700200\n");
    expect(text).toContain("\nvadium_keeper_balance_wei 987654321000000000\n");
    expect(text).toContain("\nvadium_rpc_errors_total 2\n");
    expect(text).toContain("\nvadium_drain_errors_total 1\n");
    expect(text).toContain("\nvadium_paused 1\n");
    expect(m.lastDrainHash).toBe(HASH);
  });
});

describe("metrics server", () => {
  it("serves /metrics, /status and /healthz on an ephemeral port", async () => {
    const m = new Metrics([POOL]);
    let healthy = true;
    const srv = await startMetricsServer({
      port: 0,
      host: "127.0.0.1",
      metrics: m,
      log: silentLogger,
      status: { status: () => ({ headBlock: 5n, ok: "yes" }), healthy: () => healthy },
    });
    try {
      const base = `http://127.0.0.1:${srv.port}`;
      const metricsRes = await fetch(`${base}/metrics`);
      expect(metricsRes.status).toBe(200);
      expect(metricsRes.headers.get("content-type")).toBe("text/plain; version=0.0.4; charset=utf-8");
      expect(await metricsRes.text()).toBe(m.render());

      const statusRes = await fetch(`${base}/status`);
      expect(statusRes.status).toBe(200);
      expect(await statusRes.json()).toEqual({ headBlock: "5", ok: "yes" });

      expect((await fetch(`${base}/healthz`)).status).toBe(200);
      healthy = false;
      const unhealthy = await fetch(`${base}/healthz`);
      expect(unhealthy.status).toBe(503);
      expect(await unhealthy.json()).toEqual({ ok: false });

      expect((await fetch(`${base}/nope`)).status).toBe(404);
      expect((await fetch(`${base}/metrics`, { method: "POST" })).status).toBe(405);
    } finally {
      await srv.close();
    }
  });
});
