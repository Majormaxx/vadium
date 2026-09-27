import { describe, expect, it } from "vitest";
import { createApi, describeError, type PoolSummary } from "@/lib/api";

const poolFixture: PoolSummary = {
  poolId: "0x8e04e9c3fd9137cdc79ef352d1b1af9c5b3c5384cca2d8641c754bd6a2000304",
  chainId: 1301,
  currency0: "0x0000000000000000000000000000000000000000",
  currency1: "0x31d0220469e10c4E71834a79b1f276d740d3768F",
  fee: 3000,
  tickSpacing: 10,
  reserve: "1500000",
  slashedPledged: "2000000",
  withdrawn: "500000",
  sandwiches: 2,
  refundsCredited: "400000",
  refundsClaimed: "100000",
  withheld0: "12345",
  withheld1: "0",
  lastCheckpoint: { blockNumber: "61591813", sqrtPriceX96: "79228162514264337593543950336", liquidity: "1000" },
  bondedCount: 3,
};

type Call = { url: string; init: RequestInit | undefined };

function fetchWith(handler: (url: string) => Response | Promise<Response>, calls: Call[] = []) {
  return async (url: string, init?: RequestInit) => {
    calls.push({ url, init });
    return handler(url);
  };
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

describe("createApi", () => {
  it("parses /pools and sends cache: no-store to the right url", async () => {
    const calls: Call[] = [];
    const api = createApi({
      baseUrl: "http://indexer.test/",
      fetch: fetchWith(() => json({ pools: [poolFixture] }), calls),
    });
    const result = await api.pools();
    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error("expected ok");
    expect(result.data).toHaveLength(1);
    expect(result.data[0].reserve).toBe("1500000");
    expect(calls[0].url).toBe("http://indexer.test/pools");
    expect(calls[0].init?.cache).toBe("no-store");
  });

  it("parses every list route through items[]", async () => {
    const api = createApi({
      baseUrl: "http://indexer.test",
      fetch: fetchWith((url) => {
        if (url.endsWith("/slashes?limit=10")) return json({ items: [{ txHash: "0x1", slashed: "5" }] });
        if (url.endsWith("/refunds")) return json({ items: [{ txHash: "0x2", amount: "1" }] });
        if (url.endsWith("/bonded")) return json({ items: [{ searcher: "0xabc" }] });
        if (url.endsWith("/withheld")) return json({ items: [] });
        return json({}, 500);
      }),
    });
    const id = poolFixture.poolId;
    const slashes = await api.slashes(id, 10);
    const refunds = await api.refunds(id);
    const bonded = await api.bonded(id);
    const withheld = await api.withheld(id);
    expect(slashes.ok && slashes.data[0].slashed).toBe("5");
    expect(refunds.ok && refunds.data[0].amount).toBe("1");
    expect(bonded.ok && bonded.data[0].searcher).toBe("0xabc");
    expect(withheld.ok && withheld.data).toEqual([]);
  });

  it("parses /pools/:id, /staleness, /searchers/:address and /status", async () => {
    const api = createApi({
      baseUrl: "http://indexer.test",
      fetch: fetchWith((url) => {
        if (url.endsWith("/staleness?window=500")) {
          return json({ window: 500, count: 2, p50: 3, p95: 9, mean: 6, series: [{ blockNumber: "1", startSqrtPriceX96: "1", endSqrtPriceX96: "2", deviation: 3 }] });
        }
        if (url.includes("/pools/0x")) return json({ ...poolFixture, staleness: null });
        if (url.includes("/searchers/")) {
          return json({ searcher: "0xabc", bond: null, slashes: [], flags: [{ txHash: "0xf" }] });
        }
        if (url.endsWith("/indexer/status")) {
          return json({ chainId: 1301, indexedBlock: "10", headBlock: "12", hook: "0xhook", lag: "2" });
        }
        return json({}, 500);
      }),
    });
    const pool = await api.pool(poolFixture.poolId);
    expect(pool.ok && pool.data.bondedCount).toBe(3);
    const staleness = await api.staleness(poolFixture.poolId, 500);
    expect(staleness.ok && staleness.data.p95).toBe(9);
    const searcher = await api.searcher("0xabc");
    expect(searcher.ok && searcher.data.flags).toHaveLength(1);
    expect(searcher.ok && searcher.data.bond).toBeNull();
    const status = await api.status();
    expect(status.ok && status.data.lag).toBe("2");
  });

  it("maps 404 to not_found", async () => {
    const api = createApi({ baseUrl: "http://indexer.test", fetch: fetchWith(() => json({ error: "no" }, 404)) });
    const result = await api.pool("0xdead");
    expect(result).toEqual({ ok: false, error: { kind: "not_found", url: "http://indexer.test/pools/0xdead" } });
    if (!result.ok) expect(describeError(result.error)).toBe("not found");
  });

  it("maps other failures to http with the status", async () => {
    const api = createApi({ baseUrl: "http://indexer.test", fetch: fetchWith(() => json({}, 503)) });
    const result = await api.status();
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.kind).toBe("http");
      expect(describeError(result.error)).toBe("indexer answered HTTP 503");
    }
  });

  it("maps a thrown fetch to network", async () => {
    const api = createApi({
      baseUrl: "http://indexer.test",
      fetch: async () => {
        throw new TypeError("fetch failed", { cause: new Error("ECONNREFUSED") });
      },
    });
    const result = await api.pools();
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error.kind).toBe("network");
      expect(describeError(result.error)).toBe("indexer unreachable (fetch failed: ECONNREFUSED)");
    }
  });

  it("maps bad JSON and a wrong shape to parse", async () => {
    const bad = createApi({
      baseUrl: "http://indexer.test",
      fetch: fetchWith(() => new Response("<html>", { status: 200 })),
    });
    const notJson = await bad.pools();
    expect(!notJson.ok && notJson.error.kind).toBe("parse");

    const wrong = createApi({ baseUrl: "http://indexer.test", fetch: fetchWith(() => json({ nope: [] })) });
    const wrongShape = await wrong.pools();
    expect(!wrongShape.ok && wrongShape.error.kind).toBe("parse");
    if (!wrongShape.ok) expect(describeError(wrongShape.error)).toContain("missing pools[]");
  });
});
