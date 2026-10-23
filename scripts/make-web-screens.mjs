#!/usr/bin/env node
// Makes the home page's phone screenshots (web/public/screens/*.webp, 600 × 1304) from
// full-size iPhone screenshots (1320 × 2868 PNGs, status bar at 9:41). Run it again
// whenever the screenshots are retaken:
//
//   node scripts/make-web-screens.mjs path/to/screenshots
//
// It wants these six, named like this: map, recap, secrets, progress, quests and walks.
// It uses ffmpeg (brew install ffmpeg) for the WebP, since ImageIO can't write one.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const NAMES = ["map", "recap", "secrets", "progress", "quests", "walks"];

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const from = process.argv[2];
if (!from) {
  console.error("Usage: node scripts/make-web-screens.mjs <folder of screenshots>");
  process.exit(1);
}
const out = join(root, "web/public/screens");
mkdirSync(out, { recursive: true });

for (const name of NAMES) {
  const png = resolve(from, `${name}.png`);
  if (!existsSync(png)) throw new Error(`No ${name}.png in ${from}`);
  const webp = join(out, `${name}.webp`);
  // Lanczos keeps the street names readable at this size, and yuv420p drops the
  // alpha channel the screenshots carry but never use.
  execFileSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-i", png,
    "-vf", "scale=600:1304:flags=lanczos,format=yuv420p", "-c:v", "libwebp", "-quality", "82",
    "-compression_level", "6", webp], { stdio: "inherit" });
  console.log(`  web/public/screens/${name}.webp (${Math.round(statSync(webp).size / 1024)} KB)`);
}
