/*
 * Peak live locals per prototype, counted off luau-ast JSON.
 *
 * Roblox refuses to load a function whose register arena exceeds 200 live locals:
 *   Out of local registers when trying to allocate <name>: exceeded limit 200
 * That is a load-time abort with no output at all, and the offline compiler only enforces
 * the limit for the chunk scope — a nested function over budget compiles clean under
 * luau.exe and dies in game. So the count is taken from the AST, not from a compile.
 *
 * Rules, verified against probes (see tests/locals.test.mjs):
 *   - a name holds a register from its declaration to the end of the block declaring it;
 *   - a `do … end` block releases its own registers, so two sequential blocks cost the max
 *     of the two, not the sum;
 *   - a function starts a fresh arena seeded with its parameter count plus `...`.
 */

export const LOCAL_REGISTER_LIMIT = 200;

function walkNode(node, arena, state) {
  if (!node || typeof node !== "object") return arena;

  if (Array.isArray(node)) {
    let cursor = arena;
    for (const child of node) cursor = walkNode(child, cursor, state);
    return cursor;
  }

  const kind = node.type;

  if (kind === "AstStatBlock") {
    let inner = arena;
    for (const stat of node.body || []) {
      inner = walkNode(stat, inner, state);
      if (inner > state.peak) state.peak = inner;
    }
    return arena;
  }

  if (kind === "AstExprFunction") {
    const params = (node.args || []).length + (node.vararg ? 1 : 0);
    const nested = { peak: params };
    walkNode(node.body, params, nested);
    if (nested.peak > state.peak) state.peak = nested.peak;
    return arena;
  }

  let cursor = arena;
  if (kind === "AstStatLocal" || kind === "AstStatForIn") cursor += (node.vars || []).length;
  else if (kind === "AstStatLocalFunction" || kind === "AstStatFunction" || kind === "AstStatFor") cursor += 1;

  if (cursor > state.peak) state.peak = cursor;

  for (const key of Object.keys(node)) {
    if (key === "location" || key === "type" || key === "hasDo" || key === "hasIn") continue;
    cursor = walkNode(node[key], cursor, state);
  }

  return cursor;
}

/** astRoot: the parsed JSON document from luau-ast. */
export function peakLocals(astRoot) {
  const state = { peak: 0 };
  walkNode(astRoot, 0, state);
  return state.peak;
}
