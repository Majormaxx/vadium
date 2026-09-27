// Typed client for the indexer. Every call returns an ApiResult instead of
// throwing, so a page can render what it has when the indexer is down.
// All big numbers are decimal strings, exactly as the indexer sends them.

import type { StalenessSummary } from "./staleness";

export type Checkpoint = {
  blockNumber: string;
  sqrtPriceX96: string;
  liquidity: string;
};

export type PoolSummary = {
  poolId: string;
  chainId: number;
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  reserve: string;
  slashedPledged: string;
  withdrawn: string;
  sandwiches: number;
  refundsCredited: string;
  refundsClaimed: string;
  withheld0: string;
  withheld1: string;
  lastCheckpoint: Checkpoint | null;
  bondedCount: number;
};

export type PoolDetail = PoolSummary & { staleness: StalenessSummary | null };

export type SlashItem = {
  txHash: string;
  blockNumber: string;
  timestamp: string;
  searcher: string;
  slashed: string;
  isRepeat: boolean;
  remaining: string;
  flaggedUntil: string;
  refunded: string;
};

export type RefundItem = {
  txHash: string;
  blockNumber: string;
  victim: string;
  searcher: string;
  amount: string;
  claimed: boolean;
};

export type BondedItem = {
  searcher: string;
  amount: string;
  depositBlock: string;
  strikeCount: number;
  bannedUntil: string;
  flaggedUntil: string;
};

export type WithheldItem = {
  txHash: string;
  blockNumber: string;
  sender: string;
  currency: string;
  amount: string;
};

export type Bond = {
  amount: string;
  depositBlock: string;
  strikeCount: number;
  bannedUntil: string;
  flaggedUntil: string;
};

export type FlagItem = {
  txHash: string;
  blockNumber: string;
  poolId: string;
  slashed: string;
  evidenceHash: string;
  flaggedUntil: string;
};

export type SearcherDetail = {
  searcher: string;
  bond: Bond | null;
  slashes: SlashItem[];
  flags: FlagItem[];
};

export type IndexerStatus = {
  chainId: number;
  indexedBlock: string;
  headBlock: string | null;
  hook: string;
  lag: string | null;
};

export type ApiError =
  | { kind: "not_found"; url: string }
  | { kind: "http"; url: string; status: number }
  | { kind: "network"; url: string; message: string }
  | { kind: "parse"; url: string; message: string };

export type ApiResult<T> = { ok: true; data: T } | { ok: false; error: ApiError };

export function describeError(error: ApiError): string {
  switch (error.kind) {
    case "not_found":
      return "not found";
    case "http":
      return `indexer answered HTTP ${error.status}`;
    case "network":
      return `indexer unreachable (${error.message})`;
    case "parse":
      return `indexer sent an unexpected response (${error.message})`;
  }
}

export const DEFAULT_INDEXER_URL = "http://localhost:42069";

export function indexerUrlFromEnv(): string {
  const url = process.env.NEXT_PUBLIC_INDEXER_URL?.trim();
  return (url && url.length > 0 ? url : DEFAULT_INDEXER_URL).replace(/\/+$/, "");
}

type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export type ApiOptions = {
  baseUrl: string;
  fetch?: FetchLike;
  /** Milliseconds before a request is abandoned. */
  timeoutMs?: number;
};

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function expectItems<T>(body: unknown): T[] {
  if (!isRecord(body) || !Array.isArray(body.items)) throw new Error("missing items[]");
  return body.items as T[];
}

export function createApi(options: ApiOptions) {
  const baseUrl = options.baseUrl.replace(/\/+$/, "");
  const doFetch: FetchLike = options.fetch ?? ((input, init) => fetch(input, init));
  const timeoutMs = options.timeoutMs ?? 8_000;

  async function get<T>(path: string, parse: (body: unknown) => T): Promise<ApiResult<T>> {
    const url = `${baseUrl}${path}`;
    let response: Response;
    const controller = typeof AbortController === "function" ? new AbortController() : null;
    const timer = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
    try {
      response = await doFetch(url, {
        cache: "no-store",
        headers: { accept: "application/json" },
        signal: controller?.signal,
      });
    } catch (err) {
      return { ok: false, error: { kind: "network", url, message: errorMessage(err) } };
    } finally {
      if (timer) clearTimeout(timer);
    }
    if (response.status === 404) return { ok: false, error: { kind: "not_found", url } };
    if (!response.ok) return { ok: false, error: { kind: "http", url, status: response.status } };
    let body: unknown;
    try {
      body = await response.json();
    } catch (err) {
      return { ok: false, error: { kind: "parse", url, message: errorMessage(err) } };
    }
    try {
      return { ok: true, data: parse(body) };
    } catch (err) {
      return { ok: false, error: { kind: "parse", url, message: errorMessage(err) } };
    }
  }

  return {
    baseUrl,
    pools: () =>
      get<PoolSummary[]>("/pools", (body) => {
        if (!isRecord(body) || !Array.isArray(body.pools)) throw new Error("missing pools[]");
        return body.pools as PoolSummary[];
      }),
    pool: (poolId: string) =>
      get<PoolDetail>(`/pools/${poolId}`, (body) => {
        if (!isRecord(body) || typeof body.poolId !== "string") throw new Error("missing poolId");
        return body as PoolDetail;
      }),
    slashes: (poolId: string, limit = 50) =>
      get<SlashItem[]>(`/pools/${poolId}/slashes?limit=${limit}`, expectItems<SlashItem>),
    refunds: (poolId: string) => get<RefundItem[]>(`/pools/${poolId}/refunds`, expectItems<RefundItem>),
    bonded: (poolId: string) => get<BondedItem[]>(`/pools/${poolId}/bonded`, expectItems<BondedItem>),
    withheld: (poolId: string) =>
      get<WithheldItem[]>(`/pools/${poolId}/withheld`, expectItems<WithheldItem>),
    staleness: (poolId: string, window = 1000) =>
      get<StalenessSummary>(`/pools/${poolId}/staleness?window=${window}`, (body) => {
        if (!isRecord(body) || !Array.isArray(body.series)) throw new Error("missing series[]");
        return body as StalenessSummary;
      }),
    searcher: (address: string) =>
      get<SearcherDetail>(`/searchers/${address}`, (body) => {
        if (!isRecord(body) || typeof body.searcher !== "string") throw new Error("missing searcher");
        return {
          searcher: body.searcher,
          bond: isRecord(body.bond) ? (body.bond as Bond) : null,
          slashes: Array.isArray(body.slashes) ? (body.slashes as SlashItem[]) : [],
          flags: Array.isArray(body.flags) ? (body.flags as FlagItem[]) : [],
        };
      }),
    status: () =>
      get<IndexerStatus>("/indexer/status", (body) => {
        if (!isRecord(body) || !("indexedBlock" in body)) throw new Error("missing indexedBlock");
        return body as IndexerStatus;
      }),
  };
}

export type Api = ReturnType<typeof createApi>;

function errorMessage(err: unknown): string {
  if (err instanceof Error) {
    const cause = (err as Error & { cause?: unknown }).cause;
    if (cause instanceof Error && cause.message) return `${err.message}: ${cause.message}`;
    return err.message;
  }
  return String(err);
}

/** Client bound to NEXT_PUBLIC_INDEXER_URL. Built per call so env is read at request time. */
export function indexer(): Api {
  return createApi({ baseUrl: indexerUrlFromEnv() });
}
