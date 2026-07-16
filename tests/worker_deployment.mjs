import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const root = resolve(process.argv[2] || ".");
const deployments = [
  {
    config: "examples/site/worker/wrangler.toml",
    main: "worker/worker.js",
    command: "cd ../../.. && zig build worker",
    wasm: ["worker/merjs.wasm", "worker/grep.wasm"],
    budget: "merlionjs-site-production",
  },
  {
    config: "examples/singapore-data-dashboard/worker/wrangler.toml",
    main: "worker.js",
    command: "cd ../../.. && zig build sgdata-worker",
    wasm: ["merjs.wasm"],
    budget: "merlionjs-sgdata-production",
  },
];

function resolveImports(file, seen = new Set()) {
  const absolute = resolve(file);
  if (seen.has(absolute)) return seen;
  seen.add(absolute);
  const source = readFileSync(absolute, "utf8");
  for (const match of source.matchAll(/\bfrom\s+["'](\.[^"']+)["']/g)) {
    const imported = resolve(dirname(absolute), match[1]);
    assert.ok(existsSync(imported), `${absolute}: unresolved import ${match[1]}`);
    if (imported.endsWith(".js")) resolveImports(imported, seen);
  }
  return seen;
}

for (const deployment of deployments) {
  const configPath = join(root, deployment.config);
  const configDir = dirname(configPath);
  const config = readFileSync(configPath, "utf8");
  assert.match(config, new RegExp(`^main = "${deployment.main.replaceAll(".", "\\.")}"$`, "m"));
  assert.ok(config.includes(`command = "${deployment.command}"`), `${deployment.config}: wrong build command`);
  assert.ok(config.includes(`AI_BUDGET_ACCOUNT = "${deployment.budget}"`), `${deployment.config}: AI budget account changed`);
  assert.ok(config.includes('binding = "AI_BUDGET_GUARD"'), `${deployment.config}: AI budget binding missing`);
  resolveImports(join(configDir, deployment.main));
  for (const wasm of deployment.wasm) {
    assert.ok(existsSync(join(configDir, wasm)), `${deployment.config}: missing generated ${wasm}`);
  }
}

assert.ok(!existsSync(join(root, "examples/site/worker/worker/wrangler.toml")), "site has a duplicate nested Wrangler config");
