#!/usr/bin/env node
// Populates generated/ from the Foundry build: the hook ABI and deployment records via
// the repo-level exporter, plus the SimSwapRouter ABI and bytecode this service deploys.
//
// Run `forge build` from the repo root first (test/SimSwapRouter.t.sol pulls the router
// into the default build).

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const here = resolve(new URL(".", import.meta.url).pathname, "..");
const root = resolve(here, "..", "..");
const generated = join(here, "generated");

const exporter = join(root, "scripts", "export-artifacts.mjs");
const res = spawnSync(process.execPath, [exporter], { cwd: root, stdio: "inherit" });
if (res.status !== 0) process.exit(res.status ?? 1);

const routerSrc = join(root, "app", "script", "SimSwapRouter.sol");
if (!existsSync(routerSrc)) {
  console.error(`missing ${routerSrc}`);
  process.exit(1);
}
const routerArtifact = join(root, "out", "SimSwapRouter.sol", "SimSwapRouter.json");
if (!existsSync(routerArtifact)) {
  console.error(`missing ${routerArtifact}; run \`forge build\` from ${root}`);
  process.exit(1);
}
const full = JSON.parse(readFileSync(routerArtifact, "utf8"));
if (!full.abi || !full.bytecode?.object) {
  console.error(`${routerArtifact} has no abi or bytecode.object`);
  process.exit(1);
}
mkdirSync(generated, { recursive: true });
const out = join(generated, "SimSwapRouter.json");
writeFileSync(out, JSON.stringify({ abi: full.abi, bytecode: full.bytecode.object }, null, 2) + "\n");
console.log(`wrote ${out}`);
