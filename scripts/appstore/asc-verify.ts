#!/usr/bin/env bun
/**
 * Reads back what App Store Connect actually holds for the editable version.
 *
 * The push script reports what it sent. This reports what arrived, which is a
 * different question: an image can upload cleanly, be committed cleanly, and
 * still sit in the set as `FAILED` because Apple decided afterwards that it is
 * the wrong size or has an alpha channel. Nothing surfaces that until the
 * submission is blocked by it, so it is worth one read.
 *
 *   bun scripts/asc-verify.ts
 */

import { readFileSync } from "node:fs";
import { Client } from "../lib/asc";
import { LOCALES } from "../lib/locales";

const appId: string = JSON.parse(readFileSync("apple-project.json", "utf8")).appStoreConnect.appleId;
const client = new Client();

const versions = await client.all(`/v1/apps/${appId}/appStoreVersions?limit=50`);
const EDITABLE = new Set([
  "PREPARE_FOR_SUBMISSION",
  "DEVELOPER_REJECTED",
  "REJECTED",
  "METADATA_REJECTED",
  "INVALID_BINARY",
]);
const version = versions.find((v: any) => EDITABLE.has(v.attributes.appStoreState));
if (!version) throw new Error("no editable version");

const locs = await client.all(
  `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations?limit=100`,
);

let images = 0;
const bad: string[] = [];
const missing: string[] = [];
const have = new Set<string>();

for (const loc of locs) {
  const locale = loc.attributes.locale;
  have.add(locale);
  const sets = await client.all(`/v1/appStoreVersionLocalizations/${loc.id}/appScreenshotSets`);
  const counts: string[] = [];
  for (const set of sets) {
    const shots = await client.all(`/v1/appScreenshotSets/${set.id}/appScreenshots?limit=50`);
    counts.push(`${set.attributes.screenshotDisplayType}=${shots.length}`);
    images += shots.length;
    for (const s of shots) {
      // COMPLETE is the only state that ships. UPLOAD_COMPLETE means the bytes
      // arrived and Apple has not finished looking at them yet.
      const state = s.attributes.assetDeliveryState?.state;
      if (state !== "COMPLETE") bad.push(`${locale} ${s.attributes.fileName} ${state}`);
    }
  }
  console.log(`${locale.padEnd(8)} ${counts.sort().join("  ") || "no screenshots"}`);
}

for (const l of LOCALES) if (!have.has(l.asc)) missing.push(l.asc);

console.log(`\n${locs.length}/${LOCALES.length} languages, ${images} screenshots`);
if (missing.length) console.log(`Missing languages: ${missing.join(", ")}`);
if (bad.length) {
  console.log(`\nNot ready:`);
  for (const b of bad) console.log(`  ${b}`);
}
if (!missing.length && !bad.length) console.log("Everything is COMPLETE.");
