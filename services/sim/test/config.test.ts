import { describe, expect, it } from "vitest";

import { DEFAULTS, loadConfig, parseScenarioList } from "../src/config.js";
import { SCENARIO_NAMES } from "../src/scenarios.js";

describe("parseScenarioList", () => {
  it("defaults to every scenario", () => {
    expect(parseScenarioList(undefined)).toEqual([...SCENARIO_NAMES]);
    expect(parseScenarioList("  ")).toEqual([...SCENARIO_NAMES]);
  });
  it("keeps order and drops duplicates", () => {
    expect(parseScenarioList("unbonded-mule, unbonded-sandwich,unbonded-mule")).toEqual(["unbonded-mule", "unbonded-sandwich"]);
  });
  it("rejects unknown names", () => {
    expect(() => parseScenarioList("bonded-sandwich,nope")).toThrow(/unknown scenario "nope"/);
  });
});

describe("loadConfig", () => {
  it("applies defaults from an empty environment", () => {
    const c = loadConfig({});
    expect(c.rpcUrl).toBe(DEFAULTS.rpcUrl);
    expect(c.chainId).toBe(1301);
    expect(c.usdcBudget).toBe(20_000_000n);
    expect(c.ethBudgetWei).toBe(1_000_000_000_000_000n);
    expect(c.swapFractionBps).toBe(500);
    expect(c.privateKey).toBeUndefined();
    expect(c.address).toBeUndefined();
    expect(c.scenarios).toEqual([...SCENARIO_NAMES]);
  });
  it("parses overrides", () => {
    const key = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const c = loadConfig({ RPC_URL: "http://localhost:8545", CHAIN_ID: "31337", SIM_PRIVATE_KEY: key, USDC_BUDGET: "5", ETH_BUDGET_WEI: "7", SWAP_FRACTION_BPS: "100", SCENARIOS: "unbonded-mule", SWAP_GAS_LIMIT: "900000" });
    expect(c).toMatchObject({ rpcUrl: "http://localhost:8545", chainId: 31337, privateKey: `0x${key}`, usdcBudget: 5n, ethBudgetWei: 7n, swapFractionBps: 100, scenarios: ["unbonded-mule"], swapGasLimit: 900_000n });
  });
  it("rejects bad values", () => {
    expect(() => loadConfig({ SIM_PRIVATE_KEY: "0x1234" })).toThrow(/SIM_PRIVATE_KEY/);
    expect(() => loadConfig({ SIM_ADDRESS: "nope" })).toThrow(/SIM_ADDRESS/);
    expect(() => loadConfig({ USDC_BUDGET: "-1" })).toThrow(/USDC_BUDGET/);
    expect(() => loadConfig({ SWAP_FRACTION_BPS: "0" })).toThrow(/SWAP_FRACTION_BPS/);
    expect(() => loadConfig({ SWAP_FRACTION_BPS: "6000" })).toThrow(/SWAP_FRACTION_BPS/);
  });
});
