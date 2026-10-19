// Puts Convex Auth signing keys on the production deployment, the same way
// `npx @convex-dev/auth` does for dev. Skips if they're already set (pass --force
// to rotate, which signs everyone out). Nothing secret is printed.
// Usage: node scripts/set-prod-auth-keys.mjs [--force]
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { exportJWK, exportPKCS8, generateKeyPair } from "jose";

const force = process.argv.includes("--force");
const run = (args) => spawnSync("npx", ["convex", "env", ...args, "--prod"], { encoding: "utf8" });

const existing = run(["get", "AUTH_JWKS"]);
if (!force && existing.status === 0 && existing.stdout.trim().length > 0) {
  console.log("AUTH_PRIVATE_KEY and AUTH_JWKS are already set on production, left unchanged.");
  process.exit(0);
}

const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true });
const keys = {
  AUTH_PRIVATE_KEY: Buffer.from(await exportPKCS8(privateKey)).toString("base64"),
  AUTH_JWKS: JSON.stringify({
    keys: [{ ...(await exportJWK(publicKey)), kid: randomUUID(), alg: "RS256", use: "sig" }],
  }),
};
for (const [name, value] of Object.entries(keys)) {
  const result = run(["set", name, value]);
  if (result.status !== 0) {
    console.error(`Couldn't set ${name} on production:\n${result.stderr}`);
    process.exit(1);
  }
}
console.log("Set AUTH_PRIVATE_KEY and AUTH_JWKS on production.");
