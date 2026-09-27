#!/usr/bin/env node
// Usage:
//   tsx src/cli.ts plan [--liquidity <n>] [--sqrt-price <n>] [--lp-fee <pips>] [--min-bond <n>] [--scenarios a,b]
//   tsx src/cli.ts run [--execute] [--scenarios a,b]
//   tsx src/cli.ts withdraw-bond --role <A|B|...> [--execute]
//   tsx src/cli.ts claim-refund [--execute]
//
// Nothing is broadcast without --execute.

import { join } from "node:path";

import { GENERATED_DIR, SERVICE_DIR, loadDeployment, loadHookAbi, loadRouterArtifact } from "./artifacts.js";
import { makeClients } from "./chain.js";
import { loadConfig, loadDotEnv, parseScenarioList } from "./config.js";
import { summarize, timestampSlug, writeJson, type PlanFile } from "./report.js";
import {
  PLACEHOLDER_OWNER,
  buildPlanFile,
  claimRefund,
  loadRouters,
  planScenarios,
  preflight,
  run,
  withdrawBond,
  type RunnerContext,
} from "./runner.js";
import type { Role } from "./scenarios.js";
import { Q96 } from "./sizing.js";

interface Args {
  command: string | undefined;
  flags: Map<string, string | true>;
}

export function parseArgs(argv: string[]): Args {
  const flags = new Map<string, string | true>();
  let command: string | undefined;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i] as string;
    if (a.startsWith("--")) {
      const name = a.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("--")) {
        flags.set(name, next);
        i++;
      } else {
        flags.set(name, true);
      }
    } else if (command === undefined) {
      command = a;
    } else {
      throw new Error(`unexpected argument ${a}`);
    }
  }
  return { command, flags };
}

function bigintFlag(flags: Map<string, string | true>, name: string): bigint | undefined {
  const v = flags.get(name);
  if (v === undefined) return undefined;
  if (v === true || !/^\d+$/.test(v)) throw new Error(`--${name} needs a non-negative integer`);
  return BigInt(v);
}

const USAGE = `usage:
  pnpm plan [--liquidity <n>] [--sqrt-price <n>] [--lp-fee <pips>] [--min-bond <n>] [--scenarios a,b]
  pnpm run  [--execute] [--scenarios a,b]
  tsx src/cli.ts withdraw-bond --role <role> [--execute]
  tsx src/cli.ts claim-refund [--execute]`;

async function main(): Promise<void> {
  loadDotEnv(SERVICE_DIR);
  const { command, flags } = parseArgs(process.argv.slice(2));
  const config = loadConfig();
  const scenarioFlag = flags.get("scenarios");
  const scenarios = typeof scenarioFlag === "string" ? parseScenarioList(scenarioFlag) : config.scenarios;
  const reportsDir = join(SERVICE_DIR, "reports");
  const log = (line: string): void => {
    console.log(line);
  };

  if (command === "plan" && flags.has("liquidity")) {
    // Offline: no RPC. Deployment record and flags supply everything.
    const deployment = loadDeployment(config.chainId, GENERATED_DIR);
    const liquidity = bigintFlag(flags, "liquidity") as bigint;
    const sqrtPriceX96 = bigintFlag(flags, "sqrt-price") ?? Q96;
    const lpFeePips = Number(bigintFlag(flags, "lp-fee") ?? BigInt(deployment.poolKey.fee));
    const minBond = bigintFlag(flags, "min-bond") ?? 100_000_000n;
    const owner = config.address ?? (config.privateKey !== undefined ? makeClients(config).owner : undefined);
    const snapshot = { liquidity, sqrtPriceX96, lpFeePips };
    const planned = planScenarios(config, snapshot, minBond, owner ?? PLACEHOLDER_OWNER, scenarios);
    const routers = loadRouters(join(SERVICE_DIR, "routers.json"), config.chainId);
    const planFile = buildPlanFile({
      mode: "offline",
      deployment,
      owner,
      snapshot,
      minBond,
      planned,
      routers,
      notes: [
        "offline plan: liquidity, price, and minBond came from flags, not the chain",
        `minBond ${minBond} is the --min-bond flag (default 100000000); an online plan reads it from the hook`,
        ...(owner === undefined ? ["owner unset: the victim's hookData uses a placeholder; set SIM_ADDRESS or SIM_PRIVATE_KEY"] : []),
      ],
    });
    const path = writeJson(reportsDir, `${timestampSlug()}-plan.json`, planFile);
    printPlan(planFile, log);
    log(`plan written to ${path}`);
    return;
  }

  const ctx: RunnerContext = {
    config,
    clients: makeClients(config),
    deployment: loadDeployment(config.chainId, GENERATED_DIR),
    routerArtifact: loadRouterArtifact(GENERATED_DIR),
    hookAbi: loadHookAbi(GENERATED_DIR),
    routersFile: join(SERVICE_DIR, "routers.json"),
    reportsDir,
    log,
  };

  switch (command) {
    case "plan": {
      const pre = await preflight(ctx);
      const owner = ctx.clients.owner ?? PLACEHOLDER_OWNER;
      const planned = planScenarios(config, pre.snapshot, pre.bondParams.minBond, owner, scenarios);
      const routers = loadRouters(ctx.routersFile, config.chainId);
      const planFile = buildPlanFile({ mode: "online", deployment: ctx.deployment, owner: ctx.clients.owner, snapshot: pre.snapshot, minBond: pre.bondParams.minBond, planned, routers, notes: pre.warnings });
      const path = writeJson(reportsDir, `${timestampSlug()}-plan.json`, planFile);
      printPlan(planFile, log);
      log(`plan written to ${path}`);
      return;
    }
    case "run": {
      const execute = flags.get("execute") === true;
      const { reports } = await run(ctx, { execute, scenarios });
      if (execute) {
        log("\n== summary");
        for (const r of reports) {
          log(`${r.pass ? "PASS" : r.needsRetry ? "RETRY" : "FAIL"} ${r.scenario}`);
          log(summarize(r.expectations));
        }
        const failed = reports.filter((r) => !r.pass);
        if (failed.length > 0 || reports.length < scenarios.length) process.exitCode = 1;
      }
      return;
    }
    case "withdraw-bond": {
      const role = flags.get("role");
      if (typeof role !== "string" || !["A", "V", "M", "B", "F"].includes(role)) throw new Error("--role must be one of A, V, M, B, F");
      await withdrawBond(ctx, role as Role, flags.get("execute") === true);
      return;
    }
    case "claim-refund": {
      await claimRefund(ctx, flags.get("execute") === true);
      return;
    }
    default:
      throw new Error(USAGE);
  }
}

function printPlan(plan: PlanFile, log: (s: string) => void): void {
  log(`plan (${plan.mode}) for chain ${plan.chainId}, hook ${plan.hook}, owner ${plan.owner}`);
  log(`pool liquidity ${plan.snapshot.liquidity}, sqrtPriceX96 ${plan.snapshot.sqrtPriceX96}, lp fee ${plan.snapshot.lpFeePips} pips`);
  log(`legs: eth ${plan.sizing.ethLeg} wei, usdc ${plan.sizing.usdcLeg} raw, reverse ${plan.sizing.reverseUsdcLeg} raw; minBond ${plan.minBond}`);
  for (const s of plan.scenarios) {
    log(`\n${s.name}: ${s.description}`);
    for (const tx of s.txs) {
      const args = Object.entries(tx.args)
        .map(([k, v]) => `${k}=${typeof v === "bigint" ? v.toString() : String(v)}`)
        .join(" ");
      log(`  ${tx.index} [${tx.phase}] ${tx.role} -> ${tx.router} ${tx.function} ${args} value=${tx.value}  # ${tx.label}`);
    }
    for (const e of s.expectations) log(`  expect ${e.id}: ${e.description}`);
  }
  log(`\ntotals: ${plan.totals.txCount} txs, ${plan.totals.ethIn} wei in, ${plan.totals.usdcIn} raw USDC in, ${plan.totals.bonds} raw USDC bonded`);
  for (const n of plan.notes) log(`note: ${n}`);
}

main().catch((err: unknown) => {
  console.error((err as Error).message);
  process.exit(1);
});
