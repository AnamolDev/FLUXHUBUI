/*
 * Runs the specs under tests/spec/ headlessly.
 *
 *   node tools/run-tests.mjs [--filter name] [--verbose] [--keep]
 *
 * Everything is concatenated into ONE luau chunk per spec file, and each spec file gets its own
 * process: the library's systems are module singletons, so a run that resolved an icon through
 * the file api would otherwise hand its cache to the next spec, which models a client that has
 * no file api at all.
 *
 *   tests/harness/stub.lua     the engine stand-in
 *   tests/harness/tap.lua      the assertion helpers
 *   dist/FluxHub.lua           wrapped as `local function fluxBoot() … end`
 *   tests/spec/NN-name.lua     the spec
 *
 * Two transformations are load-bearing, not cosmetics:
 *
 *  1. the bundle's final entry expression becomes `return fluxRequire`, so a spec can require
 *     any module by path and can require "Flux/init" itself and observe its failure instead of
 *     losing the whole run;
 *  2. `os.clock()` / `os.time()` / `os.date()` are rewritten to the harness clock, because
 *     this VM's `os` table is readonly and cannot be monkey-patched. Time is therefore
 *     advanced only by stepClock(), which is what makes animation and frame-budget
 *     assertions deterministic.
 *
 * The verdict comes from stdout, never the exit code: luau.exe returns 0 after printing a
 * runtime error.
 */

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const tmpDir = join(root, ".tmp");
const luau = join(root, ".tools", "luau.exe");
const bundleFile = join(root, "dist", "FluxHub.lua");
const specDir = join(root, "tests", "spec");

const argv = process.argv.slice(2);
const filter = argv.includes("--filter") ? argv[argv.indexOf("--filter") + 1] : null;
const verbose = argv.includes("--verbose");
const keep = argv.includes("--keep");

function die(message) {
  console.error(message);
  process.exit(2);
}

/* ---------------------------------------------------------------- build ---- */

const build = spawnSync(process.execPath, [join(root, "tools", "build.mjs")], {
  cwd: root,
  encoding: "utf8",
});
if (build.status !== 0) {
  die(`build failed:\n${build.stderr || build.stdout}`);
}

/* ----------------------------------------------------------------- specs ---- */

const specFiles = existsSync(specDir)
  ? readdirSync(specDir)
      .filter((name) => name.endsWith(".lua"))
      .filter((name) => filter === null || name.includes(filter))
      .sort()
  : [];

if (specFiles.length === 0) {
  die(filter === null ? "no specs found under tests/spec/" : `no spec matches ${filter}`);
}

/** See the header: the bundle must hand specs its require function, not its product table.
 *  The entry expression is matched as a whole line, searched from the end, because src/init.lua
 *  quotes that exact line in a comment and a plain string replace would patch the prose. */
function toBootable(bundleSource) {
  const entry = 'return fluxRequire("Flux/init")';
  const lines = bundleSource.split(/\r?\n/);

  for (let index = lines.length - 1; index >= 0; index -= 1) {
    if (lines[index].trim() === entry) {
      lines[index] = "return fluxRequire";
      return lines.join("\n");
    }
  }

  die("dist/FluxHub.lua does not end with the expected entry expression; update run-tests.mjs");
}

function determiniseTime(source) {
  const patched = source
    .replace(/\bos\.clock\s*\(/g, "harnessClock(")
    .replace(/\bos\.time\s*\(/g, "harnessTime(")
    .replace(/\bos\.date\s*\(/g, "harnessDate(");

  const leftover = patched.match(/\bos\.\w+/g);
  if (leftover !== null) {
    console.warn(`  note: un-patched os access remains (this VM's os table is readonly): ${[...new Set(leftover)].join(", ")}`);
  }
  return patched;
}

/* ----------------------------------------------------------------- run it ---- */

if (!existsSync(tmpDir)) {
  mkdirSync(tmpDir, { recursive: true });
}

const header = [
  readFileSync(join(root, "tests", "harness", "stub.lua"), "utf8"),
  readFileSync(join(root, "tests", "harness", "tap.lua"), "utf8"),
];

const bundle = determiniseTime(toBootable(readFileSync(bundleFile, "utf8")));

let totalChecks = 0;
let totalFailures = 0;
const crashedFiles = [];

// One process per spec file. ThemeManager, IconManager and AnimationManager are module
// singletons, so a file that resolved an icon through the file api would otherwise hand its
// cache to the file that models a client without one — a scenario no real client is ever in.
for (const name of specFiles) {
  const body = readFileSync(join(specDir, name), "utf8");
  const runFile = join(tmpDir, `run-${name.replace(/\.lua$/, "")}.lua`);

  writeFileSync(
    runFile,
    [...header, "local function fluxBoot()", bundle, "end", "local fluxRequire = fluxBoot()", body, "finishTests()"].join("\n"),
    "utf8",
  );

  const result = spawnSync(luau, [runFile], { cwd: root, encoding: "latin1" });
  const stdout = result.stdout ?? "";
  const stderr = result.stderr ?? "";
  const lines = stdout.split(/\r?\n/).filter((line) => line.trim().length > 0);

  const verdict = lines.find((line) => line.startsWith("RESULT "));
  const checks = verdict ? Number(/checks=(\d+)/.exec(verdict)?.[1] ?? "0") : 0;
  const failures = verdict ? Number(/failures=(\d+)/.exec(verdict)?.[1] ?? "1") : 1;

  totalChecks += checks;
  totalFailures += failures;

  const status = verdict === undefined ? "CRASH" : failures > 0 ? "FAIL" : "pass";
  if (verdict === undefined) {
    crashedFiles.push(name);
  }

  console.log(`${status.toUpperCase().padEnd(5)} ${name}${verdict ? ` (${checks} checks, ${failures} failed)` : " (no RESULT banner)"}`);

  if (verbose || status !== "pass") {
    const shown = verbose
      ? lines
      : lines.filter((line) => line.startsWith("FAIL") || line.startsWith("warn") || line.startsWith("SPEC"));
    for (const line of shown) {
      console.log(`        ${line}`);
    }
  }

  if (stderr.trim().length > 0) {
    console.error(`        luau.exe stderr: ${stderr.trim().split(/\r?\n/).join("\n        ")}`);
  }

  if (!keep) {
    rmSync(runFile, { force: true });
  }
}

console.log(`\n${specFiles.length} files, ${totalChecks} checks, ${totalFailures} failures`);

if (keep) {
  console.log(`kept ${tmpDir}/run-*.lua`);
}

process.exit(totalFailures > 0 || crashedFiles.length > 0 ? 1 : 0);
