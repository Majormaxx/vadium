// Event ingestion: a bounded getLogs backfill, then a polling watcher. Only the
// searcher and its flaggedUntil are kept from each Sandwiched / Flagged log.

import { getAbiItem, type Address, type PublicClient } from "viem";
import type { HookAbi } from "./abi.js";
import type { Logger } from "./log.js";

export interface FlagEvent {
  searcher: Address;
  flaggedUntil: bigint;
  blockNumber: bigint;
  event: "Sandwiched" | "Flagged";
}

interface DecodedFlagLog {
  eventName: "Sandwiched" | "Flagged";
  blockNumber: bigint;
  args: { searcher: Address; flaggedUntil: bigint };
}

export function toFlagEvent(log: DecodedFlagLog): FlagEvent {
  return { searcher: log.args.searcher, flaggedUntil: log.args.flaggedUntil, blockNumber: log.blockNumber, event: log.eventName };
}

export interface BackfillOptions {
  client: PublicClient;
  hook: Address;
  abi: HookAbi;
  fromBlock: bigint;
  toBlock: bigint;
  step: bigint;
  onFlag(e: FlagEvent): void;
  /** Called after each range is folded in, with the last block now covered. */
  onProgress?(coveredThrough: bigint): void | Promise<void>;
  log: Logger;
  retries?: number;
  retryDelayMs?: number;
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/** Scan [fromBlock, toBlock] in ranges of `step` blocks. Returns the last block covered. */
export async function backfill(opts: BackfillOptions): Promise<bigint> {
  const { client, hook, abi, step, log } = opts;
  const retries = opts.retries ?? 5;
  const retryDelayMs = opts.retryDelayMs ?? 2000;
  const events = [getAbiItem({ abi, name: "Sandwiched" }), getAbiItem({ abi, name: "Flagged" })] as const;

  if (opts.fromBlock > opts.toBlock) return opts.fromBlock - 1n;
  const total = opts.toBlock - opts.fromBlock + 1n;
  log.info("backfill start", { fromBlock: opts.fromBlock, toBlock: opts.toBlock, step, blocks: total });

  let found = 0;
  for (let from = opts.fromBlock; from <= opts.toBlock; ) {
    const to = from + step - 1n < opts.toBlock ? from + step - 1n : opts.toBlock;
    let attempt = 0;
    for (;;) {
      try {
        const logs = await client.getLogs({ address: hook, events, fromBlock: from, toBlock: to, strict: true });
        for (const l of logs) {
          opts.onFlag(toFlagEvent(l as unknown as DecodedFlagLog));
          found++;
        }
        break;
      } catch (err) {
        attempt++;
        if (attempt > retries) throw err;
        log.warn("backfill getLogs failed, retrying", { from, to, attempt, error: err });
        await sleep(retryDelayMs * attempt);
      }
    }
    await opts.onProgress?.(to);
    from = to + 1n;
  }
  log.info("backfill done", { throughBlock: opts.toBlock, flagEvents: found });
  return opts.toBlock;
}

export interface WatchOptions {
  client: PublicClient;
  hook: Address;
  abi: HookAbi;
  /** First block the live watcher is responsible for (normally backfill end + 1). */
  fromBlock: bigint;
  pollingIntervalMs: number;
  /** Largest block range fetched per poll; the poller catches up in several polls after a stall. */
  step: bigint;
  onFlag(e: FlagEvent): void;
  /** Called with the head block after every successful head poll, even when there is nothing new to scan. */
  onHead?(head: bigint): void;
  /**
   * Called after each successful poll with the last block whose logs are folded in.
   * Only advances when the logs for that block were actually fetched, so it is safe
   * to persist as the scan checkpoint.
   */
  onCovered(coveredThrough: bigint): void | Promise<void>;
  onError(err: unknown): void;
  log: Logger;
}

export interface Watcher {
  /** Stop polling and wait for any poll that is mid-flight. */
  stop(): Promise<void>;
}

/**
 * Polls the head block and fetches Sandwiched / Flagged logs for every block not yet
 * covered. A failed poll leaves the coverage pointer where it was and is retried on
 * the next interval, so a flaky RPC can delay ingestion but never skip a block.
 *
 * This is a hand-rolled poller instead of viem's watchContractEvent because the
 * latter prefers eth_newFilter when the RPC accepts it, and a filter dropped by a
 * public RPC can leave it polling a dead filter while the head moves on. The
 * keeper must know exactly which blocks it has scanned.
 */
export function startWatch(opts: WatchOptions): Watcher {
  const { client, hook, abi, pollingIntervalMs, step, onFlag, onHead, onCovered, onError, log } = opts;
  const events = [getAbiItem({ abi, name: "Sandwiched" }), getAbiItem({ abi, name: "Flagged" })] as const;
  let covered = opts.fromBlock - 1n;
  let stopped = false;
  let timer: NodeJS.Timeout | null = null;
  let inFlight: Promise<void> | null = null;

  const poll = async () => {
    try {
      const head = await client.getBlockNumber();
      onHead?.(head);
      while (covered < head && !stopped) {
        const from = covered + 1n;
        const to = from + step - 1n < head ? from + step - 1n : head;
        const logs = await client.getLogs({ address: hook, events, fromBlock: from, toBlock: to, strict: true });
        for (const l of logs) onFlag(toFlagEvent(l as unknown as DecodedFlagLog));
        covered = to;
        await onCovered(to);
      }
    } catch (err) {
      onError(err);
    }
  };

  const schedule = () => {
    if (stopped) return;
    timer = setTimeout(() => {
      inFlight = poll().finally(() => {
        inFlight = null;
        schedule();
      });
    }, pollingIntervalMs);
  };

  log.info("watching hook events", { fromBlock: opts.fromBlock, pollingIntervalMs, step });
  inFlight = poll().finally(() => {
    inFlight = null;
    schedule();
  });

  return {
    stop: async () => {
      stopped = true;
      if (timer) clearTimeout(timer);
      if (inFlight) await inFlight;
    },
  };
}
