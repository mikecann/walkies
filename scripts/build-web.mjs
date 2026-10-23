#!/usr/bin/env node
// Builds the website (walkies.mikecann.app) into web/dist for Convex static hosting:
// web/src's pages wrapped in web/src/layout.html, with web/public copied alongside.
// No bundler: it's three plain pages. `npm run web:build`, then `npm run web:upload:prod`
// (docs/runbooks/appstore-release.md). `npm run web:serve` serves web/dist on :5175.
//
// The App Store screenshots (appstore/screenshots/*.png) go in the "Have a look" row,
// shrunk with sips, when they've been taken. Apple's own badge is used if it's at
// web/public/img/app-store-badge.svg; otherwise a drawn one.
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { APP_STORE_URL, PRIVACY_UPDATED, SITE_URL, SUPPORT_EMAIL } from "../web/site.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const src = join(root, "web/src");
const dist = join(root, "web/dist");

/** The screenshots for the home page, in order, with what each shows. */
const SCREENS = [
  ["map", "Your suburb under the clouds"],
  ["recap", "After a walk"],
  ["secrets", "The secrets book"],
  ["progress", "Shells and levels"],
  ["walks", "Every walk"],
];

const APPLE_LOGO = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16.37 12.6c-.03-2.6 2.13-3.86 2.23-3.92-1.22-1.78-3.11-2.02-3.78-2.05-1.6-.17-3.13.95-3.95.95-.82 0-2.07-.93-3.4-.9-1.75.03-3.37 1.02-4.27 2.58-1.82 3.16-.47 7.83 1.31 10.4.87 1.25 1.9 2.66 3.26 2.61 1.31-.05 1.8-.85 3.38-.85 1.58 0 2.02.85 3.4.82 1.41-.02 2.3-1.27 3.15-2.53.99-1.45 1.4-2.86 1.42-2.93-.03-.01-2.72-1.04-2.75-4.18ZM13.8 4.96c.72-.88 1.21-2.09 1.08-3.31-1.04.04-2.3.7-3.05 1.57-.67.77-1.26 2.01-1.1 3.2 1.16.09 2.35-.59 3.07-1.46Z"/></svg>`;

function appStoreBadge() {
  if (!APP_STORE_URL) {
    return `<span class="appstore soon" aria-label="Coming soon to the App Store">${APPLE_LOGO}<span><small>Coming soon to the</small><b>App Store</b></span></span>`;
  }
  if (existsSync(join(root, "web/public/img/app-store-badge.svg"))) {
    return `<a class="appstore-official" href="${APP_STORE_URL}"><img src="/img/app-store-badge.svg" alt="Download on the App Store" width="162" height="54"></a>`;
  }
  return `<a class="appstore" href="${APP_STORE_URL}">${APPLE_LOGO}<span><small>Download on the</small><b>App Store</b></span></a>`;
}

/** Shrinks the App Store screenshots for the page. Nothing if they haven't been taken. */
function screens() {
  const shots = SCREENS.filter(([name]) => existsSync(join(root, "appstore/screenshots", `${name}.png`)));
  if (shots.length === 0) return "";
  mkdirSync(join(dist, "screens"), { recursive: true });
  for (const [name] of shots) {
    const from = join(root, "appstore/screenshots", `${name}.png`);
    const to = join(dist, "screens", `${name}.jpg`);
    execFileSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "78", "-Z", "1000", from, "--out", to], { stdio: "ignore" });
  }
  const items = shots.map(([name, caption]) =>
    `        <li><img src="/screens/${name}.jpg" width="460" height="1000" loading="lazy" alt="Walkies: ${caption.toLowerCase()}"><span>${caption}</span></li>`);
  return `    <section class="screens">\n      <h2>Have a look</h2>\n      <ul class="screen-row">\n${items.join("\n")}\n      </ul>\n    </section>`;
}

const fill = (template, values) => template.replace(/\{\{(\w+)\}\}/g, (match, key) => (key in values ? values[key] : match));
const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });
cpSync(join(root, "web/public"), dist, { recursive: true });

const layout = readFileSync(join(src, "layout.html"), "utf8");
const version = Date.now().toString(36);
const shared = {
  site: SITE_URL, email: SUPPORT_EMAIL, privacyUpdated: PRIVACY_UPDATED, version,
  appStoreBadge: appStoreBadge(), screens: screens(),
  // Smart App Banner in Safari, once there's an App Store page.
  appStoreMeta: APP_STORE_URL?.match(/id(\d+)/) ? `<meta name="apple-itunes-app" content="app-id=${APP_STORE_URL.match(/id(\d+)/)[1]}">` : "",
};
const pages = readdirSync(src).filter((f) => f.endsWith(".html") && f !== "layout.html");
for (const file of pages) {
  const html = readFileSync(join(src, file), "utf8");
  const match = html.match(/^<!--page (\{.*?\}) -->\n/);
  if (!match) throw new Error(`${file} needs a <!--page {...} --> line first`);
  const page = JSON.parse(match[1]);
  const name = file.replace(/\.html$/, "");
  const out = fill(layout, {
    ...shared,
    title: escape(page.title), description: escape(page.description), url: SITE_URL + page.path, page: name,
    supportCurrent: name === "support" ? ' aria-current="page"' : "",
    privacyCurrent: name === "privacy" ? ' aria-current="page"' : "",
    content: fill(html.slice(match[0].length), shared).trimEnd(),
  });
  if (/\{\{\w+\}\}/.test(out)) throw new Error(`${file} has a {{placeholder}} left over: ${out.match(/\{\{\w+\}\}/)[0]}`);
  if (out.includes("—")) throw new Error(`${file} has an em dash in it`);
  writeFileSync(join(dist, file), out);
}
cpSync(join(src, "styles.css"), join(dist, "styles.css"));
console.log(`Built ${pages.length} pages into web/dist${shared.screens ? "" : " (no screenshots yet, so no \"Have a look\" row)"}.`);
