// Writes docs/machines.md from the machines' rules (scripts/machine-diagrams.ts).
//   npm run diagrams          rewrite it
//   npm run diagrams:check    fail if it's out of date
import { readFileSync, writeFileSync } from "node:fs";
import { machineDiagrams } from "./machine-diagrams";

const path = new URL("../docs/machines.md", import.meta.url);
const markdown = machineDiagrams();
if (process.argv.includes("--check")) {
  let current = "";
  try {
    current = readFileSync(path, "utf8");
  } catch {
    // Missing counts as out of date.
  }
  if (current !== markdown) {
    console.error("docs/machines.md is out of date. Run `npm run diagrams`.");
    process.exit(1);
  }
  console.log("docs/machines.md is up to date.");
} else {
  writeFileSync(path, markdown);
  console.log("Wrote docs/machines.md.");
}
