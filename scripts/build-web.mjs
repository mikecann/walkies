#!/usr/bin/env node
// Builds the website (walkies.mikecann.app) into web/dist for Convex static hosting:
// web/src's pages wrapped in web/src/layout.html, with web/public copied alongside.
// No bundler: it's three plain pages. `npm run web:build`, then `npm run web:upload:prod`.
// `npm run web:serve` builds and serves web/dist on :5175.
//
// Pages can use {{phone <name>}} for a screenshot in a phone (add "hero" for one that
// loads straight away, "first" for the one to fetch first), {{gallery}} for the row of
// every screenshot, {{appStoreBadge}} and {{promoVideo}}. The screenshots are
// web/public/screens/*.webp, made by scripts/make-web-screens.mjs.
import { cpSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { APP_STORE_LIVE, APP_STORE_URL, GITHUB_URL, PRIVACY_UPDATED, PROMO_VIDEO, SITE_URL, SUPPORT_EMAIL } from "../web/site.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const src = join(root, "web/src");
const dist = join(root, "web/dist");

/** The screenshots: sample data for a made-up walker in Fremantle, WA. */
const SHOTS = {
  recap: {
    caption: "After a walk",
    alt: "A walk round Fremantle playing back over Apple's satellite map: a teal line along the streets, the clouds cleared off the tiles beside it, and 12 new tiles in 33 minutes 25 at the top",
  },
  map: {
    caption: "The map",
    alt: "The map zoomed out over Fremantle in Perth, with the suburb under white clouds apart from the bits already walked, Fremantle at 46%, 874 shells, level 6 and the Start walk button",
  },
  secrets: {
    caption: "Secrets",
    alt: "The secrets book: 9 of 136 secrets found, 9 of 24 around Busselton, and stickers like Butter by the River, Chasing Deep Water and A Piano on a Truck",
  },
  walks: {
    caption: "Past walks",
    alt: "Past walks: 13 walks, 48.53 km and 324 tiles uncovered so far, then each walk with its route, distance, time, new tiles and steps",
  },
  progress: {
    caption: "Levels",
    alt: "Level 6 with 874 XP, what earned it (tiles, secrets, place milestones, walking streaks and quests), and a reward to pick at each level, like footprints, a sneaker or a bag of 50 shells",
  },
  quests: {
    caption: "Quests",
    alt: "This week's quests: walk 5 km (done), uncover 60 new tiles (33 so far) and find a secret (done), worth 40 shells each",
  },
};
const GALLERY = ["recap", "map", "secrets", "walks", "progress", "quests"];
const SHOT_SIZE = 'width="600" height="1304"';

const APPLE_LOGO = `<svg class="appstore-logo" viewBox="0 0 24 24" aria-hidden="true"><path d="M16.37 12.6c-.02-2.2 1.8-3.26 1.88-3.31-1.03-1.5-2.62-1.7-3.18-1.73-1.35-.14-2.65.8-3.33.8-.7 0-1.75-.78-2.88-.76-1.48.02-2.85.86-3.61 2.19-1.55 2.68-.4 6.63 1.1 8.8.74 1.06 1.61 2.25 2.75 2.2 1.11-.04 1.52-.71 2.86-.71 1.33 0 1.71.71 2.87.69 1.19-.02 1.94-1.07 2.66-2.14.85-1.23 1.19-2.43 1.21-2.49-.03-.01-2.31-.89-2.33-3.54ZM14.2 6.17c.6-.74 1.01-1.75.9-2.77-.87.04-1.94.59-2.56 1.32-.56.64-1.05 1.69-.92 2.68.97.08 1.97-.49 2.58-1.23Z"/></svg>`;

/** The black App Store badge, drawn rather than hotlinked. Until it's live it isn't a link. */
function appStoreBadge() {
  const label = `${APPLE_LOGO}<span><small>${APP_STORE_LIVE ? "Download on the" : "Coming soon to the"}</small><b>App Store</b></span>`;
  return APP_STORE_LIVE ? `<a class="appstore" href="${APP_STORE_URL}">${label}</a>` : `<span class="appstore soon">${label}</span>`;
}

/** A screenshot in a phone. Only the hero's load straight away. */
function phone(name, ...flags) {
  const shot = SHOTS[name];
  if (!shot) throw new Error(`No screenshot called ${name}`);
  const extra = flags.filter((f) => f !== "hero" && f !== "first");
  const loading = flags.includes("hero") ? 'loading="eager"' : 'loading="lazy"';
  const priority = flags.includes("first") ? ' fetchpriority="high"' : "";
  return `<div class="phone${extra.map((c) => ` ${c}`).join("")}"><img src="/screens/${name}.webp" alt="${escape(shot.alt)}" ${SHOT_SIZE} ${loading} decoding="async"${priority}></div>`;
}

function gallery() {
  const items = GALLERY.map((name) =>
    `        <li><figure>${phone(name)}<figcaption>${SHOTS[name].caption}</figcaption></figure></li>`);
  return `<ul class="strip">\n${items.join("\n")}\n      </ul>`;
}

const WATCH_URL = `https://www.youtube.com/watch?v=${PROMO_VIDEO.id}`;

/**
 * The promo video, after Poddle's: the poster with a play button, which swaps in YouTube's
 * player when it's pressed, so nothing loads from YouTube (and it sets no cookies) until
 * then. Without JavaScript the poster's a link to the video on YouTube instead.
 */
function promoVideo() {
  const title = escape(PROMO_VIDEO.title);
  const embed = `https://www.youtube-nocookie.com/embed/${PROMO_VIDEO.id}?autoplay=1&rel=0`;
  return `<section class="promo" aria-label="Walkies in a ${PROMO_VIDEO.seconds} second video">
      <div class="promo-frame">
        <button class="promo-play" type="button" aria-label="Play the video: ${title}" data-embed="${escape(embed)}" data-title="${title}">
          <img src="/img/promo-poster.webp" alt="" width="1600" height="900" loading="lazy" decoding="async">
          <span class="promo-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg></span>
        </button>
        <noscript><a class="promo-play" href="${WATCH_URL}" aria-label="Watch the video on YouTube: ${title}"></a></noscript>
      </div>
      <script>
        document.querySelector(".promo-play").addEventListener("click", (event) => {
          const button = event.currentTarget;
          const player = document.createElement("iframe");
          player.src = button.dataset.embed;
          player.title = button.dataset.title;
          player.allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share";
          player.referrerPolicy = "strict-origin-when-cross-origin";
          player.allowFullscreen = true;
          button.replaceWith(player);
          // The button's gone, so keyboard focus would drop back to the top of the page.
          player.focus();
        });
      </script>
    </section>`;
}

/** schema.org data for the home page, so search engines know what Walkies is. */
function structuredData() {
  const app = {
    "@context": "https://schema.org",
    "@type": "MobileApplication",
    name: "Walkies",
    description: "An iPhone app Mike Cann made where your suburb starts under clouds on a satellite map and the clouds clear off the hex tiles you walk through. The idea is to try and walk every street.",
    operatingSystem: "iOS 18.0 or later",
    applicationCategory: "HealthApplication",
    offers: { "@type": "Offer", price: "0", priceCurrency: "AUD" },
    url: `${SITE_URL}/`,
    image: `${SITE_URL}/img/icon-512.png`,
    screenshot: GALLERY.map((name) => `${SITE_URL}/screens/${name}.webp`),
    author: { "@type": "Person", name: "Mike Cann" },
    ...(APP_STORE_LIVE ? { downloadUrl: APP_STORE_URL, installUrl: APP_STORE_URL } : {}),
  };
  const video = {
    "@context": "https://schema.org",
    "@type": "VideoObject",
    name: PROMO_VIDEO.title,
    description: "Sammy, Mike's chocolate lab, shows you round Walkies: the clouds clearing off your suburb as you walk, the secrets hidden under some of the tiles and watching your walks back.",
    thumbnailUrl: `${SITE_URL}/img/promo-poster.webp`,
    uploadDate: PROMO_VIDEO.uploaded,
    duration: `PT${PROMO_VIDEO.seconds}S`,
    embedUrl: `https://www.youtube.com/embed/${PROMO_VIDEO.id}`,
    contentUrl: WATCH_URL,
  };
  return `<script type="application/ld+json">${JSON.stringify([app, video]).replace(/</g, "\\u003c")}</script>`;
}

const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

/**
 * A Phosphor icon (web/icons/, copied from @phosphor-icons/core, MIT), inlined so it takes
 * the text colour and costs no request. Used by the landing page, after the Elaya
 * landing-page-design skill's "icons from Phosphor, Solar or Iconamoon" rule.
 */
function icon(name) {
  const svg = readFileSync(join(root, "web/icons", `${name}.svg`), "utf8").trim();
  return svg.replace("<svg ", '<svg class="icon" aria-hidden="true" focusable="false" ');
}

/**
 * FAQPage structured data, read back out of the landing page's <details class="faq-item">
 * so the questions only live in one place.
 */
function faqData(html) {
  const text = (s) => s.replace(/<[^>]+>/g, "").replace(/\s+/g, " ").replace(/&amp;/g, "&").trim();
  const items = [...html.matchAll(/<details class="faq-item">\s*<summary>([\s\S]*?)<\/summary>\s*<div class="faq-a">([\s\S]*?)<\/div>\s*<\/details>/g)];
  if (!items.length) return "";
  const data = {
    "@context": "https://schema.org", "@type": "FAQPage",
    mainEntity: items.map(([, q, a]) => ({ "@type": "Question", name: text(q), acceptedAnswer: { "@type": "Answer", text: text(a) } })),
  };
  return `<script type="application/ld+json">${JSON.stringify(data).replace(/</g, "\\u003c")}</script>`;
}

/** Fills {{name}} from `values`, {{phone name flags}} with a phone and {{icon name}} with an icon. */
function fill(template, values) {
  return template.replace(/\{\{(\w+)((?: [\w-]+)*)\}\}/g, (match, key, args) => {
    if (key === "phone") return phone(...args.trim().split(" "));
    if (key === "icon") return icon(args.trim());
    return key in values ? values[key] : match;
  });
}

rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });
cpSync(join(root, "web/public"), dist, { recursive: true });

// A page can pick its layout with "layout" in its <!--page --> line. The landing page uses
// layout-landing.html (the Elaya skill experiment); the others keep layout.html.
const layouts = {};
const layoutFor = (name) => (layouts[name] ??= readFileSync(join(src, `${name}.html`), "utf8"));
const version = Date.now().toString(36);
const appId = APP_STORE_URL.match(/id(\d+)/)?.[1];
const shared = {
  site: SITE_URL, email: SUPPORT_EMAIL, github: GITHUB_URL, privacyUpdated: PRIVACY_UPDATED, version,
  appStoreBadge: appStoreBadge(), gallery: gallery(), promoVideo: promoVideo(),
  // Safari's Smart App Banner. It shows "View" until the app's out, then "Open" or "Get".
  appStoreMeta: appId ? `<meta name="apple-itunes-app" content="app-id=${appId}">` : "",
};
const pages = readdirSync(src).filter((f) => f.endsWith(".html") && !f.startsWith("layout"));
const paths = [];
for (const file of pages) {
  const html = readFileSync(join(src, file), "utf8");
  const match = html.match(/^<!--page (\{.*?\}) -->\n/);
  if (!match) throw new Error(`${file} needs a <!--page {...} --> line first`);
  const page = JSON.parse(match[1]);
  const name = file.replace(/\.html$/, "");
  const content = fill(html.slice(match[0].length), shared).trimEnd();
  const out = fill(layoutFor(page.layout ?? "layout"), {
    ...shared,
    title: escape(page.title), description: escape(page.description), url: SITE_URL + page.path, page: name,
    supportCurrent: name === "support" ? ' aria-current="page"' : "",
    privacyCurrent: name === "privacy" ? ' aria-current="page"' : "",
    structuredData: name === "index" ? structuredData() + faqData(content) : "",
    content,
  });
  if (/\{\{[\w ]+\}\}/.test(out)) throw new Error(`${file} has a {{placeholder}} left over: ${out.match(/\{\{[\w ]+\}\}/)[0]}`);
  // Em and en dashes read as written by a machine, so they never go out.
  if (/[—–]/.test(out)) throw new Error(`${file} has an em or en dash in it: ${out.match(/.{0,40}[—–].{0,40}/)[0]}`);
  writeFileSync(join(dist, file), out);
  paths.push(page.path);
}
cpSync(join(src, "styles.css"), join(dist, "styles.css"));
cpSync(join(src, "landing.css"), join(dist, "landing.css"));
const urls = paths.sort().map((p) => `  <url><loc>${SITE_URL}${p}</loc></url>`).join("\n");
writeFileSync(join(dist, "sitemap.xml"), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`);
console.log(`Built ${pages.length} pages into web/dist.`);
