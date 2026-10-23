#!/usr/bin/env node
// Gets the version being prepared ready for App Review, and submits it with --submit.
//
// Usage: node scripts/appstore-submit.mjs <build number> [--submit]
//   1. waits until App Store Connect has processed the build (VALID),
//   2. attaches it to the version, sets a manual release and "contains third-party content"
//      (OpenStreetMap's streets and Wikimedia Commons photos),
//   3. with --submit, creates a review submission for the version and submits it.
// Without --submit it stops after step 2, so it's safe to run before Mike says go.
import { APP_ID, api, requireApp } from "./appstore-lib.mjs";

const [buildNumber] = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const submit = process.argv.includes("--submit");
if (!buildNumber) {
  console.error("Usage: node scripts/appstore-submit.mjs <build number> [--submit]");
  process.exit(1);
}
requireApp();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 1. The build, once processed.
let build;
for (let i = 0; ; i++) {
  const found = await api("GET", `/v1/builds?filter[app]=${APP_ID}&filter[version]=${buildNumber}&limit=1`);
  build = found.data[0];
  const state = build?.attributes?.processingState ?? "not there yet";
  if (state === "VALID") break;
  if (state === "FAILED" || state === "INVALID") throw new Error(`build ${buildNumber} is ${state}`);
  if (i === 0 || i % 4 === 0) console.log(`build ${buildNumber}: ${state}, waiting…`);
  await sleep(30_000);
}
console.log(`build ${buildNumber}: VALID`);
if (build.attributes.usesNonExemptEncryption == null) {
  await api("PATCH", `/v1/builds/${build.id}`, { data: { type: "builds", id: build.id, attributes: { usesNonExemptEncryption: false } } });
  console.log("export compliance: no non-exempt encryption");
}

// 2. Attach it, and the last listing settings.
const versions = await api("GET", `/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=IOS&limit=10`);
const version = versions.data.find((v) => ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"].includes(v.attributes.appStoreState));
if (!version) throw new Error("no version in a state that can be submitted");
await api("PATCH", `/v1/appStoreVersions/${version.id}/relationships/build`, { data: { type: "builds", id: build.id } });
await api("PATCH", `/v1/appStoreVersions/${version.id}`, { data: { type: "appStoreVersions", id: version.id, attributes: { releaseType: "MANUAL" } } });
await api("PATCH", `/v1/apps/${APP_ID}`, { data: { type: "apps", id: APP_ID, attributes: { contentRightsDeclaration: "USES_THIRD_PARTY_CONTENT" } } });
console.log(`version ${version.attributes.versionString}: build attached, manual release, third-party content declared`);

if (!submit) {
  console.log("Ready. Run again with --submit to send it to App Review.");
  process.exit(0);
}

// 3. Submit.
const open = await api("GET", `/v1/reviewSubmissions?filter[app]=${APP_ID}&filter[state]=READY_FOR_REVIEW&limit=1`);
let submission = open.data[0];
if (!submission) {
  submission = (await api("POST", "/v1/reviewSubmissions", {
    data: { type: "reviewSubmissions", attributes: { platform: "IOS" }, relationships: { app: { data: { type: "apps", id: APP_ID } } } },
  })).data;
}
const items = await api("GET", `/v1/reviewSubmissions/${submission.id}/items`);
if (!items.data.length) {
  await api("POST", "/v1/reviewSubmissionItems", {
    data: {
      type: "reviewSubmissionItems",
      relationships: {
        reviewSubmission: { data: { type: "reviewSubmissions", id: submission.id } },
        appStoreVersion: { data: { type: "appStoreVersions", id: version.id } },
      },
    },
  });
}
const done = await api("PATCH", `/v1/reviewSubmissions/${submission.id}`, {
  data: { type: "reviewSubmissions", id: submission.id, attributes: { submitted: true } },
});
console.log(`Submitted for review: ${done.data.attributes.state}`);
