import { existsSync } from "node:fs";
import { createPublicClient, createWalletClient, getAddress, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { loadHookAbi } from "./abi.js";
import { chainFor } from "./chains.js";
import { ConfigError, describeConfig, loadConfig, type Config } from "./config.js";
import { runDrainTick, type DrainDeps, type DrainTickResult } from "./drain.js";
import { createLogger, type Level } from "./log.js";
import { Metrics, startMetricsServer } from "./metrics.js";
import { advanceBlock, loadState, newState, pruneExpired, recordFlag, saveState, StateFormatError, type KeeperState } from "./state.js";
import { backfill, startWatch, type FlagEvent } from "./watch.js";

/** Blocks re-scanned on restart in case the last checkpoint landed on a block that was later reorged. */
const REORG_MARGIN = 64n;
/** Head-block poll cadence for the live watcher. Unichain produces a block a second. */
const POLL_INTERVAL_MS = 2000;
/** How often the state file is written while idle (flags also trigger a write). */
const CHECKPOINT_INTERVAL_MS = 60_000;
/** Chain contact older than this makes /healthz report 503. */
const HEALTH_STALE_MS = 120_000;

async function main(): Promise<void> {
  if (existsSync(".env")) process.loadEnvFile(".env");
  const log = createLogger({ minLevel: (process.env.LOG_LEVEL as Level | undefined) ?? "info" });

  let cfg: Config;
  try {
    cfg = loadConfig();
  } catch (err) {
    log.error("invalid configuration", { error: err });
    if (!(err instanceof ConfigError)) throw err;
    process.exit(1);
  }
  const abi = loadHookAbi();
  const chain = chainFor(cfg.chainId);
  const transport = http(cfg.rpcUrl, { timeout: 30_000, retryCount: 2 });
  const publicClient = createPublicClient({ chain, transport });
  const account = privateKeyToAccount(cfg.privateKey);
  const walletClient = createWalletClient({ chain, transport, account });
  const hook = getAddress(cfg.hook);
  log.info("keeper starting", { ...describeConfig(cfg), signer: account.address });

  // Preflight: the RPC must be the configured chain and the signer must be the hook's keeper.
  const rpcChainId = await publicClient.getChainId();
  if (rpcChainId !== cfg.chainId) {
    log.error("refusing to start: RPC chain id does not match CHAIN_ID", { rpcChainId, chainId: cfg.chainId });
    process.exit(1);
  }
  const onchainKeeper = await publicClient.readContract({ address: hook, abi, functionName: "keeper" });
  if (onchainKeeper.toLowerCase() !== account.address.toLowerCase()) {
    log.error("refusing to start: keeper() on the hook is not the signer", { hook, keeper: onchainKeeper, signer: account.address });
    process.exit(1);
  }
  let lastChainOkAt = Date.now();

  // State: reuse the checkpoint when it belongs to this deployment, otherwise start at the deploy block.
  let state: KeeperState | null;
  try {
    state = await loadState(cfg.stateFile);
  } catch (err) {
    if (err instanceof StateFormatError) {
      log.error("state file is corrupt; delete it to rescan from START_BLOCK / the deploy block", { stateFile: cfg.stateFile, error: err });
      process.exit(1);
    }
    throw err;
  }
  if (state && (state.chainId !== cfg.chainId || state.hook !== hook)) {
    log.warn("state file belongs to a different deployment, starting fresh", { stateFile: cfg.stateFile, stateChainId: state.chainId, stateHook: state.hook, hook });
    state = null;
  }
  let scanFrom: bigint;
  if (state) {
    const rewound = state.lastBlock + 1n - REORG_MARGIN;
    scanFrom = rewound > 0n ? rewound : 0n;
    log.info("resuming from state file", { stateFile: cfg.stateFile, lastBlock: state.lastBlock, flagged: state.flagged.size, scanFrom });
  } else {
    scanFrom = cfg.startBlock ?? cfg.deployBlock;
    state = newState(cfg.chainId, hook, scanFrom - 1n);
    log.info("no usable state file, scanning from the start block", { stateFile: cfg.stateFile, scanFrom });
  }
  const st: KeeperState = state;

  const metrics = new Metrics(cfg.poolIds);
  let dirty = false;
  let saving: Promise<void> | null = null;
  const persist = async () => {
    if (saving) await saving;
    saving = saveState(cfg.stateFile, st)
      .then(() => {
        dirty = false;
      })
      .catch((err: unknown) => log.error("failed to write state file", { stateFile: cfg.stateFile, error: err }))
      .finally(() => {
        saving = null;
      });
    await saving;
  };
  const ingest = (e: FlagEvent) => {
    const changed = recordFlag(st, e.searcher, e.flaggedUntil);
    if (changed) {
      dirty = true;
      log.info("flag recorded", { searcher: e.searcher, flaggedUntil: e.flaggedUntil, blockNumber: e.blockNumber, event: e.event });
    }
  };

  // Backfill to the current head, then hand over to the live poller from the next block.
  const head = await publicClient.getBlockNumber();
  let ranges = 0;
  await backfill({
    client: publicClient,
    hook,
    abi,
    fromBlock: scanFrom,
    toBlock: head,
    step: cfg.backfillStep,
    onFlag: ingest,
    onProgress: async (through) => {
      advanceBlock(st, through);
      lastChainOkAt = Date.now();
      if (++ranges % 25 === 0) await persist();
    },
    log,
  });
  advanceBlock(st, head);
  pruneExpired(st, head);
  await persist();

  let headBlock = head;
  const watcher = startWatch({
    client: publicClient,
    hook,
    abi,
    fromBlock: head + 1n,
    pollingIntervalMs: POLL_INTERVAL_MS,
    step: cfg.backfillStep,
    onFlag: ingest,
    onHead: (h) => {
      headBlock = h;
      lastChainOkAt = Date.now();
    },
    onCovered: async (through) => {
      advanceBlock(st, through);
      if (dirty) await persist();
    },
    onError: (err) => {
      metrics.incRpcErrors();
      log.warn("watch poll failed, will retry", { error: err });
    },
    log,
  });

  // Drain loop.
  const deps: DrainDeps = {
    getBlockNumber: () => publicClient.getBlockNumber(),
    readContract: async (call) => {
      const value =
        call.functionName === "paused"
          ? await publicClient.readContract({ address: hook, abi, functionName: "paused" })
          : await publicClient.readContract({ address: hook, abi, functionName: "insuranceReserve", args: call.args });
      return value as never;
    },
    simulateContract: async (call) => {
      const { request, result } = await publicClient.simulateContract({ address: hook, abi, functionName: "drainFlagged", args: call.args, account });
      return { request, result };
    },
    writeContract: (request) => walletClient.writeContract(request as Parameters<typeof walletClient.writeContract>[0]),
    log,
  };

  let lastTick: DrainTickResult | null = null;
  let lastTickAt: string | null = null;
  let ticking: Promise<void> | null = null;
  const tick = async () => {
    if (ticking) {
      log.warn("previous drain tick still running, skipping this one");
      return;
    }
    ticking = (async () => {
      try {
        const balance = await publicClient.getBalance({ address: account.address });
        metrics.setKeeperBalance(balance);
      } catch (err) {
        metrics.incRpcErrors();
        log.warn("could not read keeper balance", { error: err });
      }
      const result = await runDrainTick(deps, { poolIds: cfg.poolIds, cap: cfg.drainCap, min: cfg.minDrain, state: st, metrics });
      lastTick = result;
      lastTickAt = new Date().toISOString();
      if (result.blockNumber !== null) {
        lastChainOkAt = Date.now();
        if (pruneExpired(st, result.blockNumber) > 0) dirty = true;
      }
      if (dirty) await persist();
    })().finally(() => {
      ticking = null;
    });
    await ticking;
  };

  const server = await startMetricsServer({
    port: cfg.metricsPort,
    metrics,
    log,
    status: {
      status: () => ({
        chainId: cfg.chainId,
        hook,
        keeper: account.address,
        poolIds: cfg.poolIds,
        paused: metrics.paused,
        headBlock,
        lastScannedBlock: st.lastBlock,
        flaggedKnown: st.flagged.size,
        flagged: Object.fromEntries([...st.flagged.entries()].map(([a, u]) => [a, u.toString()])),
        lastTickAt,
        lastTick,
        drainsTotal: metrics.drainsTotal,
        lastDrainBlock: metrics.lastDrainBlock,
        lastDrainHash: metrics.lastDrainHash,
        keeperBalanceWei: metrics.keeperBalanceWei,
        rpcErrorsTotal: metrics.rpcErrorsTotal,
        drainErrorsTotal: metrics.drainErrorsTotal,
        drainIntervalS: cfg.drainIntervalS,
        drainCap: cfg.drainCap,
        minDrain: cfg.minDrain,
        uptimeS: Math.floor(process.uptime()),
      }),
      healthy: () => Date.now() - lastChainOkAt < HEALTH_STALE_MS,
    },
  });

  await tick();
  const drainTimer = setInterval(() => void tick(), cfg.drainIntervalS * 1000);
  const checkpointTimer = setInterval(() => {
    if (dirty) void persist();
  }, CHECKPOINT_INTERVAL_MS);

  let shuttingDown = false;
  const shutdown = async (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    log.info("shutting down", { signal });
    clearInterval(drainTimer);
    clearInterval(checkpointTimer);
    await watcher.stop();
    if (ticking) await ticking;
    await persist();
    await server.close();
    log.info("stopped");
    process.exit(0);
  };
  process.on("SIGINT", () => void shutdown("SIGINT"));
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
}

main().catch((err: unknown) => {
  process.stderr.write(JSON.stringify({ ts: new Date().toISOString(), level: "error", msg: "keeper crashed", error: err instanceof Error ? { name: err.name, message: err.message, stack: err.stack } : err }) + "\n");
  process.exit(1);
});
