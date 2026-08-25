#!/usr/bin/env bun
/**
 * Reads back everything App Store Connect needs before 1.0 can be submitted,
 * and says what is missing.
 *
 * `asc-verify.ts` answers one question — did the screenshots arrive intact.
 * This answers the other one: is the listing complete. They are separate
 * because a listing can be complete in every language and still be
 * unsubmittable for a reason that lives nowhere near a localization — no build
 * attached, no price, no age rating, no review contact. Those are one object
 * each and easy to forget precisely because they are not per-language.
 *
 *   bun scripts/asc-audit.ts
 */

import { readFileSync } from "node:fs";
import { Client } from "../lib/asc";
import { LOCALES } from "../lib/locales";

const appId: string = JSON.parse(readFileSync("apple-project.json", "utf8")).appStoreConnect.appleId;
const c = new Client();

const EDITABLE = new Set([
  "PREPARE_FOR_SUBMISSION",
  "DEVELOPER_REJECTED",
  "REJECTED",
  "METADATA_REJECTED",
  "INVALID_BINARY",
]);

const versions = await c.all(`/v1/apps/${appId}/appStoreVersions?limit=50`);
const version = versions.find((v: any) => EDITABLE.has(v.attributes.appStoreState));
if (!version) throw new Error("no editable version");

const blockers: string[] = [];
const notes: string[] = [];

console.log(`Version ${version.attributes.versionString}  ${version.attributes.appStoreState}\n`);

// ---- per-language metadata -------------------------------------------------
// The two resources are keyed by locale but are not joined by the API, so they
// are fetched separately and matched here.
const vlocs = await c.all(
  `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations?limit=100`,
);
const appInfos = await c.all(`/v1/apps/${appId}/appInfos`);
const info =
  appInfos.find((i: any) => EDITABLE.has(i.attributes.appStoreState)) ?? appInfos[0];
const ilocs = await c.all(`/v1/appInfos/${info.id}/appInfoLocalizations?limit=100`);

const byLocale = new Map<string, any>();
for (const l of ilocs) byLocale.set(l.attributes.locale, l.attributes);

const rows: string[] = [];
for (const want of LOCALES) {
  const v = vlocs.find((l: any) => l.attributes.locale === want.asc);
  const i = byLocale.get(want.asc);
  if (!v) {
    blockers.push(`${want.asc}: no version localization`);
    continue;
  }
  const a = v.attributes;
  const gaps: string[] = [];
  if (!i?.name) gaps.push("name");
  if (!i?.subtitle) gaps.push("subtitle");
  if (!i?.privacyPolicyUrl) gaps.push("privacyPolicyUrl");
  if (!a.description) gaps.push("description");
  if (!a.keywords) gaps.push("keywords");
  if (!a.promotionalText) gaps.push("promotionalText");
  if (!a.supportUrl) gaps.push("supportUrl");
  if (gaps.length) blockers.push(`${want.asc}: missing ${gaps.join(", ")}`);

  // Keywords are the field most likely to be silently left in English: they are
  // invisible in the listing, so nothing looks wrong when they are wrong.
  const kw = (a.keywords ?? "").length;
  rows.push(
    `${want.asc.padEnd(8)} kw ${String(kw).padStart(3)}/100  ` +
      `desc ${String((a.description ?? "").length).padStart(4)}  ` +
      `sub ${String((i?.subtitle ?? "").length).padStart(2)}/30  ` +
      `${a.keywords ?? ""}`,
  );
}
for (const r of rows) console.log(r);

// English keywords repeated verbatim in another language is not an error the
// API will report, so compare rather than trust.
const en = vlocs.find((l: any) => l.attributes.locale === "en-US")?.attributes?.keywords;
const copied = vlocs
  .filter((l: any) => l.attributes.locale !== "en-US" && l.attributes.keywords === en)
  .map((l: any) => l.attributes.locale);
if (copied.length) notes.push(`keywords identical to en-US: ${copied.join(", ")}`);

// ---- the things that are not per-language ----------------------------------
console.log();

// These are to-one relationships. `all()` paginates and expects a list, so it
// throws on the single object these return — read them with `request` instead.
const one = async (path: string) => {
  try {
    return (await c.request("GET", path))?.data ?? null;
  } catch {
    return null;
  }
};

const attached = await one(`/v1/appStoreVersions/${version.id}/build`);
if (attached?.attributes?.version) {
  console.log(
    `build           ${attached.attributes.version} ${attached.attributes.processingState ?? ""}`,
  );
  // A build being attached is not the same as the *right* build being attached.
  // Uploading a new one does not move the version's selection, so a version can
  // sit here for days pointing at a binary from before the work that matters —
  // which looks identical to being finished.
  const builds = await c.all(`/v1/apps/${appId}/builds?limit=20`).catch(() => []);
  const top = builds.sort(
    (a: any, b: any) => Number(b.attributes.version) - Number(a.attributes.version),
  )[0];
  if (top && Number(top.attributes.version) > Number(attached.attributes.version)) {
    const s = top.attributes.processingState;
    blockers.push(
      `build ${attached.attributes.version} attached but ${top.attributes.version} is newer (${s})` +
        (s === "VALID" ? " — run scripts/asc-attach-build.ts" : ""),
    );
  }
} else {
  console.log(`build           none`);
  blockers.push("no build attached to the version");
}

// The age rating hangs off `appInfo`, not the version — it describes the app,
// not the release. Asking the version for it returns null rather than an error,
// which reads exactly like a missing declaration.
const rating = await one(`/v1/appInfos/${info.id}/ageRatingDeclaration`);
console.log(`age rating      ${rating?.id ? "declared" : "MISSING"}`);
if (!rating?.id) blockers.push("no age rating declaration");

const detail = await one(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`);
const rd = detail?.attributes ?? {};
const contactOk = rd.contactEmail && rd.contactPhone && rd.contactFirstName;
console.log(`review contact  ${contactOk ? rd.contactEmail : "MISSING"}`);
if (!contactOk) blockers.push("no App Store review contact");

// Price lives on the app, not the version, and reaching it takes two hops: the
// schedule is a to-one relationship whose id then addresses the prices. A paid
// app with no schedule is the one blocker no API key can clear — it needs the
// Account Holder to sign the Paid Applications agreement first.
const schedule = await one(`/v1/apps/${appId}/appPriceSchedule`);
if (!schedule?.id) {
  console.log(`price           none`);
  blockers.push("no price schedule — needs the Paid Applications agreement");
} else {
  // The price itself is on the included appPricePoint, not on the appPrice —
  // the appPrice is only the join. Ask for it inline rather than per row.
  const res = await c
    .request("GET", `/v1/appPriceSchedules/${schedule.id}/manualPrices?include=appPricePoint&limit=10`)
    .catch(() => null);
  const points = (res?.included ?? []).filter((x: any) => x.type === "appPricePoints");
  if (!points.length) {
    console.log(`price           schedule exists, no manual price`);
    blockers.push("price schedule has no price");
  } else {
    for (const p of points) {
      console.log(
        `price           ${p.attributes.customerPrice} (proceeds ${p.attributes.proceeds})`,
      );
    }
  }
}

// Territory count comes back in the relationship's paging meta. Walking the
// 175 rows to count them costs several pages and answers the same question.
const availRes = await c
  .request(
    "GET",
    `/v1/apps/${appId}/appAvailabilityV2?include=territoryAvailabilities&limit[territoryAvailabilities]=1`,
  )
  .catch(() => null);
const total = availRes?.data?.relationships?.territoryAvailabilities?.meta?.paging?.total;
if (!Number.isFinite(total)) {
  console.log(`territories     unreadable`);
} else {
  const future = availRes.data.attributes?.availableInNewTerritories ? ", new ones auto-added" : "";
  console.log(`territories     ${total}${future}`);
  if (!total) blockers.push("no territories selected");
}

// ---- verdict ---------------------------------------------------------------
console.log();
for (const n of notes) console.log(`note     ${n}`);
if (!blockers.length) {
  console.log("Ready to submit.");
} else {
  console.log(`${blockers.length} blocker${blockers.length === 1 ? "" : "s"}:`);
  for (const b of blockers) console.log(`  ${b}`);
}
