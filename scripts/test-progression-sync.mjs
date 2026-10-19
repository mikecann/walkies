// Exercises the server merge without connecting to or deploying Convex.
import assert from "node:assert/strict";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import ts from "typescript";

const root = new URL("../", import.meta.url);
const output = new URL("build/progression-sync-tests/", root);
await mkdir(output, { recursive: true });
const source = await readFile(new URL("convex/progression.ts", root), "utf8");
const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText;
const moduleURL = new URL("progression.mjs", output);
await writeFile(moduleURL, compiled);
const { mergeLedgers, parseLedger } = await import(moduleURL);
const equipped = { marker: "marker.dot", trail: "trail.teal", clouds: "clouds.classic", cover: "cover.red", celebration: "celebration.confetti", updatedAt: 0 };
const first = {
  purchases: [{ id: "a", item: "spyglass", cost: 60, at: 10 }],
  claims: [{ level: 2, choice: "shells.50" }],
  spyglasses: [{ id: "s1", secretId: "secret", centre: [0, 1], at: 12 }],
  equipped,
  offers: [{ level: 3, choices: ["cover.map", "shells.50", "spyglasses.2"] }],
};
const second = {
  purchases: [{ id: "a", item: "spyglass", cost: 99, at: 10 }, { id: "b", item: "trail.sparkles", cost: 250, at: 20 }],
  claims: [{ level: 2, choice: "spyglasses.2" }, { level: 4, choice: "spyglasses.2" }],
  spyglasses: [{ id: "s1", secretId: "different", centre: [2, 3], at: 14 }, { id: "s2", secretId: "other", centre: [1, 2], at: 15 }],
  equipped: { ...equipped, trail: "trail.sparkles", updatedAt: 20 },
  offers: [{ level: 3, choices: ["x", "y", "z"] }],
};
const result = mergeLedgers(first, second);
assert.deepEqual(result.purchases, [first.purchases[0], second.purchases[1]]);
assert.deepEqual(result.claims, [first.claims[0], second.claims[1]]);
assert.deepEqual(result.spyglasses, [first.spyglasses[0], second.spyglasses[1]]);
assert.deepEqual(result.offers, first.offers);
assert.deepEqual(result.equipped, second.equipped);
assert.deepEqual(mergeLedgers(result, second), result);
assert.deepEqual(mergeLedgers(first, { ...second, equipped: { ...second.equipped, updatedAt: 0 } }).equipped, first.equipped);
assert.deepEqual(parseLedger(JSON.stringify(result)), result);
assert.deepEqual(parseLedger(JSON.stringify({ ...first, offers: undefined })).purchases, first.purchases);
for (const invalid of ["{}", "null", "[]", "not-json", JSON.stringify({ ...first, purchases: [{ ...first.purchases[0], cost: -1 }] }), JSON.stringify({ ...first, spyglasses: [{ ...first.spyglasses[0], centre: [0] }] })]) {
  assert.throws(() => parseLedger(invalid));
}
console.log("Progression sync merge and wire validation checks passed.");
