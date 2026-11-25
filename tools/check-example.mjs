/*
 * Runs example/Showcase.lua headlessly.
 *
 *   node tools/check-example.mjs [--keep]
 *
 * The published demo is documentation, and documentation that throws on load is worse than none.
 * This assembles the same chunk tests/run-tests.mjs uses — engine stub, assertion helpers, the
 * bundle as a bootable function — then substitutes the demo's `loadstring(game:HttpGet(...))` line
 * for the local bundle and asserts the hub the file describes actually builds.
 *
 * The verification block is appended rather than placed in tests/spec/ because it checks the demo,
 * not the library: a spec would drift away from the example it is supposed to be watching.
 */

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const tmpDir = join(root, ".tmp");
const luau = join(root, ".tools", "luau.exe");
const exampleFile = join(root, "example", "Showcase.lua");
const keep = process.argv.includes("--keep");

const build = spawnSync(process.execPath, [join(root, "tools", "build.mjs")], { cwd: root, encoding: "utf8" });
if (build.status !== 0) {
  console.error(`build failed:\n${build.stderr || build.stdout}`);
  process.exit(2);
}

/**
 * The demo loads its library from the published raw URL, exactly as an executor would. Here that
 * line becomes the local bundle, and nothing else in the file changes — so the syntax, the option
 * tables and the call order under test are the ones a reader of the demo would run.
 */
function localizeLoader(source) {
  const pattern = /^local\s+Flux\s*=\s*loadstring\(.*\)\(\)\s*$/m;
  if (!pattern.test(source)) {
    console.error("example/Showcase.lua no longer opens with the documented loadstring line");
    process.exit(2);
  }
  return source.replace(pattern, 'local Flux = fluxRequire("Flux/init")');
}

const verify = `
--[[ appended by tools/check-example.mjs ]]

local Lifecycle = fluxRequire("Flux/Core/Lifecycle")
local SearchManager = fluxRequire("Flux/Systems/SearchManager")
local Notifications = fluxRequire("Flux/Systems/NotificationManager")
local InputManager = fluxRequire("Flux/Systems/InputManager")

runSpec("the showcase builds and tears down", function()

checkEq(type(Flux), "table", "the bundle returned a hub")
checkNe(Flux.Version, nil, "and it is versioned: " .. tostring(Flux.Version))
checkEq(#Flux.Windows, 1, "one window")
checkEq(#Window.TabOrder, 4, "four tabs declared", tostring(#Window.TabOrder))

-- The whole point of the lazy shell: declaring a tab costs a pill, not a page.
checkEq(Window.Active.Built, true, "the open tab built its page")
checkEq(aim.Built, true, "Aim is the open one")
checkEq(visuals.Page, nil, "Visuals is a pill and nothing else")
checkEq(visuals:GroupCount(), 0, "its deferred blocks have not run")

check(SearchManager.size() >= 12, "controls registered for search", tostring(SearchManager.size()))
check(#InputManager.list() >= 1, "the hub's hotkeys are bound", tostring(#InputManager.list()))
check(Notifications.count() >= 1, "the indexing toast is showing", tostring(Notifications.count()))

-- Opening the deferred tab builds what its block declares, through the renderer.
checkEq(Window:OpenTab("Visuals"), true, "the tab opens")
pumpFrames(40)
checkEq(visuals.Built, true, "the page exists now")
checkEq(visuals:GroupCount(), 2, "the deferred block made its two cards")
checkEq(visuals:Rows(), 8, "and eight rows", tostring(visuals:Rows()))
local function deep(parent, name)
	for _, child in ipairs(parent:GetDescendants()) do
		if tostring(child.Name) == name then
			return child
		end
	end
	return nil
end

checkNe(deep(visuals.Page, "Group_Player ESP"), nil, "the first card is mounted in the page")
checkNe(deep(visuals.Page, "Toggle_Skeleton"), nil, "and its rows are there")

-- Search reaches a control the user has never seen rendered.
local hits = Window:Search("skeleton")
check(hits >= 1, "the search index knows the deferred rows", tostring(hits))
Window:Search("")

-- The progress toast the demo spawns tracks to its end once the clock passes it.
pumpFrames(200)
check(Notifications.count() >= 1, "the toast survived its updates", tostring(Notifications.count()))

checkEq(Flux:Save(), true, "the demo's save path works on this client")
checkEq(Flux:Load(), true, "and its load path")

checkEq(Flux:Unload(), true, "and it tears down")
checkEq(Notifications.count(), 0, "no toast outlived the hub")
checkEq(Lifecycle.count(), 0, "no window outlived it")
checkEq(SearchManager.size(), 0, "no index entry outlived it")
end)
`;

if (!existsSync(tmpDir)) {
  mkdirSync(tmpDir, { recursive: true });
}

const chunk = [
  readFileSync(join(root, "tests", "harness", "stub.lua"), "utf8"),
  readFileSync(join(root, "tests", "harness", "tap.lua"), "utf8"),
  "local function fluxBoot()",
  readFileSync(join(root, "dist", "FluxHub.lua"), "utf8").replace('return fluxRequire("Flux/init")', "return fluxRequire"),
  "end",
  "local fluxRequire = fluxBoot()",
  localizeLoader(readFileSync(exampleFile, "utf8")),
  verify,
  "finishTests()",
].join("\n");

const runFile = join(tmpDir, "run-example.lua");
writeFileSync(runFile, chunk, "utf8");

const result = spawnSync(luau, [runFile], { cwd: root, encoding: "latin1" });
const stdout = result.stdout ?? "";
const stderr = result.stderr ?? "";
const lines = stdout.split(/\r?\n/).filter((line) => line.trim().length > 0);
const verdict = lines.find((line) => line.startsWith("RESULT "));

for (const line of lines) {
  if (verboseLine(line)) {
    console.log(`  ${line}`);
  }
}

function verboseLine(line) {
  return (
    line.startsWith("FAIL") ||
    line.startsWith("warn") ||
    line.startsWith("SPEC") ||
    line.startsWith("[Flux]") ||
    verdict === undefined
  );
}

if (!keep) {
  rmSync(runFile, { force: true });
}

if (stderr.trim().length > 0) {
  console.error(`luau.exe stderr: ${stderr.trim()}`);
  process.exit(1);
}

if (verdict === undefined || /failures=[1-9]/.test(verdict)) {
  console.error(`\nexample failed: ${verdict ?? "no RESULT banner (the demo crashed on load)"}`);
  process.exit(1);
}

console.log(`\nexample/Showcase.lua: ${verdict.replace("RESULT ", "")}`);
