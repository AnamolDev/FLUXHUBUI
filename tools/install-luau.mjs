/*
 * Downloads the official Luau CLI binaries into .tools/ so the test suite is reproducible.
 *
 *   node tools/install-luau.mjs [--version 0.748] [--dir .tools] [--force]
 *
 * .tools/ is gitignored, which means a fresh clone has nothing to run specs with. This fetches the
 * release archive for the current platform and extracts the two executables the suite needs:
 *
 *   luau.exe      runs the concatenated spec files
 *   luau-ast.exe  powers the parse check and the local-count gate in check.mjs
 *
 * Nothing here is compiled locally; the binaries come from github.com/luau-lang/luau releases.
 */

import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const argv = process.argv.slice(2);

function flag(name, fallback) {
  const index = argv.indexOf(`--${name}`);
  return index === -1 ? fallback : argv[index + 1];
}

const force = argv.includes("--force");
const wantedVersion = flag("version", null);
const outDir = resolve(root, flag("dir", ".tools"));

const ASSET = { win32: "luau-windows.zip", linux: "luau-ubuntu.zip", darwin: "luau-macos.zip" };
const EXECUTABLES = process.platform === "win32" ? ["luau.exe", "luau-ast.exe"] : ["luau", "luau-ast"];

function fail(message) {
  console.error(`install-luau: ${message}`);
  process.exit(1);
}

const asset = ASSET[process.platform];
if (asset === undefined) {
  fail(`no official Luau release archive for platform ${process.platform}; place the binaries in ${outDir}/ yourself`);
}

async function latestTag() {
  const response = await fetch("https://api.github.com/repos/luau-lang/luau/releases/latest", {
    headers: { "user-agent": "fluxhub-dev" },
  });
  if (!response.ok) {
    fail(`GitHub answered ${response.status} for the latest release`);
  }
  const body = await response.json();
  if (typeof body.tag_name !== "string") {
    fail("the latest release response had no tag_name");
  }
  return body.tag_name;
}

const version = wantedVersion ?? (await latestTag());
const download = `https://github.com/luau-lang/luau/releases/download/${version}/${asset}`;
const staging = join(tmpdir(), `luau-${version}-${Date.now()}`);
const archive = join(staging, asset);

mkdirSync(staging, { recursive: true });
mkdirSync(outDir, { recursive: true });

console.log(`luau ${version} <- ${download}`);
const fetched = await fetch(download, { redirect: "follow" });
if (!fetched.ok) {
  rmSync(staging, { recursive: true, force: true });
  fail(`download answered ${fetched.status}`);
}
writeFileSync(archive, Buffer.from(await fetched.arrayBuffer()));

function extract() {
  if (process.platform === "win32") {
    execFileSync("powershell.exe", ["-NoProfile", "-Command", `Expand-Archive -LiteralPath '${archive}' -DestinationPath '${staging}'`], { stdio: "inherit" });
    return;
  }
  const unzip = spawnSync("unzip", ["-o", archive, "-d", staging], { encoding: "utf8" });
  if (unzip.status !== 0) {
    fail("unzip failed; install unzip or pass --dir to reuse an existing checkout");
  }
}

extract();

/** The archives keep the executables at their root on every platform, but a nested directory would
 *  still be found here rather than producing a confusing "not installed" error later. */
function locate(name, from) {
  const direct = join(from, name);
  if (existsSync(direct)) {
    return direct;
  }
  const probe = spawnSync(process.platform === "win32" ? "cmd" : "find", process.platform === "win32" ? ["/c", "dir", "/s", "/b", join(from, name)] : [from, "-name", name], { encoding: "utf8" });
  const line = (probe.stdout ?? "").split(/\r?\n/).find((entry) => entry.trim().length > 0);
  return line === undefined ? null : line.trim();
}

let installed = 0;
for (const name of EXECUTABLES) {
  const found = locate(name, staging);
  if (found === null) {
    fail(`${name} was not inside ${asset}`);
  }
  const target = join(outDir, name);
  if (existsSync(target) && !force) {
    console.log(`  kept existing ${target} (pass --force to overwrite)`);
    continue;
  }
  renameSync(found, target);
  if (process.platform !== "win32") {
    execFileSync("chmod", ["+x", target]);
  }
  installed += 1;
  console.log(`  installed ${target}`);
}

rmSync(staging, { recursive: true, force: true });

/** luau.exe is a file interpreter only — this build has no -e/-c switch — so the smoke test is a file. */
const probeFile = join(outDir, ".smoke.lua");
writeFileSync(probeFile, 'print("luau ok")\n', "utf8");
const check = spawnSync(join(outDir, EXECUTABLES[0]), [probeFile], { encoding: "utf8" });
rmSync(probeFile, { force: true });
if (check.status !== 0 || !check.stdout.includes("luau ok")) {
  fail(`${EXECUTABLES[0]} refused to run: ${check.stderr || check.stdout}`);
}
console.log(`${check.stdout.trim()} — ${installed} binary(ies) installed, ${EXECUTABLES.length - installed} already present`);
