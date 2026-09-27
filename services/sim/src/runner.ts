// Talks to the chain: preflight reads, router deployment, approvals, same-block batch
// submission, receipt decoding, and report writing. Everything it decides from is
// computed by the pure modules (sizing, scenarios, evaluate).

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  decodeEventLog,
  encodeFunctionData,
  formatEther,
  getAddress,
  maxUint256,
  type Abi,
  type Address,
  type Hex,
  type TransactionReceipt,
} from "viem";

import {
  erc20Abi,
  poolManagerEventsAbi,
  stateViewAbi,
  type Deployment,
} from "./artifacts.js";
import type { Clients } from "./chain.js";
import type { SimConfig } from "./config.js";
import { evaluate, type DecodedEvent, type Outcome, type StateSnapshot, type StepOutcome } from "./evaluate.js";
import {
  buildReport,
  plannedTx,
  planTotals,
  reportFileName,
  summarize,
  timestampSlug,
  writeJson,
  type PlanFile,
  type Report,
} from "./report.js";
import {
  planScenario,
  rolesFor,
  totalLegCounts,
  type PlannedCall,
  type Role,
  type ScenarioName,
  type ScenarioPlan,
} from "./scenarios.js";
import { sizeLegs, type PoolSnapshot, type Sizing } from "./sizing.js";

export interface RunnerContext {
  config: SimConfig;
  clients: Clients;
  deployment: Deployment;
  routerArtifact: { abi: Abi; bytecode: Hex };
  hookAbi: Abi;
  routersFile: string;
  reportsDir: string;
  log: (line: string) => void;
}

export interface BondParams {
  minBond: bigint;
  minBondDurationBlocks: bigint;
  firstSlashBps: bigint;
  firstOffenseLockExtensionBlocks: bigint;
  repeatOffenseBanBlocks: bigint;
  victimRefundBps: bigint;
  refundClaimWindowBlocks: bigint;
}

export interface PoolConfig {
  clampEnabled: boolean;
  exemptFirstSwapOnly: boolean;
  requireVictimLoss: boolean;
}

export interface Preflight {
  blockNumber: bigint;
  snapshot: PoolSnapshot;
  bondParams: BondParams;
  poolConfig: PoolConfig;
  ethBalance: bigint | undefined;
  usdcBalance: bigint | undefined;
  warnings: string[];
}

export type Routers = Partial<Record<Role, Address>>;

// ---------------------------------------------------------------------------
// routers.json
// ---------------------------------------------------------------------------

type RoutersFile = Record<string, Partial<Record<Role, string>>>;

export function loadRouters(file: string, chainId: number): Routers {
  if (!existsSync(file)) return {};
  const all = JSON.parse(readFileSync(file, "utf8")) as RoutersFile;
  const entry = all[String(chainId)] ?? {};
  const out: Routers = {};
  for (const [role, addr] of Object.entries(entry)) {
    if (typeof addr === "string") out[role as Role] = getAddress(addr);
  }
  return out;
}

export function saveRouter(file: string, chainId: number, role: Role, address: Address): void {
  const all: RoutersFile = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as RoutersFile) : {};
  const entry = all[String(chainId)] ?? {};
  entry[role] = address;
  all[String(chainId)] = entry;
  writeFileSync(file, JSON.stringify(all, null, 2) + "\n");
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

async function hookRead<T>(ctx: RunnerContext, functionName: string, args: unknown[] = []): Promise<T> {
  return (await ctx.clients.publicClient.readContract({
    address: ctx.deployment.hook,
    abi: ctx.hookAbi,
    functionName,
    args,
  })) as T;
}

async function readPoolSnapshot(ctx: RunnerContext): Promise<PoolSnapshot> {
  const { publicClient } = ctx.clients;
  const { stateView, poolId } = ctx.deployment;
  const [slot0, liquidity] = await Promise.all([
    publicClient.readContract({ address: stateView, abi: stateViewAbi, functionName: "getSlot0", args: [poolId] }),
    publicClient.readContract({ address: stateView, abi: stateViewAbi, functionName: "getLiquidity", args: [poolId] }),
  ]);
  return { liquidity, sqrtPriceX96: slot0[0], lpFeePips: Number(slot0[3]) };
}

export async function preflight(ctx: RunnerContext): Promise<Preflight> {
  const { publicClient, owner } = ctx.clients;
  const d = ctx.deployment;
  const warnings: string[] = [];

  const chainId = await publicClient.getChainId();
  if (chainId !== ctx.config.chainId) {
    throw new Error(`RPC_URL serves chain ${chainId}, config expects ${ctx.config.chainId}`);
  }
  const code = await publicClient.getCode({ address: d.hook });
  if (code === undefined || code === "0x") throw new Error(`no code at hook ${d.hook} on chain ${chainId}`);

  let bondParams: BondParams;
  let poolConfig: PoolConfig;
  try {
    const registered = await hookRead<boolean>(ctx, "isPoolRegistered", [d.poolId]);
    if (!registered) throw new Error(`pool ${d.poolId} is not registered on hook ${d.hook}`);
    bondParams = await hookRead<BondParams>(ctx, "bondParams");
    poolConfig = await hookRead<PoolConfig>(ctx, "poolConfig", [d.poolId]);
    // The clamp views exist only on the accountable-arbitrage hook.
    await hookRead<unknown>(ctx, "checkpoint", [d.poolId]);
    await hookRead<bigint>(ctx, "withheld", [d.poolId, d.poolKey.currency0]);
  } catch (err) {
    throw new Error(
      `hook ${d.hook} does not answer the clamp interface (${(err as Error).message.split("\n")[0]}). ` +
        "The deployment record predates the clamp; redeploy with `make deploy-sepolia` at the repo root, " +
        "then rerun `pnpm artifacts`.",
    );
  }
  if (!poolConfig.clampEnabled) warnings.push("pool config has clampEnabled=false: nothing will be withheld");
  if (!poolConfig.exemptFirstSwapOnly) {
    warnings.push("pool config has exemptFirstSwapOnly=false: a bonded back-run will not be clamped");
  }

  const snapshot = await readPoolSnapshot(ctx);
  const blockNumber = await publicClient.getBlockNumber();

  let ethBalance: bigint | undefined;
  let usdcBalance: bigint | undefined;
  if (owner !== undefined) {
    ethBalance = await publicClient.getBalance({ address: owner });
    usdcBalance = await publicClient.readContract({
      address: d.bondToken,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [owner],
    });
  } else {
    warnings.push("no SIM_PRIVATE_KEY or SIM_ADDRESS: balances not checked");
  }
  return { blockNumber, snapshot, bondParams, poolConfig, ethBalance, usdcBalance, warnings };
}

async function readBonded(ctx: RunnerContext, router: Address): Promise<bigint> {
  return hookRead<bigint>(ctx, "bondedBalance", [router]);
}

async function snapshotState(ctx: RunnerContext, roles: Role[], routers: Routers, owner: Address): Promise<StateSnapshot> {
  const d = ctx.deployment;
  const pool = await readPoolSnapshot(ctx);
  const [blockNumber, insuranceReserve, withheld0, withheld1, ownerClaimable] = await Promise.all([
    ctx.clients.publicClient.getBlockNumber(),
    hookRead<bigint>(ctx, "insuranceReserve", [d.poolId]),
    hookRead<bigint>(ctx, "withheld", [d.poolId, d.poolKey.currency0]),
    hookRead<bigint>(ctx, "withheld", [d.poolId, d.poolKey.currency1]),
    hookRead<bigint>(ctx, "claimableRefund", [owner]),
  ]);
  const bondedBalance: Partial<Record<Role, bigint>> = {};
  const isExempt: Partial<Record<Role, boolean>> = {};
  for (const role of roles) {
    const router = routers[role];
    if (router === undefined) continue;
    bondedBalance[role] = await readBonded(ctx, router);
    isExempt[role] = await hookRead<boolean>(ctx, "isExempt", [d.poolId, router]);
  }
  return {
    blockNumber,
    sqrtPriceX96: pool.sqrtPriceX96,
    liquidity: pool.liquidity,
    insuranceReserve,
    withheld0,
    withheld1,
    ownerClaimable,
    bondedBalance,
    isExempt,
  };
}

// ---------------------------------------------------------------------------
// Planning
// ---------------------------------------------------------------------------

export interface Planned {
  sizing: Sizing;
  plans: ScenarioPlan[];
  roles: Role[];
}

export function planScenarios(
  config: SimConfig,
  snapshot: PoolSnapshot,
  minBond: bigint,
  owner: Address,
  names: readonly ScenarioName[] = config.scenarios,
): Planned {
  const sizing = sizeLegs(
    snapshot,
    { usdc: config.usdcBudget, ethWei: config.ethBudgetWei },
    config.swapFractionBps,
    totalLegCounts(names),
  );
  const input = { sizing, minBond, owner };
  const plans = names.map((n) => planScenario(n, input));
  return { sizing, plans, roles: rolesFor(names, input) };
}

export function buildPlanFile(input: {
  mode: "offline" | "online";
  deployment: Deployment;
  owner: Address | undefined;
  snapshot: PoolSnapshot;
  minBond: bigint;
  planned: Planned;
  routers: Routers;
  notes?: string[];
  now?: Date;
}): PlanFile {
  const { planned } = input;
  return {
    version: 1,
    kind: "plan",
    generatedAt: (input.now ?? new Date()).toISOString(),
    mode: input.mode,
    chainId: input.deployment.chainId,
    hook: input.deployment.hook,
    poolId: input.deployment.poolId,
    owner: input.owner ?? "unset",
    snapshot: input.snapshot,
    sizing: planned.sizing,
    minBond: input.minBond,
    scenarios: planned.plans.map((p) => ({
      name: p.name,
      description: p.description,
      roles: p.roles,
      txs: p.calls.map((c, i) => plannedTx(i, c, input.routers[c.role])),
      expectations: p.expectations.map((e) => ({ id: e.id, description: e.description })),
    })),
    totals: planTotals(planned.plans),
    notes: input.notes ?? [],
  };
}

/** The owner address a plan is built for: the signer, SIM_ADDRESS, or a placeholder for offline plans. */
export const PLACEHOLDER_OWNER: Address = "0x0000000000000000000000000000000000000001";

// ---------------------------------------------------------------------------
// Requirements (dry run and execute share these)
// ---------------------------------------------------------------------------

export interface Requirements {
  usdcSwaps: bigint;
  usdcBonds: bigint;
  ethSwaps: bigint;
  ethGas: bigint;
  routersToDeploy: Role[];
  bondsToPost: Role[];
  blockers: string[];
}

export async function requirements(ctx: RunnerContext, pre: Preflight, planned: Planned, routers: Routers): Promise<Requirements> {
  const totals = planTotals(planned.plans);
  const routersToDeploy = planned.roles.filter((r) => routers[r] === undefined);
  const bondsToPost: Role[] = [];
  let usdcBonds = 0n;
  const blockers: string[] = [];

  for (const plan of planned.plans) {
    for (const call of plan.calls) {
      if (call.kind !== "bond") continue;
      const router = routers[call.role];
      if (router === undefined) {
        bondsToPost.push(call.role);
        usdcBonds += call.amount;
        continue;
      }
      const bonded = await readBonded(ctx, router);
      if (bonded >= call.amount) {
        const exempt = await hookRead<boolean>(ctx, "isExempt", [ctx.deployment.poolId, router]);
        if (!exempt) {
          const until = await hookRead<bigint>(ctx, "flaggedUntil", [router]);
          blockers.push(
            `router ${call.role} (${router}) is bonded but not exempt (flagged until block ${until}); ` +
              `remove "${call.role}" from routers.json so a fresh router is deployed`,
          );
        }
        continue;
      }
      if (bonded > 0n) {
        blockers.push(`router ${call.role} holds ${bonded} raw USDC of bond, below minBond ${call.amount}; withdraw it first`);
        continue;
      }
      bondsToPost.push(call.role);
      usdcBonds += call.amount;
    }
  }

  const fees = await ctx.clients.publicClient.estimateFeesPerGas();
  const batchTxs = planned.plans.reduce((n, p) => n + p.calls.filter((c) => c.phase === "batch").length, 0);
  const setupTxs = bondsToPost.length + routersToDeploy.length * 2; // deploy + approve
  const ethGas = (BigInt(batchTxs) * ctx.config.swapGasLimit + BigInt(setupTxs) * 1_500_000n) * fees.maxFeePerGas * 2n;

  if (pre.usdcBalance !== undefined && pre.usdcBalance < totals.usdcIn + usdcBonds) {
    blockers.push(`owner holds ${pre.usdcBalance} raw USDC, needs ${totals.usdcIn + usdcBonds} (${totals.usdcIn} swaps + ${usdcBonds} bonds)`);
  }
  if (pre.ethBalance !== undefined && pre.ethBalance < totals.ethIn + ethGas) {
    blockers.push(`owner holds ${formatEther(pre.ethBalance)} ETH, needs about ${formatEther(totals.ethIn + ethGas)} (swaps + gas headroom)`);
  }
  return { usdcSwaps: totals.usdcIn, usdcBonds, ethSwaps: totals.ethIn, ethGas, routersToDeploy, bondsToPost, blockers };
}

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

function signer(ctx: RunnerContext) {
  const { walletClient, account } = ctx.clients;
  if (walletClient === undefined || account === undefined) throw new Error("SIM_PRIVATE_KEY is required to execute");
  return { walletClient, account };
}

function decodeLogs(ctx: RunnerContext, receipt: TransactionReceipt): DecodedEvent[] {
  const sources: Array<{ address: Address; abi: Abi }> = [
    { address: ctx.deployment.hook, abi: ctx.hookAbi },
    { address: ctx.deployment.poolManager, abi: poolManagerEventsAbi },
  ];
  const out: DecodedEvent[] = [];
  for (const log of receipt.logs) {
    const src = sources.find((s) => s.address.toLowerCase() === log.address.toLowerCase());
    if (src === undefined) continue;
    try {
      const decoded = decodeEventLog({ abi: src.abi, data: log.data, topics: log.topics });
      if (decoded.eventName === undefined) continue;
      out.push({
        name: decoded.eventName,
        address: getAddress(log.address),
        args: (decoded.args ?? {}) as Record<string, unknown>,
      });
    } catch {
      // Not an event in the ABI (or an anonymous log); leave it out.
    }
  }
  return out;
}

function stepFromReceipt(ctx: RunnerContext, index: number, receipt: TransactionReceipt): StepOutcome {
  return {
    index,
    txHash: receipt.transactionHash,
    blockNumber: receipt.blockNumber,
    status: receipt.status === "success" ? "success" : "reverted",
    gasUsed: receipt.gasUsed,
    events: decodeLogs(ctx, receipt),
  };
}

function callData(ctx: RunnerContext, call: PlannedCall): { data: Hex; value: bigint } {
  const abi = ctx.routerArtifact.abi;
  if (call.kind === "bond") {
    return { data: encodeFunctionData({ abi, functionName: "bond", args: [ctx.deployment.hook, call.amount] }), value: 0n };
  }
  const key = ctx.deployment.poolKey;
  return {
    data: encodeFunctionData({
      abi,
      functionName: "swap",
      args: [
        { currency0: key.currency0, currency1: key.currency1, fee: key.fee, tickSpacing: key.tickSpacing, hooks: key.hooks },
        { zeroForOne: call.zeroForOne, amountSpecified: call.amountSpecified, sqrtPriceLimitX96: call.sqrtPriceLimitX96 },
        call.hookData,
      ],
    }),
    value: call.value,
  };
}

async function waitReceipt(ctx: RunnerContext, hash: Hex): Promise<TransactionReceipt> {
  return ctx.clients.publicClient.waitForTransactionReceipt({ hash, timeout: 180_000, pollingInterval: 500 });
}

async function waitForBlockAfter(ctx: RunnerContext, block: bigint): Promise<void> {
  const { publicClient } = ctx.clients;
  for (;;) {
    const now = await publicClient.getBlockNumber();
    if (now > block) return;
    await new Promise((r) => setTimeout(r, 500));
  }
}

export async function deployRouter(ctx: RunnerContext, role: Role): Promise<Address> {
  const { walletClient, account } = signer(ctx);
  const hash = await walletClient.deployContract({
    abi: ctx.routerArtifact.abi,
    bytecode: ctx.routerArtifact.bytecode,
    args: [ctx.deployment.poolManager, account.address],
  });
  ctx.log(`deploying router ${role}: ${hash}`);
  const receipt = await waitReceipt(ctx, hash);
  if (receipt.status !== "success" || receipt.contractAddress === undefined || receipt.contractAddress === null) {
    throw new Error(`router ${role} deployment failed in ${hash}`);
  }
  const address = getAddress(receipt.contractAddress);
  saveRouter(ctx.routersFile, ctx.config.chainId, role, address);
  ctx.log(`router ${role} at ${address} (block ${receipt.blockNumber})`);
  return address;
}

export async function ensureAllowance(ctx: RunnerContext, router: Address, needed: bigint): Promise<void> {
  const { walletClient, account } = signer(ctx);
  const { publicClient } = ctx.clients;
  const current = await publicClient.readContract({
    address: ctx.deployment.bondToken,
    abi: erc20Abi,
    functionName: "allowance",
    args: [account.address, router],
  });
  if (current >= needed) return;
  const hash = await walletClient.writeContract({
    address: ctx.deployment.bondToken,
    abi: erc20Abi,
    functionName: "approve",
    args: [router, maxUint256],
  });
  ctx.log(`approving USDC for ${router}: ${hash}`);
  const receipt = await waitReceipt(ctx, hash);
  if (receipt.status !== "success") throw new Error(`approve for ${router} reverted in ${hash}`);
}

/** Sign every batch call with consecutive nonces, then send them back to back. */
async function sendBatch(ctx: RunnerContext, targets: Array<{ index: number; to: Address; call: PlannedCall }>): Promise<Hex[]> {
  const { account } = signer(ctx);
  const { publicClient } = ctx.clients;
  const fees = await publicClient.estimateFeesPerGas();
  const maxFeePerGas = fees.maxFeePerGas * 2n;
  const maxPriorityFeePerGas = fees.maxPriorityFeePerGas;
  let nonce = await publicClient.getTransactionCount({ address: account.address, blockTag: "pending" });

  const signed: Hex[] = [];
  for (const t of targets) {
    const { data, value } = callData(ctx, t.call);
    signed.push(
      await account.signTransaction({
        type: "eip1559",
        chainId: ctx.config.chainId,
        to: t.to,
        data,
        value,
        gas: ctx.config.swapGasLimit,
        nonce: nonce++,
        maxFeePerGas,
        maxPriorityFeePerGas,
      }),
    );
  }
  const hashes: Hex[] = [];
  for (const [i, raw] of signed.entries()) {
    const hash = await publicClient.sendRawTransaction({ serializedTransaction: raw });
    hashes.push(hash);
    ctx.log(`sent step ${targets[i]?.index}: ${hash}`);
  }
  return hashes;
}

export async function executeScenario(ctx: RunnerContext, plan: ScenarioPlan, routers: Routers, sizing: Sizing): Promise<Report> {
  const { account } = signer(ctx);
  const owner = account.address;
  const steps: StepOutcome[] = [];
  const notes: string[] = [];
  ctx.log(`\n== ${plan.name}: ${plan.description}`);

  const routerOf = (role: Role): Address => {
    const r = routers[role];
    if (r === undefined) throw new Error(`no router for role ${role}`);
    return r;
  };

  // Setup phase: one transaction at a time, confirmed before the next.
  let lastSetupBlock: bigint | undefined;
  for (const [index, call] of plan.calls.entries()) {
    if (call.phase !== "setup") continue;
    const to = routerOf(call.role);
    const bonded = await readBonded(ctx, to);
    if (bonded >= call.amount) {
      steps.push({ index, txHash: null, blockNumber: null, status: "skipped", gasUsed: null, events: [], note: `already bonded ${bonded}` });
      notes.push(`step ${index}: ${call.role} already bonded with ${bonded}`);
      continue;
    }
    if (bonded > 0n) throw new Error(`router ${call.role} holds ${bonded} of bond, below ${call.amount}`);
    const { walletClient } = signer(ctx);
    const { data, value } = callData(ctx, call);
    const hash = await walletClient.sendTransaction({ to, data, value });
    ctx.log(`sent step ${index} (${call.label}): ${hash}`);
    const receipt = await waitReceipt(ctx, hash);
    const step = stepFromReceipt(ctx, index, receipt);
    steps.push(step);
    if (step.status !== "success") throw new Error(`setup step ${index} reverted in ${hash}`);
    lastSetupBlock = receipt.blockNumber;
  }
  if (lastSetupBlock !== undefined) {
    ctx.log(`setup confirmed in block ${lastSetupBlock}; waiting for the next block`);
    await waitForBlockAfter(ctx, lastSetupBlock);
  }

  const pre = await snapshotState(ctx, plan.roles, routers, owner);
  for (const role of plan.bondedRoles) {
    if (pre.isExempt[role] !== true) {
      throw new Error(`router ${role} is not exempt before the batch (bonded ${pre.bondedBalance[role]}); it is flagged or banned`);
    }
  }

  // Batch phase: consecutive nonces, no waiting between sends.
  const targets = plan.calls
    .map((call, index) => ({ call, index }))
    .filter((t) => t.call.phase === "batch")
    .map((t) => ({ index: t.index, to: routerOf(t.call.role), call: t.call }));
  const hashes = await sendBatch(ctx, targets);
  const receipts = await Promise.all(hashes.map((h) => waitReceipt(ctx, h)));
  for (const [i, receipt] of receipts.entries()) {
    const target = targets[i];
    if (target === undefined) continue;
    steps.push(stepFromReceipt(ctx, target.index, receipt));
  }
  steps.sort((a, b) => a.index - b.index);

  const post = await snapshotState(ctx, plan.roles, routers, owner);
  const outcome: Outcome = { owner, routers, steps, pre, post };
  const results = evaluate(plan, outcome);
  const report = buildReport({
    plan,
    outcome,
    expectations: results,
    chainId: ctx.config.chainId,
    hook: ctx.deployment.hook,
    poolId: ctx.deployment.poolId,
    sizing,
    notes,
  });
  const path = writeJson(ctx.reportsDir, reportFileName(plan.name), report);
  ctx.log(summarize(results));
  ctx.log(`${report.pass ? "PASS" : report.needsRetry ? "RETRY" : "FAIL"} ${plan.name} -> ${path}`);
  return report;
}

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

export interface RunOptions {
  execute: boolean;
  scenarios?: ScenarioName[];
}

export async function run(ctx: RunnerContext, opts: RunOptions): Promise<{ planPath: string; reports: Report[] }> {
  const names = opts.scenarios ?? ctx.config.scenarios;
  const pre = await preflight(ctx);
  for (const w of pre.warnings) ctx.log(`warning: ${w}`);
  const owner = ctx.clients.owner ?? PLACEHOLDER_OWNER;
  const routers = loadRouters(ctx.routersFile, ctx.config.chainId);
  const planned = planScenarios(ctx.config, pre.snapshot, pre.bondParams.minBond, owner, names);
  const req = await requirements(ctx, pre, planned, routers);

  const notes = [
    `pool liquidity ${pre.snapshot.liquidity}, sqrtPriceX96 ${pre.snapshot.sqrtPriceX96}, lp fee ${pre.snapshot.lpFeePips} pips at block ${pre.blockNumber}`,
    `routers to deploy: ${req.routersToDeploy.join(", ") || "none"}`,
    `bonds to post: ${req.bondsToPost.join(", ") || "none"}`,
    `USDC needed: ${req.usdcSwaps} for swaps + ${req.usdcBonds} for bonds; owner holds ${pre.usdcBalance ?? "unknown"}`,
    `ETH needed: ${formatEther(req.ethSwaps)} for swaps + about ${formatEther(req.ethGas)} gas headroom; owner holds ${pre.ethBalance === undefined ? "unknown" : formatEther(pre.ethBalance)}`,
    ...pre.warnings.map((w) => `warning: ${w}`),
    ...req.blockers.map((b) => `blocker: ${b}`),
  ];
  const planFile = buildPlanFile({ mode: "online", deployment: ctx.deployment, owner: ctx.clients.owner, snapshot: pre.snapshot, minBond: pre.bondParams.minBond, planned, routers, notes });
  const planPath = writeJson(ctx.reportsDir, `${timestampSlug()}-plan.json`, planFile);
  ctx.log(`plan written to ${planPath}`);
  for (const n of notes) ctx.log(n);

  if (!opts.execute) {
    ctx.log(`dry run: no transaction sent. ${planFile.totals.txCount} scenario transactions planned; rerun with --execute to send them.`);
    return { planPath, reports: [] };
  }
  if (req.blockers.length > 0) throw new Error(`cannot execute:\n  ${req.blockers.join("\n  ")}`);
  signer(ctx);

  for (const role of req.routersToDeploy) routers[role] = await deployRouter(ctx, role);
  const usdcPerRouter = req.usdcSwaps + req.usdcBonds;
  for (const role of planned.roles) await ensureAllowance(ctx, routers[role] as Address, usdcPerRouter);

  const reports: Report[] = [];
  for (const plan of planned.plans) {
    try {
      reports.push(await executeScenario(ctx, plan, routers, planned.sizing));
    } catch (err) {
      ctx.log(`${plan.name} aborted: ${(err as Error).message}`);
    }
  }
  return { planPath, reports };
}

/** Withdraw a router's bond to the owner. Dry run reports the bond and its maturity. */
export async function withdrawBond(ctx: RunnerContext, role: Role, execute: boolean): Promise<void> {
  const routers = loadRouters(ctx.routersFile, ctx.config.chainId);
  const router = routers[role];
  if (router === undefined) throw new Error(`no router for role ${role} in routers.json`);
  const bond = await hookRead<readonly [bigint, number, number, number, number]>(ctx, "bonds", [router]);
  const params = await hookRead<BondParams>(ctx, "bondParams");
  const [amount, depositBlock, bannedUntil, strikeCount, lastStrikeBlock] = bond;
  const lock = strikeCount > 0 ? params.firstOffenseLockExtensionBlocks : 0n;
  const maturity = BigInt(depositBlock) + params.minBondDurationBlocks + lock;
  const now = await ctx.clients.publicClient.getBlockNumber();
  ctx.log(`router ${role} ${router}: bond ${amount}, deposit block ${depositBlock}, strikes ${strikeCount} (last ${lastStrikeBlock}), banned until ${bannedUntil}, matures at block ${maturity} (now ${now})`);
  if (!execute) {
    ctx.log("dry run: no transaction sent");
    return;
  }
  if (amount === 0n) throw new Error("nothing bonded");
  if (now < maturity) throw new Error(`bond matures at block ${maturity}`);
  const { walletClient } = signer(ctx);
  const data = encodeFunctionData({ abi: ctx.routerArtifact.abi, functionName: "withdrawBond", args: [ctx.deployment.hook] });
  const hash = await walletClient.sendTransaction({ to: router, data });
  ctx.log(`withdrawBond: ${hash}`);
  const receipt = await waitReceipt(ctx, hash);
  ctx.log(receipt.status === "success" ? `withdrawn in block ${receipt.blockNumber}` : "reverted");
}

/** Claim the owner's refund credit straight from the hook (the victim key names the EOA). */
export async function claimRefund(ctx: RunnerContext, execute: boolean): Promise<void> {
  const owner = ctx.clients.owner;
  if (owner === undefined) throw new Error("SIM_PRIVATE_KEY or SIM_ADDRESS is required");
  const claimable = await hookRead<bigint>(ctx, "claimableRefund", [owner]);
  ctx.log(`claimable refund for ${owner}: ${claimable} raw USDC`);
  if (!execute) {
    ctx.log("dry run: no transaction sent");
    return;
  }
  if (claimable === 0n) throw new Error("nothing to claim");
  const { walletClient } = signer(ctx);
  const hash = await walletClient.writeContract({ address: ctx.deployment.hook, abi: ctx.hookAbi, functionName: "claimRefund", args: [] });
  ctx.log(`claimRefund: ${hash}`);
  const receipt = await waitReceipt(ctx, hash);
  ctx.log(receipt.status === "success" ? `claimed in block ${receipt.blockNumber}` : "reverted");
}
