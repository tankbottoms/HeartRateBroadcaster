#!/usr/bin/env bun
/**
 * Writes the App Review Information "Notes" field from
 * `notes/app-review-information-notes.md`.
 *
 *   bun scripts/asc-notes.ts            # show the diff, write nothing
 *   bun scripts/asc-notes.ts --apply    # write it
 *
 * The markdown file is part prose-for-us and part text-for-Apple. Only the
 * second part goes in the field, and it is delimited by the first two `---`
 * rules — everything before the first is instructions to ourselves and
 * everything after the second is the URL substitution table.
 *
 * The field belongs to `appStoreReviewDetail`, a singleton hanging off the
 * editable version. It exists already for any version that has been submitted
 * once, so this PATCHes rather than POSTs; a POST against an existing one is a
 * 409 that does not say which resource it means.
 */

import { readFileSync } from "node:fs";
import { Client, body } from "../lib/asc";

const APP_ID = JSON.parse(readFileSync("apple-project.json", "utf8")).appStoreConnect.appleId;
const LIMIT = 4000; // App Store Connect truncates silently past this.

const md = readFileSync("notes/app-review-information-notes.md", "utf8");
const parts = md.split(/^---$/m);
if (parts.length < 3) throw new Error("expected two --- rules in the notes markdown");
const notes = parts[1].trim();

if (!notes) throw new Error("extracted notes are empty");
if (notes.length > LIMIT) throw new Error(`notes are ${notes.length} characters, over ${LIMIT}`);

const c = new Client();
const apply = process.argv.includes("--apply");

const EDITABLE = new Set([
  "PREPARE_FOR_SUBMISSION",
  "DEVELOPER_REJECTED",
  "REJECTED",
  "METADATA_REJECTED",
  "INVALID_BINARY",
]);

const versions = await c.all(`/v1/apps/${APP_ID}/appStoreVersions?limit=20`);
const version = versions.find((v: any) => EDITABLE.has(v.attributes.appStoreState));
if (!version) throw new Error("no editable version — nothing to write notes to");
console.log(`version ${version.attributes.versionString} (${version.attributes.appStoreState})`);

const detail = (await c.request("GET", `/v1/appStoreVersions/${version.id}/appStoreReviewDetail`))?.data;
if (!detail) throw new Error("no appStoreReviewDetail on this version");

const current: string = detail.attributes?.notes ?? "";
if (current.trim() === notes) {
  console.log("notes already match — nothing to do");
  process.exit(0);
}

console.log(`current ${current.length} chars, new ${notes.length} chars`);
console.log(`--- new ---\n${notes}\n-----------`);

if (!apply) {
  console.log("dry run — pass --apply to write");
  process.exit(0);
}

await c.request("PATCH", `/v1/appStoreReviewDetails/${detail.id}`,
                body("appStoreReviewDetails", { notes }, undefined, detail.id));
console.log("notes written");
