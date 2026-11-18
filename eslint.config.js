import mikecannLint from "mikecann-lint";

// mikecann-lint brings the state machine library's guardrails for convex/, with
// the catalog (convex/machines.ts) and test exemptions the old config had.
// scripts/ are Node scripts outside convex/tsconfig.json.
export default await mikecannLint({ root: import.meta.dirname, untyped: ["scripts/**"] });
