/*
 * Validates tools/locals.mjs against the counts the real VM produces.
 * node tests/locals.test.mjs
 */

import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { peakLocals, LOCAL_REGISTER_LIMIT } from "../tools/locals.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const astBin = join(root, ".tools", "luau-ast.exe");

const dir = mkdtempSync(join(tmpdir(), "flux-locals-"));

function measure(name, source) {
  const file = join(dir, `${name}.lua`);
  writeFileSync(file, source, "utf8");
  const json = execFileSync(astBin, [file], { maxBuffer: 256 * 1024 * 1024, encoding: "latin1" });
  return peakLocals(JSON.parse(json));
}

const cases = [];
const expect = (label, actual, wanted) => cases.push({ label, actual, wanted, ok: actual === wanted });

// 1. Two hundred sequential chunk-level locals.
expect(
  "200 sequential chunk locals",
  measure("flat", Array.from({ length: 200 }, (_, i) => `local v${i} = ${i}`).join("\n") + "\nreturn v0\n"),
  200,
);

// 2. A do-block of 150 followed by a do-block of 60 must report 150, not 210.
const blockA = Array.from({ length: 150 }, (_, i) => `    local a${i} = ${i}`).join("\n");
const blockB = Array.from({ length: 60 }, (_, i) => `    local b${i} = ${i}`).join("\n");
expect(
  "sequential do-blocks take the max",
  measure("blocks", `do\n${blockA}\nend\ndo\n${blockB}\nend\n`),
  150,
);

// 3. A nested function holding 90 locals with two params and a vararg costs 93.
const inner = Array.from({ length: 90 }, (_, i) => `    local c${i} = ${i}`).join("\n");
expect(
  "function arena = params + vararg + body",
  measure("nested", `local outer = 1\nlocal f = function(a, b, ...)\n${inner}\n    return a, b, outer\nend\nreturn f\n`),
  93,
);

// 4. A nested function over the limit is invisible to a compile gate but must be caught here.
const fat = Array.from({ length: 210 }, (_, i) => `    local d${i} = ${i}`).join("\n");
expect("over-budget nested function is measured", measure("fat", `local g = function()\n${fat}\nend\nreturn g\n`), 210);

let failed = 0;
for (const item of cases) {
  const verdict = item.ok ? "ok  " : "FAIL";
  if (!item.ok) failed += 1;
  console.log(`${verdict} ${item.label}: got ${item.actual}, want ${item.wanted}`);
}

console.log(`\nlimit is ${LOCAL_REGISTER_LIMIT}; ${cases.length - failed}/${cases.length} probes agree`);
process.exit(failed === 0 ? 0 : 1);
