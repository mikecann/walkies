#!/usr/bin/env node
// Screenshots of the website at phone and desktop width, into appstore/web-shots/.
// Builds web/dist, serves it the way prod does (scripts/serve-web.mjs) and drives
// headless Chromium with Playwright. `npm run web:shots`
// (first time: `npx playwright install chromium`).
import { spawn, execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "appstore/web-shots");
const port = 5176;
mkdirSync(out, { recursive: true });
execFileSync("node", ["scripts/build-web.mjs"], { cwd: root, stdio: "inherit" });
const server = spawn("node", ["scripts/serve-web.mjs"], { cwd: root, env: { ...process.env, PORT: String(port) }, stdio: "ignore" });
await new Promise((r) => setTimeout(r, 600));

const sizes = { phone: { width: 390, height: 844, deviceScaleFactor: 3, isMobile: true, hasTouch: true },
  desktop: { width: 1440, height: 900, deviceScaleFactor: 2 } };
const pages = { home: "/", privacy: "/privacy", support: "/support" };
const browser = await chromium.launch();
try {
  for (const [size, viewport] of Object.entries(sizes)) {
    const { deviceScaleFactor, isMobile, hasTouch, ...box } = viewport;
    const context = await browser.newContext({ viewport: box, deviceScaleFactor, isMobile, hasTouch });
    const page = await context.newPage();
    for (const [name, path] of Object.entries(pages)) {
      await page.goto(`http://localhost:${port}${path}`, { waitUntil: "networkidle" });
      await page.screenshot({ path: join(out, `${name}-${size}.png`), fullPage: name !== "home" || size === "desktop" });
      if (name === "home" && size === "phone") await page.screenshot({ path: join(out, `home-phone-full.png`), fullPage: true });
      console.log(`  appstore/web-shots/${name}-${size}.png`);
    }
    await context.close();
  }
} finally {
  await browser.close();
  server.kill();
}
