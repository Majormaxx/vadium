import { describe, expect, it } from "vitest";
import { createLogger, formatLine } from "../src/log.js";

const now = () => new Date("2026-09-27T10:00:00.000Z");

describe("log", () => {
  it("emits one JSON object per line with bigints as strings and errors flattened", () => {
    const line = formatLine("info", "drain submitted", { amount: 10n ** 20n, error: new Error("boom") }, now);
    expect(line).toBe('{"ts":"2026-09-27T10:00:00.000Z","level":"info","msg":"drain submitted","amount":"100000000000000000000","error":{"name":"Error","message":"boom"}}');
  });

  it("respects the minimum level and merges child fields", () => {
    const lines: string[] = [];
    const log = createLogger({ minLevel: "warn", write: (l) => lines.push(l), now }).child({ pool: "p1" });
    log.info("hidden");
    log.warn("shown", { n: 1 });
    expect(lines).toEqual(['{"ts":"2026-09-27T10:00:00.000Z","level":"warn","msg":"shown","pool":"p1","n":1}']);
  });
});
