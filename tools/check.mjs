/*
 * Quality gate. Three checks, because a Roblox library can pass the first two and still
 * be a script that never runs:
 *
 *   1. parse     — luau-ast exit code over every src file and the bundle.
 *   2. dialect   — constructs the offline VM (and some executors) refuse: generalized
 *                  iteration, the `if … then … else` expression form, `!=`.
 *   3. locals    — peak live locals per prototype, counted off the AST JSON. Roblox aborts
 *                  a chunk at 200 live locals with "Out of local registers", and the
 *                  offline compiler only enforces it at chunk level, so a parse gate alone
 *                  green-lights a file that dies on load in game.
 *
 * Usage: node tools/check.mjs [--dist]   (needs .tools/luau-ast or luau-ast on PATH)
 */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");

const candidates = [
  join(root, ".tools", "luau-ast.exe"),
  join(root, ".tools", "luau-ast"),
  "luau-ast",
];
const astBin = candidates.find((c) => (c.includes("\\") || c.includes("/")) ? existsSync(c) : true);
if (!astBin) {
  console.error("luau-ast not found. Put it in .tools/ or run scripts/get-luau.mjs");
  process.exit(2);
}

function walk(dir) {
  const found = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) found.push(...walk(full));
    else if (entry.endsWith(".lua")) found.push(full);
  }
  return found.sort();
}

let failures = 0;
const fail = (label, detail) => {
  failures += 1;
  console.log(`FAIL ${label}: ${detail}`);
};

/* ---------------------------------------------------------------- 1. parse */

const targets = walk(join(root, "src"));
if (process.argv.includes("--dist") && existsSync(join(root, "dist", "FluxHub.lua"))) {
  targets.push(join(root, "dist", "FluxHub.lua"));
}

const parsed = new Map();
for (const file of targets) {
  try {
    const json = execFileSync(astBin, [file], {
      maxBuffer: 512 * 1024 * 1024,
      encoding: "latin1",
      stdio: ["ignore", "pipe", "pipe"],
    });
    parsed.set(file, json);
  } catch (error) {
    const stderr = (error.stderr ? error.stderr.toString("latin1") : "").trim();
    fail("parse", `${file}\n       ${stderr.split("\n").slice(0, 4).join("\n       ")}`);
  }
}
console.log(`parse: ${parsed.size}/${targets.length} files ok`);

/* -------------------------------------------------------------- 2. dialect */

const dialectRules = [
  {
    name: "generalized-iteration",
    pattern: /^\s*for\s+[\w,\s]+\s+in\s+(?!pairs\(|ipairs\(|next\(|\w+:gmatch\(|\w+:match\(|string\.)([^\s]+)/,
    hint: "use pairs()/ipairs() explicitly",
  },
  {
    name: "if-expression",
    pattern: /=\s*if\s+.{1,120}\s+then\s+.{1,120}\s+else/,
    hint: "use `cond and a or b`, or an if statement",
  },
  { name: "bang-equals", pattern: /(^|[^!=])!=(?!=)/, hint: "use ~=" },
];

for (const file of targets) {
  const lines = readFileSync(file, "latin1").split("\n");
  lines.forEach((line, index) => {
    const code = line.replace(/--\[\[[\s\S]*?\]\]/g, "").replace(/--(?!\[=).*$/, "");
    for (const rule of dialectRules) {
      if (rule.pattern.test(code)) {
        fail("dialect", `${file}:${index + 1} ${rule.name} — ${rule.hint}`);
      }
    }
  });
}

/* --------------------------------------------------------------- 3. locals */

import { peakLocals, LOCAL_REGISTER_LIMIT } from "./locals.mjs";

const LIMIT = LOCAL_REGISTER_LIMIT;
let measured = 0;
let worst = 0;
let worstFile = "";

for (const [file, json] of parsed) {
  let ast;
  try {
    ast = JSON.parse(json);
  } catch {
    continue;
  }
  measured += 1;
  const peak = peakLocals(ast);

  if (peak > worst) {
    worst = peak;
    worstFile = file;
  }
  if (peak > LIMIT * 0.8) {
    fail("locals", `${file}: ${peak} live locals at peak (limit ${LIMIT})`);
  }
}

console.log(`locals: ${measured} trees, worst ${worst}/${LIMIT} (${worstFile.split(/[\\/]/).pop()})`);


if (failures > 0) {
  console.log(`\n${failures} gate failures`);
  process.exit(1);
}
console.log("\ngate: clean");
