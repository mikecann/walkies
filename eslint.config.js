import tseslint from "typescript-eslint";
import machines from "@convex-dev/state-machines/eslint";

// The state machine library's guardrails (convex/machines.ts): no optional fields beside
// a machine's state, no writes to its state round the machine, no way round the internal
// brand, and a reason on any eslint-disable that turns one off. With type information
// they read the app's DataModel to find the machines' tables.
export default [
  { ignores: ["convex/_generated/**"] },
  {
    files: ["convex/**/*.ts"],
    languageOptions: {
      parser: tseslint.parser,
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
    ...machines.configs.recommended,
  },
  // The catalog registers the delivery that timers and links fire through.
  {
    files: ["convex/machines.ts"],
    rules: { "machines/no-brand-bypass": ["error", { deliver: false }] },
  },
  // Tests put rows straight into a state to set up a case, and the library's test
  // helpers reach the internal brand on purpose.
  {
    files: ["convex/**/*.test.ts"],
    rules: { "machines/no-direct-state-writes": "off", "machines/no-brand-bypass": "off" },
  },
];
