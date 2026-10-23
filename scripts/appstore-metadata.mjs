#!/usr/bin/env node
// Sets Walkies' App Store listing through the App Store Connect API, from appstore/metadata.json.
//
//   node scripts/appstore-metadata.mjs --dry-run   show what would change, change nothing
//   node scripts/appstore-metadata.mjs             make the changes
//
// It covers: the app's content rights declaration; app info (categories, and the en-AU name,
// subtitle and privacy policy URL); the version being prepared (version string, copyright, and
// its en-AU description, keywords, promotional text, support and marketing URLs); the age rating
// declaration; a free price; worldwide availability; and the App Review contact and notes.
// Idempotent: it reads everything first and only writes what differs. Screenshots, the build and
// the App Privacy answers are separate (docs/runbooks/appstore-release.md).
//
// The listing copy is checked first (lengths, no em dashes), so --dry-run is a quick check of
// metadata.json even before the app exists. It then refuses to go on while APP_ID in
// scripts/appstore-lib.mjs is still TODO. The review contact's email and phone come from
// ~/.config/poddle/review-contact.json and are never printed.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { APP_ID, BUNDLE_ID, REVIEW_CONTACT_FILE, get, getAll, api, requireApp, reviewContact } from "./appstore-lib.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dryRun = process.argv.includes("--dry-run");
const meta = JSON.parse(readFileSync(join(root, "appstore/metadata.json"), "utf8"));
/** Filled in from the review contact file rather than kept in git. */
const FROM_FILE = /FROM-REVIEW-CONTACT-FILE|PHONE-NUMBER/;
/** Never printed: the review contact's phone and email. */
const PRIVATE_FIELDS = new Set(["contactPhone", "contactEmail"]);

// ---- checks on the copy, before anything talks to Apple ----

const limits = { subtitle: 30, keywords: 100, promotionalText: 170, description: 4000, name: 30 };
for (const [field, max] of Object.entries(limits)) {
  if ((meta[field] ?? "").length > max) fail(`${field} is ${meta[field].length} characters; the limit is ${max}.`);
}
if (meta.review.notes.length > 4000) fail(`review.notes is ${meta.review.notes.length} characters; the limit is 4000.`);
if (/[—]/.test(JSON.stringify(meta))) fail("metadata.json has an em dash in it.");
if (meta.bundleId !== BUNDLE_ID) fail(`metadata.json's bundleId is ${meta.bundleId}, not ${BUNDLE_ID}.`);
console.log("metadata.json: lengths and copy look fine.");
requireApp();

// ---- reporting and writing ----

let changes = 0;
const show = (v) => {
  if (v === undefined || v === null) return "(unset)";
  const s = typeof v === "string" ? v : JSON.stringify(v);
  return s.length > 70 ? JSON.stringify(s.slice(0, 67) + "…") : JSON.stringify(s);
};

/** The attributes in `want` that differ from `have`, printed. */
function diff(label, have, want) {
  const out = {};
  for (const [k, v] of Object.entries(want)) {
    if (v === undefined) continue;
    if (JSON.stringify(have?.[k] ?? null) !== JSON.stringify(v)) {
      out[k] = v;
      const secret = PRIVATE_FIELDS.has(k);
      console.log(`  ${label}.${k}: ${secret ? (have?.[k] ? "<set>" : "<none>") : show(have?.[k])} → ${secret ? "<set>" : show(v)}`);
    }
  }
  return out;
}

async function write(method, path, body, what) {
  changes++;
  if (dryRun) {
    console.log(`  would ${method} ${path} (${what})`);
    return null;
  }
  const res = await api(method, path, body);
  console.log(`  ${method} ${path}: done (${what})`);
  return res;
}

async function patchAttrs(type, id, label, have, want) {
  const attributes = diff(label, have, want);
  if (Object.keys(attributes).length === 0) return console.log(`  ${label}: up to date`);
  await write("PATCH", `/v1/${type}/${id}`, { data: { type, id, attributes } }, label);
}

function fail(message) {
  console.error(`✗ ${message}`);
  process.exit(1);
}

// ---- the listing ----

async function main() {
  console.log(dryRun ? "Dry run: nothing will change.\n" : "Updating the App Store listing.\n");
  const app = (await get(`/v1/apps/${APP_ID}`)).data;
  if (app.attributes.bundleId !== meta.bundleId) fail(`App ${APP_ID} is ${app.attributes.bundleId}, not ${meta.bundleId}.`);
  console.log(`App: ${app.attributes.name} (${app.attributes.bundleId}), primary locale ${app.attributes.primaryLocale}`);
  await patchAttrs("apps", app.id, "app", app.attributes, { contentRightsDeclaration: meta.contentRightsDeclaration });

  await appInfo(app);
  const version = await appStoreVersion(app);
  await reviewDetails(version);
  await price(app);
  await availability(app);

  console.log(`\n${changes === 0 ? "Everything's up to date." : dryRun ? `${changes} change(s) would be made.` : `${changes} change(s) made.`}`);
}

/** Categories, the age rating, and the en-AU name, subtitle and privacy policy. */
async function appInfo(app) {
  console.log("\nApp info");
  const infos = await getAll(`/v1/apps/${app.id}/appInfos`);
  // The one being edited, if there's a live one too.
  const editable = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "WAITING_FOR_REVIEW"];
  const info = infos.find((i) => editable.includes(i.attributes.state ?? i.attributes.appStoreState)) ?? infos[0];
  if (!info) fail("The app has no app info.");
  console.log(`  state ${info.attributes.state ?? info.attributes.appStoreState}`);

  const full = await get(`/v1/appInfos/${info.id}?include=primaryCategory,secondaryCategory`);
  const rel = full.data.relationships ?? {};
  const relationships = {};
  for (const [key, want] of [["primaryCategory", meta.primaryCategory], ["secondaryCategory", meta.secondaryCategory]]) {
    const have = rel[key]?.data?.id ?? (await get(`/v1/appInfos/${info.id}/relationships/${key}`)).data?.id;
    if (have !== want) {
      console.log(`  appInfo.${key}: ${show(have)} → ${show(want)}`);
      relationships[key] = { data: { type: "appCategories", id: want } };
    }
  }
  if (Object.keys(relationships).length) {
    await write("PATCH", `/v1/appInfos/${info.id}`, { data: { type: "appInfos", id: info.id, relationships } }, "categories");
  } else console.log("  categories: up to date");

  const locs = await getAll(`/v1/appInfos/${info.id}/appInfoLocalizations`);
  const loc = locs.find((l) => l.attributes.locale === meta.locale);
  const want = { name: meta.name, subtitle: meta.subtitle, privacyPolicyUrl: meta.privacyPolicyUrl };
  if (loc) await patchAttrs("appInfoLocalizations", loc.id, `appInfo[${meta.locale}]`, loc.attributes, want);
  else {
    diff(`appInfo[${meta.locale}]`, {}, want);
    await write("POST", "/v1/appInfoLocalizations", {
      data: { type: "appInfoLocalizations", attributes: { locale: meta.locale, ...want },
        relationships: { appInfo: { data: { type: "appInfos", id: info.id } } } },
    }, `${meta.locale} app info`);
  }

  // The age rating. Only questions Apple's API has today are answered; the rest are left alone.
  const rating = (await get(`/v1/appInfos/${info.id}/ageRatingDeclaration`)).data;
  const answers = {};
  const unknown = [];
  for (const [k, v] of Object.entries(meta.ageRating)) {
    if (k.startsWith("_")) continue;
    if (k in rating.attributes) answers[k] = v;
    else unknown.push(k);
  }
  if (unknown.length) console.log(`  ageRating: skipping questions the API doesn't have: ${unknown.join(", ")}`);
  const unanswered = Object.keys(rating.attributes).filter((k) => !(k in answers) && rating.attributes[k] === null);
  if (unanswered.length) console.log(`  ageRating: still unanswered (answer in metadata.json or in App Store Connect): ${unanswered.join(", ")}`);
  await patchAttrs("ageRatingDeclarations", rating.id, "ageRating", rating.attributes, answers);
}

/** The iOS version being prepared: its version string, copyright and en-AU listing. */
async function appStoreVersion(app) {
  console.log("\nVersion");
  const versions = await getAll(`/v1/apps/${app.id}/appStoreVersions?filter[platform]=IOS`);
  const editable = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"];
  let version = versions.find((v) => editable.includes(v.attributes.appVersionState ?? v.attributes.appStoreState));
  if (!version) {
    console.log(`  no iOS version being prepared; creating ${meta.version}`);
    const created = await write("POST", "/v1/appStoreVersions", {
      data: { type: "appStoreVersions", attributes: { platform: "IOS", versionString: meta.version, copyright: meta.copyright, releaseType: meta.releaseType },
        relationships: { app: { data: { type: "apps", id: app.id } } } },
    }, `version ${meta.version}`);
    if (!created) return null;
    version = created.data;
  } else {
    console.log(`  ${version.attributes.versionString} (${version.attributes.appVersionState ?? version.attributes.appStoreState})`);
    await patchAttrs("appStoreVersions", version.id, "version", version.attributes, { versionString: meta.version, copyright: meta.copyright, releaseType: meta.releaseType });
  }

  const locs = await getAll(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`);
  const loc = locs.find((l) => l.attributes.locale === meta.locale);
  const want = {
    description: meta.description, keywords: meta.keywords, promotionalText: meta.promotionalText,
    supportUrl: meta.supportUrl, marketingUrl: meta.marketingUrl,
  };
  if (loc) await patchAttrs("appStoreVersionLocalizations", loc.id, `version[${meta.locale}]`, loc.attributes, want);
  else {
    diff(`version[${meta.locale}]`, {}, want);
    await write("POST", "/v1/appStoreVersionLocalizations", {
      data: { type: "appStoreVersionLocalizations", attributes: { locale: meta.locale, ...want },
        relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: version.id } } } },
    }, `${meta.locale} listing`);
  }
  return version;
}

/** Who App Review contacts, and the notes for them. */
async function reviewDetails(version) {
  console.log("\nApp Review");
  if (!version) return console.log("  (the version doesn't exist yet in a dry run)");
  const review = { ...meta.review };
  const contact = reviewContact();
  for (const key of ["contactEmail", "contactPhone"]) {
    if (FROM_FILE.test(review[key] ?? "") && contact[key]) review[key] = contact[key];
  }
  const want = {
    contactFirstName: review.contactFirstName, contactLastName: review.contactLastName,
    contactEmail: FROM_FILE.test(review.contactEmail) ? undefined : review.contactEmail,
    demoAccountRequired: review.demoAccountRequired, notes: review.notes,
    contactPhone: FROM_FILE.test(review.contactPhone) ? undefined : review.contactPhone,
  };
  for (const key of ["contactEmail", "contactPhone"]) {
    if (want[key] === undefined) console.log(`  ${key}: not in ${REVIEW_CONTACT_FILE}, so it's left alone`);
  }
  let detail = null;
  try {
    detail = (await get(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`)).data;
  } catch (e) {
    if (!/→ 404/.test(String(e))) throw e;
  }
  if (detail) return await patchAttrs("appStoreReviewDetails", detail.id, "review", detail.attributes, want);
  diff("review", {}, want);
  await write("POST", "/v1/appStoreReviewDetails", {
    data: { type: "appStoreReviewDetails", attributes: Object.fromEntries(Object.entries(want).filter(([, v]) => v !== undefined)),
      relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: version.id } } } },
  }, "review details");
}

/** Free, everywhere: a manual price of 0 with the US as the base territory. */
async function price(app) {
  console.log("\nPrice");
  if (meta.price !== "free") fail("Only a free price is supported.");
  let current = null;
  try {
    const schedule = (await get(`/v1/apps/${app.id}/appPriceSchedule`)).data;
    const prices = await get(`/v1/appPriceSchedules/${schedule.id}/manualPrices?include=appPricePoint&limit=50`);
    const points = prices.included?.filter((i) => i.type === "appPricePoints") ?? [];
    current = { count: prices.data.length, free: points.length > 0 && points.every((p) => Number(p.attributes.customerPrice) === 0) };
  } catch (e) {
    if (!/→ 404/.test(String(e))) throw e;
  }
  if (current?.free) return console.log("  free: up to date");
  console.log(`  price: ${current ? "not free" : "(unset)"} → free`);
  const points = await get(`/v1/apps/${app.id}/appPricePoints?filter[territory]=USA&limit=200`);
  const zero = points.data.find((p) => Number(p.attributes.customerPrice) === 0);
  if (!zero) fail("Couldn't find the free price point.");
  await write("POST", "/v1/appPriceSchedules", {
    data: {
      type: "appPriceSchedules",
      relationships: {
        app: { data: { type: "apps", id: app.id } },
        baseTerritory: { data: { type: "territories", id: "USA" } },
        manualPrices: { data: [{ type: "appPrices", id: "${free}" }] },
      },
    },
    included: [{
      type: "appPrices", id: "${free}", attributes: { startDate: null },
      relationships: { appPricePoint: { data: { type: "appPricePoints", id: zero.id } } },
    }],
  }, "free price");
}

/** Every territory, and new ones as Apple adds them. */
async function availability(app) {
  console.log("\nAvailability");
  if (meta.availability !== "worldwide") fail("Only worldwide availability is supported.");
  const territories = await getAll("/v1/territories?limit=200");
  let current = null;
  try {
    current = (await get(`/v1/apps/${app.id}/appAvailabilityV2`)).data;
  } catch (e) {
    if (!/→ 404/.test(String(e))) throw e;
  }
  if (current) {
    const list = await getAll(`/v2/appAvailabilities/${current.id}/territoryAvailabilities?limit=200`);
    const off = list.filter((t) => !t.attributes.available);
    const missing = territories.length - list.length;
    if (current.attributes.availableInNewTerritories && off.length === 0 && missing <= 0) {
      return console.log(`  worldwide (${list.length} territories): up to date`);
    }
    // Apple only lets an existing availability be changed territory by territory.
    console.log(`  ${off.length} territories off, ${Math.max(0, missing)} missing, new territories ${current.attributes.availableInNewTerritories ? "on" : "off"}`);
    for (const t of off) {
      await write("PATCH", `/v1/territoryAvailabilities/${t.id}`,
        { data: { type: "territoryAvailabilities", id: t.id, attributes: { available: true } } }, "make available");
    }
    if (!current.attributes.availableInNewTerritories || missing > 0) {
      console.log("  ! Turn on 'available in new territories' and any missing ones in App Store Connect > Pricing and Availability");
    }
    return;
  }
  console.log(`  (unset) → all ${territories.length} territories, and new ones`);
  await write("POST", "/v2/appAvailabilities", {
    data: {
      type: "appAvailabilities",
      attributes: { availableInNewTerritories: true },
      relationships: {
        app: { data: { type: "apps", id: app.id } },
        territoryAvailabilities: { data: territories.map((t) => ({ type: "territoryAvailabilities", id: `\${${t.id}}` })) },
      },
    },
    included: territories.map((t) => ({
      type: "territoryAvailabilities", id: `\${${t.id}}`, attributes: { available: true },
      relationships: { territory: { data: { type: "territories", id: t.id } } },
    })),
  }, "worldwide availability");
}

main().catch((e) => fail(e.message));
