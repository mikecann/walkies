// Puts the Apple and Google sign-in settings on a Convex deployment without
// printing any of them.
//
// Usage: node scripts/set-oauth-keys.mjs <dev|prod> <path to oauth.json>
//
// oauth.json (keep it out of git, e.g. in ~/Downloads, and delete it after):
// {
//   "appleServicesId": "com.mikecann.walkies.signin",
//   "appleKeyId": "ABC123DEFG",
//   "appleKeyFile": "/Users/you/Downloads/AuthKey_ABC123DEFG.p8",
//   "googleClientId": "1234-abc.apps.googleusercontent.com",
//   "googleClientSecret": "GOCSPX-..."
// }
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

const [target, file] = process.argv.slice(2);
if (!["dev", "prod"].includes(target) || !file) {
  console.error("Usage: node scripts/set-oauth-keys.mjs <dev|prod> <oauth.json>");
  process.exit(1);
}
const config = JSON.parse(readFileSync(file, "utf8"));
const values = {
  AUTH_APPLE_CLIENT_ID: config.appleServicesId,
  AUTH_APPLE_TEAM_ID: config.appleTeamId ?? "4DTAZSZL6B",
  AUTH_APPLE_KEY_ID: config.appleKeyId,
  AUTH_APPLE_PRIVATE_KEY: config.appleKeyFile ? readFileSync(config.appleKeyFile, "utf8").trim() : undefined,
  AUTH_GOOGLE_CLIENT_ID: config.googleClientId,
  AUTH_GOOGLE_CLIENT_SECRET: config.googleClientSecret,
};
for (const [name, value] of Object.entries(values)) {
  if (!value) {
    console.log(`skipped ${name} (not in ${file})`);
    continue;
  }
  // The value goes in on stdin: as an argument the .p8 key's leading "-----"
  // reads as a flag, and the CLI's error message would echo it back.
  const args = ["convex", "env", "set", name, ...(target === "prod" ? ["--prod"] : [])];
  const result = spawnSync("npx", args, { encoding: "utf8", input: value });
  if (result.status !== 0) {
    console.error(`Couldn't set ${name}:\n${result.stderr.split(value).join("[redacted]")}`);
    process.exit(1);
  }
  console.log(`set ${name} on ${target}`);
}
