#!/usr/bin/env bun
/**
 * Publishes the localized App Store listing alongside the press kit, so every
 * field that goes on the product page is readable from a URL.
 *
 *   bun scripts/publish-listing.ts
 *
 * WHY THIS EXISTS
 * `appstore/metadata` is generated and gitignored, and it is where the twenty-
 * five localized listings actually live. That makes it unreachable to anything
 * that is not this checkout — including a browser sitting on App Store Connect,
 * which is the one place the last few fields still have to be typed. Copying
 * the listings to the press kit turns "paste the Polish keywords" into a fetch.
 *
 * It holds nothing private. Every field here is on the public product page the
 * moment the app is approved — no account identifiers, no contact details, no
 * review notes. The press kit is unlinked, not protected, and the rule for what
 * may go in it is exactly that.
 *
 * Run after publish-press-kit.ts, which wipes the directory.
 */

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { LOCALES } from "../lib/locales";

const APP: string = JSON.parse(readFileSync("apple-project.json", "utf8")).app.name;
const REPO = join(import.meta.dir, "..", "..");
const METADATA = join(REPO, "appstore", "metadata");
const OUT = join(REPO, "web", "press", "listing");

if (!existsSync(METADATA)) {
  console.error(`${METADATA} missing — run scripts/export-appstore.ts first`);
  process.exit(1);
}

await mkdir(OUT, { recursive: true });

/** Only fields that appear on the product page. Nothing else is copied. */
const PUBLIC = [
  "name",
  "subtitle",
  "description",
  "keywords",
  "promotionalText",
  "marketingUrl",
  "supportUrl",
  "privacyPolicyUrl",
] as const;

const escape = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const files = readdirSync(METADATA).filter((f) => f.endsWith(".json")).sort();
/** Language code -> that language's listing, as `index.json` publishes it. */
type ListingIndex = Record<string, { file: string; language: string; endonym?: string }>;

const index: ListingIndex = {};
const rows: string[] = [];

for (const file of files) {
  const asc = file.replace(/\.json$/, "");
  const raw = JSON.parse(readFileSync(join(METADATA, file), "utf8"));
  const listing = Object.fromEntries(
    PUBLIC.filter((k) => raw[k]).map((k) => [k, raw[k]]),
  );
  await writeFile(join(OUT, file), JSON.stringify(listing, null, 2) + "\n");

  // `language` and `endonym` rather than `name`, which on a listing is the app
  // name and would be clobbered by the spread below.
  const locale = LOCALES.find((l) => l.asc === asc);
  index[asc] = { file, language: locale?.name ?? asc, endonym: locale?.endonym, ...listing };

  rows.push(
    `<tr><td><a href="${file}">${asc}</a></td><td>${escape(locale?.name ?? "")}</td>` +
      `<td>${escape(String(listing.subtitle ?? ""))}</td>` +
      `<td class="kw">${escape(String(listing.keywords ?? ""))}</td></tr>`,
  );
}

await writeFile(join(OUT, "listing.json"), JSON.stringify(index, null, 2) + "\n");

const html = `<!doctype html>
<meta charset="utf-8">
<meta name="robots" content="noindex, nofollow">
<title>${APP} — localized listing</title>
<style>body{font:15px/1.6 -apple-system,system-ui,sans-serif;max-width:78rem;margin:3rem auto;padding:0 1.5rem;color:#26262b}
h1{font-size:1.4rem}table{border-collapse:collapse;width:100%;margin-top:1.5rem;font-size:13px}
th,td{border-bottom:1px solid #e5e5ea;padding:.5rem .6rem;text-align:left;vertical-align:top}
th{font-weight:600;background:#f7f7fa}.kw{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}
a{color:#0a58ca}</style>
<h1>Localized App Store listing — ${files.length} languages</h1>
<p>Every field that appears on the product page, one JSON file per App Store
locale. Machine-readable index: <a href="listing.json">listing.json</a>.
Screenshots and icon: <a href="../">press kit</a>.</p>
<table><thead><tr><th>Locale</th><th>Language</th><th>Subtitle</th><th>Keywords</th></tr></thead>
<tbody>
${rows.join("\n")}
</tbody></table>
`;
await writeFile(join(OUT, "index.html"), html);

console.log(`Listing: ${OUT}`);
console.log(`  ${files.length} locales + listing.json + index.html`);
