// Prometheus text exposition plus a JSON status page, on vanilla node:http.

import { createServer, type Server } from "node:http";
import type { Hex } from "viem";
import type { Logger } from "./log.js";

export class Metrics {
  readonly reserve = new Map<Hex, bigint>();
  readonly flaggedActive = new Map<Hex, number>();
  readonly drainedTotal = new Map<Hex, bigint>();
  drainsTotal = 0;
  lastDrainBlock = 0n;
  lastDrainHash: Hex | null = null;
  keeperBalanceWei = 0n;
  rpcErrorsTotal = 0;
  drainErrorsTotal = 0;
  paused = false;

  constructor(poolIds: readonly Hex[] = []) {
    for (const p of poolIds) this.registerPool(p);
  }

  registerPool(poolId: Hex): void {
    if (!this.reserve.has(poolId)) this.reserve.set(poolId, 0n);
    if (!this.flaggedActive.has(poolId)) this.flaggedActive.set(poolId, 0);
    if (!this.drainedTotal.has(poolId)) this.drainedTotal.set(poolId, 0n);
  }

  setReserve(poolId: Hex, reserve: bigint): void {
    this.registerPool(poolId);
    this.reserve.set(poolId, reserve);
  }

  setFlaggedActive(poolId: Hex, count: number): void {
    this.registerPool(poolId);
    this.flaggedActive.set(poolId, count);
  }

  recordDrain(poolId: Hex, amount: bigint, blockNumber: bigint, hash: Hex): void {
    this.registerPool(poolId);
    this.drainsTotal += 1;
    this.drainedTotal.set(poolId, (this.drainedTotal.get(poolId) ?? 0n) + amount);
    this.lastDrainBlock = blockNumber;
    this.lastDrainHash = hash;
  }

  incRpcErrors(): void {
    this.rpcErrorsTotal += 1;
  }

  incDrainErrors(): void {
    this.drainErrorsTotal += 1;
  }

  setPaused(paused: boolean): void {
    this.paused = paused;
  }

  setKeeperBalance(wei: bigint): void {
    this.keeperBalanceWei = wei;
  }

  /** Prometheus text format (version 0.0.4). Pools are emitted in sorted order so the output is stable. */
  render(): string {
    const lines: string[] = [];
    const family = (name: string, help: string, type: "gauge" | "counter") => {
      lines.push(`# HELP ${name} ${help}`, `# TYPE ${name} ${type}`);
    };
    const perPool = (name: string, values: Map<Hex, bigint | number>) => {
      for (const pool of [...values.keys()].sort()) lines.push(`${name}{pool="${pool}"} ${values.get(pool)!.toString()}`);
    };

    family("vadium_reserve", "Insurance reserve per pool, bond-token raw units.", "gauge");
    perPool("vadium_reserve", this.reserve);
    family("vadium_flagged_active", "Flagged addresses whose flag was active at the last tick, per pool.", "gauge");
    perPool("vadium_flagged_active", this.flaggedActive);
    family("vadium_drains_total", "Drain transactions submitted since start.", "counter");
    lines.push(`vadium_drains_total ${this.drainsTotal}`);
    family("vadium_drained_total", "Bond-token raw units paid out since start, per pool.", "counter");
    perPool("vadium_drained_total", this.drainedTotal);
    family("vadium_last_drain_block", "Block number at which the last drain was submitted.", "gauge");
    lines.push(`vadium_last_drain_block ${this.lastDrainBlock}`);
    family("vadium_keeper_balance_wei", "Native balance of the keeper signer, wei.", "gauge");
    lines.push(`vadium_keeper_balance_wei ${this.keeperBalanceWei}`);
    family("vadium_rpc_errors_total", "Failed chain calls since start.", "counter");
    lines.push(`vadium_rpc_errors_total ${this.rpcErrorsTotal}`);
    family("vadium_drain_errors_total", "Drain simulations or submissions that failed since start.", "counter");
    lines.push(`vadium_drain_errors_total ${this.drainErrorsTotal}`);
    family("vadium_paused", "1 when the hook is paused, else 0.", "gauge");
    lines.push(`vadium_paused ${this.paused ? 1 : 0}`);
    return lines.join("\n") + "\n";
  }
}

export interface StatusProvider {
  status(): Record<string, unknown>;
  healthy(): boolean;
}

function jsonReplacer(_key: string, value: unknown): unknown {
  return typeof value === "bigint" ? value.toString() : value;
}

export interface MetricsServer {
  server: Server;
  port: number;
  close(): Promise<void>;
}

export function startMetricsServer(opts: { port: number; metrics: Metrics; status: StatusProvider; log: Logger; host?: string }): Promise<MetricsServer> {
  const { metrics, status, log } = opts;
  const server = createServer((req, res) => {
    const path = (req.url ?? "/").split("?")[0];
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.writeHead(405, { "content-type": "text/plain" }).end("method not allowed\n");
      return;
    }
    if (path === "/metrics") {
      res.writeHead(200, { "content-type": "text/plain; version=0.0.4; charset=utf-8" }).end(metrics.render());
    } else if (path === "/status") {
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(status.status(), jsonReplacer, 2) + "\n");
    } else if (path === "/healthz") {
      const ok = status.healthy();
      res.writeHead(ok ? 200 : 503, { "content-type": "application/json" }).end(JSON.stringify({ ok }) + "\n");
    } else {
      res.writeHead(404, { "content-type": "text/plain" }).end("not found\n");
    }
  });
  server.on("error", (err) => log.error("metrics server error", { error: err }));
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(opts.port, opts.host ?? "0.0.0.0", () => {
      server.off("error", reject);
      const addr = server.address();
      const port = typeof addr === "object" && addr ? addr.port : opts.port;
      log.info("metrics server listening", { port });
      resolve({
        server,
        port,
        close: () =>
          new Promise<void>((res, rej) => {
            server.close((err) => (err ? rej(err) : res()));
            server.closeAllConnections();
          }),
      });
    });
  });
}
