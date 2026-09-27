// Verifies that every function signature hard-coded in src/lib/onchain.ts
// exists in the generated VadiumHook ABI with the same inputs and outputs.
// Usage: node scripts/check-abi.mjs   (runs after `pnpm abis`)
import { readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const abiPath = path.join(root, "src", "generated", "VadiumHook.abi.json");
if (!existsSync(abiPath)) {
  console.error(`missing ${abiPath}; run \`pnpm abis\` first`);
  process.exit(1);
}
const abi = JSON.parse(readFileSync(abiPath, "utf8"));
const source = readFileSync(path.join(root, "src", "lib", "onchain.ts"), "utf8");
const signatures = [...source.matchAll(/"function ([^"]+)"/g)].map((m) => m[1]);

// Renders one ABI parameter the way parseAbi writes it: "(uint48 a, uint160 b)" for tuples.
function param(p) {
  if (p.type.startsWith("tuple")) {
    const inner = p.components.map(param).join(", ");
    return `(${inner})${p.type.slice("tuple".length)}${p.name ? ` ${p.name}` : ""}`;
  }
  return `${p.type}${p.name ? ` ${p.name}` : ""}`;
}
function canon(text) {
  return text.replace(/\s+/g, " ").replace(/\( /g, "(").replace(/ \)/g, ")").trim();
}
function stripNames(text) {
  // Compares types only, so a renamed parameter is not a failure.
  return canon(text).replace(/(\b(?:u?int\d*|address|bool|bytes\d*|string)(?:\[\d*\])?|\)) [A-Za-z_]\w*/g, "$1");
}

let failed = 0;
for (const sig of signatures) {
  const name = sig.slice(0, sig.indexOf("("));
  const fn = abi.find((e) => e.type === "function" && e.name === name);
  if (!fn) {
    console.error(`MISSING  ${name}: not in ABI`);
    failed++;
    continue;
  }
  const inputs = fn.inputs.map(param).join(", ");
  const outputs = fn.outputs.map(param).join(", ");
  const expected = `${name}(${inputs}) ${fn.stateMutability} returns (${outputs})`;
  if (stripNames(expected) !== stripNames(sig)) {
    console.error(`DRIFT    ${name}\n  code: ${canon(sig)}\n  abi:  ${canon(expected)}`);
    failed++;
  } else {
    console.log(`ok       ${name}`);
  }
}
if (failed) {
  console.error(`${failed} signature(s) differ from the generated ABI`);
  process.exit(1);
}
console.log(`${signatures.length} signatures match the generated ABI`);
