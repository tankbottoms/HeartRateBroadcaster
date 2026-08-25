#!/usr/bin/env bun
/**
 * Submits the editable version for App Review.
 *
 *   bun scripts/asc-submit.ts            # preflight only, submits nothing
 *   bun scripts/asc-submit.ts --apply    # preflight, then submit
 *
 * WHY THIS IS THREE CALLS AND NOT ONE
 * `appStoreVersionSubmissions` — the one-POST endpoint most examples still
 * show — was retired. What replaced it models a submission as a container that
 * can carry several things at once (a version, an in-app purchase, a custom
 * product page), so creating it and putting the version in it are separate
 * acts, and neither of them submits anything:
 *
 *   POST   /v1/reviewSubmissions        create the container
 *   POST   /v1/reviewSubmissionItems    put the version in it
 *   PATCH  /v1/reviewSubmissions/{id}   { submitted: true }  <- this one submits
 *
 * Stopping after the second leaves a submission sitting in READY_FOR_REVIEW
 * that looks submitted in the API and is not in the queue. That state is also
 * why this reuses an existing container rather than creating a second one: a
 * previous half-finished run leaves one behind, and a second POST is a 409.
 *
 * EXPORT COMPLIANCE
 * The "does your app use encryption" question is not part of the submission —
 * it is an attribute of the *build*, and an unanswered build blocks the
 * submit with an error that names neither. It is answered here, from
 * apple-project.json, so the browser is not needed for it.
 */

import { readFileSync } from "node:fs";
import { Client, body } from "../lib/asc";

const project = JSON.parse(readFileSync("apple-project.json", "utf8"));
const APP_ID: string = project.appStoreConnect.appleId;

const c = new Client();
const apply = process.argv.includes("--apply");

const EDITABLE = new Set([
  "PREPARE_FOR_SUBMISSION",
  "DEVELOPER_REJECTED",
  "REJECTED",
  "METADATA_REJECTED",
  "INVALID_BINARY",
]);

const fail: string[] = [];
const ok = (s: string) => console.log(`  ok   ${s}`);
const bad = (s: string) => {
  console.log(`  FAIL ${s}`);
  fail.push(s);
};

// ---------------------------------------------------------------------------
// Preflight
// ---------------------------------------------------------------------------

const versions = await c.all(`/v1/apps/${APP_ID}/appStoreVersions?limit=20`);
const version = versions.find((v: any) => EDITABLE.has(v.attributes.appStoreState));
if (!version) {
  const states = versions.map((v: any) => `${v.attributes.versionString} ${v.attributes.appStoreState}`);
  console.error(`No editable version. Found: ${states.join(", ") || "none"}`);
  process.exit(1);
}
console.log(`${version.attributes!.versionString} · ${version.attributes!.appStoreState}\n`);

// The build. A version with no build attached submits and is rejected within
// the hour, which costs a full review cycle for a one-field mistake.
const build = (await c.request("GET", `/v1/appStoreVersions/${version.id}/build`))?.data;
if (!build) bad("no build attached");
else {
  const b = await c.get(`/v1/builds/${build.id}`);
  const attrs = b.data.attributes;
  if (attrs.processingState !== "VALID") bad(`build ${attrs.version} is ${attrs.processingState}`);
  else ok(`build ${attrs.version} VALID`);

  // null means unanswered, which is not the same as false.
  if (attrs.usesNonExemptEncryption === null) {
    const declared = project.appStoreConnect?.usesNonExemptEncryption ?? false;
    console.log(`  ..   export compliance unanswered → ${declared}`);
    if (apply) {
      await c.patch(
        `/v1/builds/${build.id}`,
        body("builds", { usesNonExemptEncryption: declared }, undefined, build.id),
      );
      ok(`export compliance set to ${declared}`);
    }
  } else ok(`export compliance ${attrs.usesNonExemptEncryption}`);
}

// Screenshots. Apple requires a set for the largest iPhone and — because this
// binary declares iPad support — for iPad as well. A missing iPad set is the
// single most common cause of a submission bouncing back within minutes.
const locs = await c.all(
  `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations?limit=50`,
);
const base = locs.find((l: any) => l.attributes.locale === "en-US") ?? locs[0];
const sets = await c.all(`/v1/appStoreVersionLocalizations/${base.id}/appScreenshotSets`);
const counts = new Map<string, number>();
for (const s of sets) {
  const shots = await c.all(`/v1/appScreenshotSets/${s.id}/appScreenshots`);
  // SAFETY: a screenshot set is created for a display type, so every set in
  // this collection carries one.
  counts.set(s.attributes!.screenshotDisplayType as string, shots.length);
  // An asset that uploaded but never had its checksum committed sits in the
  // set as "processing" forever and blocks the submit, so count them here
  // rather than discover them in the rejection.
  const stuck = shots.filter((x: any) => x.attributes.assetDeliveryState?.state !== "COMPLETE");
  if (stuck.length) bad(`${s.attributes!.screenshotDisplayType}: ${stuck.length} screenshots not COMPLETE`);
}
for (const need of ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129"]) {
  const n = counts.get(need) ?? 0;
  if (n < 1) bad(`${base.attributes!.locale}: no ${need} screenshots`);
  else ok(`${need} ${n} screenshots`);
}

// Age rating and review contact both live off appInfo and both block submit.
const appInfos = await c.all(`/v1/apps/${APP_ID}/appInfos`);
const appInfo = appInfos.find((i: any) => EDITABLE.has(i.attributes.appStoreState)) ?? appInfos[0];
const rating = (await c.request("GET", `/v1/appInfos/${appInfo.id}/ageRatingDeclaration`))?.data;
if (rating) ok("age rating declared");
else bad("age rating not declared");

const review = (await c.request("GET", `/v1/appStoreVersions/${version.id}/appStoreReviewDetail`))?.data;
if (!review?.attributes?.contactEmail) bad("no App Review contact");
else ok(`review contact ${review.attributes.contactEmail}`);

if (fail.length) {
  console.error(`\n${fail.length} blocker${fail.length === 1 ? "" : "s"} — not submitting.`);
  process.exit(1);
}

if (!apply) {
  console.log("\nPreflight clean. Add --apply to submit.");
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Submit
// ---------------------------------------------------------------------------

const open = (
  await c.all(`/v1/apps/${APP_ID}/reviewSubmissions?filter[state]=READY_FOR_REVIEW`)
).find((s: any) => s.attributes.platform === "IOS");

const submission =
  open ??
  (
    await c.post(
      "/v1/reviewSubmissions",
      body("reviewSubmissions", { platform: "IOS" }, {
        app: { data: { type: "apps", id: APP_ID } },
      }),
    )
  ).data;
console.log(`\nsubmission ${submission.id} ${open ? "(reused)" : "(created)"}`);

const items = await c.all(`/v1/reviewSubmissions/${submission.id}/items`);
const already = items.some((i: any) => i.relationships?.appStoreVersion?.data?.id === version.id);
if (already) console.log("version already in the submission");
else {
  await c.post(
    "/v1/reviewSubmissionItems",
    body("reviewSubmissionItems", {}, {
      reviewSubmission: { data: { type: "reviewSubmissions", id: submission.id } },
      appStoreVersion: { data: { type: "appStoreVersions", id: version.id } },
    }),
  );
  console.log("version added to the submission");
}

const done = await c.patch(
  `/v1/reviewSubmissions/${submission.id}`,
  body("reviewSubmissions", { submitted: true }, undefined, submission.id),
);
console.log(`state ${done.data.attributes.state}`);
