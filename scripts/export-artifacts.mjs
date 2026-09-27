#!/usr/bin/env node
// Copies the hook ABI and the deployment records into each service's generated/
// directory, so services build without a Foundry toolchain.
//
// Usage: node scripts/export-artifacts.mjs [--out out]
// Run after `forge build` (default profile) from the repo root.

import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const outDir = process.argv.includes("--out")
  ? process.argv[process.argv.indexOf("--out") + 1]
  : "out";

const artifacts = {
  VadiumHook: join(root, outDir, "VadiumHook.sol", "VadiumHook.json"),
  VadiumReactive: join(root, outDir, "VadiumReactive.sol", "VadiumReactive.json"),
};

const abis = {};
for (const [name, path] of Object.entries(artifacts)) {
  if (!existsSync(path)) {
    console.error(`missing ${path}; run \`forge build\` first`);
    process.exit(1);
  }
  abis[name] = JSON.parse(readFileSync(path, "utf8")).abi;
}

const deployments = {};
const depDir = join(root, "deployments");
for (const f of readdirSync(depDir)) {
  if (!f.endsWith(".json")) continue;
  deployments[f.replace(".json", "")] = JSON.parse(readFileSync(join(depDir, f), "utf8"));
}

const targets = [];
const servicesDir = join(root, "services");
if (existsSync(servicesDir)) {
  for (const s of readdirSync(servicesDir)) targets.push(join(servicesDir, s, "generated"));
}
if (existsSync(join(root, "frontend"))) targets.push(join(root, "frontend", "src", "generated"));

for (const dir of targets) {
  mkdirSync(dir, { recursive: true });
  for (const [name, abi] of Object.entries(abis)) {
    writeFileSync(join(dir, `${name}.abi.json`), JSON.stringify(abi, null, 2) + "\n");
  }
  writeFileSync(join(dir, "deployments.json"), JSON.stringify(deployments, null, 2) + "\n");
  console.log(`wrote ${dir}`);
}
