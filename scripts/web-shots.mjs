#!/usr/bin/env node
// Full-page screenshots of the website at phone (390 px) and desktop (1440 px) width, into
// web-shots/ (or the folder you pass). Builds web/dist, serves it the way prod does
// (scripts/serve-web.mjs) and drives headless Chromium with Playwright. It also warns if
// any page scrolls sideways. `npm run web:shots` (first time: `npx playwright install chromium`).
import { spawn, execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = resolve(root, process.argv[2] ?? "web-shots");
const port = 5176;
mkdirSync(out, { recursive: true });
execFileSync("node", ["scripts/build-web.mjs"], { cwd: root, stdio: "inherit" });
const server = spawn("node", ["scripts/serve-web.mjs"], { cwd: root, env: { ...process.env, PORT: String(port) }, stdio: "ignore" });
await new Promise((r) => setTimeout(r, 600));

const sizes = {
  phone: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
  desktop: { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 },
};
const pages = { home: "/", privacy: "/privacy", support: "/support" };
const browser = await chromium.launch();
try {
  for (const [size, options] of Object.entries(sizes)) {
    const context = await browser.newContext(options);
    const page = await context.newPage();
    for (const [name, path] of Object.entries(pages)) {
      await page.goto(`http://localhost:${port}${path}`, { waitUntil: "networkidle" });
      // Lazy images only load once they're near the screen, so scroll through first.
      await page.evaluate(async () => {
        for (let y = 0; y < document.body.scrollHeight; y += 400) {
          window.scrollTo(0, y);
          await new Promise((r) => setTimeout(r, 40));
        }
        window.scrollTo(0, 0);
      });
      await page.waitForLoadState("networkidle");
      const wide = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      if (wide > 0) console.warn(`  ${name} at ${size} width scrolls sideways by ${wide}px`);
      const file = join(out, `${name}-${size}.png`);
      await page.screenshot({ path: file, fullPage: true });
      console.log(`  ${file}`);
    }
    await context.close();
  }
} finally {
  await browser.close();
  server.kill();
}
