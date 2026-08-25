#!/usr/bin/env bun
/**
 * Pushes the localized listing and the localized screenshots to App Store
 * Connect.
 *
 * This is the script that removes the browser from the loop. Twenty-five
 * languages is a hundred text fields and three hundred images; doing that by
 * hand is not slow so much as unrepeatable — a listing built by clicking cannot
 * be diffed, re-run after a copy change, or restored after a mistake.
 *
 *   bun scripts/asc-push.ts                     # say what would change, write nothing
 *   bun scripts/asc-push.ts --apply             # do it
 *   bun scripts/asc-push.ts --apply --lang de,ja
 *   bun scripts/asc-push.ts --apply --metadata  # text only, no images
 *   bun scripts/asc-push.ts --apply --screenshots --replace
 *
 * Dry run is the default on purpose. The version this writes to is the one
 * that goes to review, and there is no undo.
 *
 * WHAT LIVES WHERE, WHICH THE API DOES NOT MAKE OBVIOUS
 * The listing is split across two resources that are not siblings and do not
 * version together:
 *
 *   appInfoLocalization       name, subtitle, privacyPolicyUrl
 *   appStoreVersionLocalization  description, keywords, promotionalText,
 *                                marketingUrl, supportUrl, whatsNew, screenshots
 *
 * Sending `subtitle` to the version localization is a 409 naming a field that
 * plainly exists — it exists on the other resource.
 */

import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { Client, body, type Resource } from "../lib/asc";
import { BASE as BASE_LOCALE, LOCALES } from "../lib/locales";

const APP_ID = JSON.parse(readFileSync("apple-project.json", "utf8")).appStoreConnect.appleId;
const METADATA = "appstore/metadata";
const SHOTS = "appstore/localized";

/**
 * Which capture directory feeds which App Store display type.
 *
 * The display types are wider than their names: `APP_IPHONE_67` takes both the
 * 6.7-inch 1290×2796 and the 6.9-inch 1320×2868 images, and
 * `APP_IPAD_PRO_3GEN_129` takes the 13-inch 2064×2752 as well as the 12.9-inch
 * 2048×2732. Apple did not add new types for the new sizes, so the names are
 * now historical and the mapping has to be written down rather than inferred.
 */
const DISPLAY_TYPES = {
  "iphone-6.9": "APP_IPHONE_67",
  "ipad-13": "APP_IPAD_PRO_3GEN_129",
} satisfies Record<string, string>;

/** Only on the version localization. `subtitle` is deliberately not here. */
const VERSION_FIELDS = [
  "description",
  "keywords",
  "promotionalText",
  "marketingUrl",
  "supportUrl",
  "whatsNew",
] as const;

/** Only on the app info localization. */
const INFO_FIELDS = ["subtitle", "privacyPolicyUrl"] as const;

const argv = process.argv.slice(2);
const flag = (n: string) => (argv.indexOf(n) >= 0 ? argv[argv.indexOf(n) + 1] : undefined);
const apply = argv.includes("--apply");
const replace = argv.includes("--replace");
const only = flag("--lang")?.split(",").map((s) => s.trim());
// Neither flag means both, which is the case you want almost every time.
const wantMetadata = argv.includes("--metadata") || !argv.includes("--screenshots");
const wantShots = argv.includes("--screenshots") || !argv.includes("--metadata");

const targets = LOCALES.filter((l) => !only || only.includes(l.ios) || only.includes(l.asc));

const client = new Client();
const changes: string[] = [];
const note = (s: string) => {
  changes.push(s);
  console.log(`${apply ? "  " : "  would "}${s}`);
};

// ---------------------------------------------------------------------------
// The editable version
// ---------------------------------------------------------------------------

/**
 * The one version that can still be written to.
 *
 * A live app has a released version and an editable one, and the API returns
 * both. Writing to the released one is not an error you get told about at the
 * time — the request succeeds against a resource nobody will ever look at.
 */
const EDITABLE = new Set([
  "PREPARE_FOR_SUBMISSION",
  "DEVELOPER_REJECTED",
  "REJECTED",
  "METADATA_REJECTED",
  "INVALID_BINARY",
]);

const versions = await client.all(`/v1/apps/${APP_ID}/appStoreVersions?limit=20`);
const version = versions.find((v) => EDITABLE.has(v.attributes?.appStoreState));
if (!version) {
  const states = versions.map((v) => `${v.attributes?.versionString} ${v.attributes?.appStoreState}`);
  console.error(`No editable version. Found: ${states.join(", ") || "none"}`);
  process.exit(1);
}
console.log(`${version.attributes!.versionString} · ${version.attributes!.appStoreState}\n`);

const appInfos = await client.all(`/v1/apps/${APP_ID}/appInfos`);
const appInfo = appInfos.find((i) => EDITABLE.has(i.attributes?.appStoreState)) ?? appInfos[0];

// ---------------------------------------------------------------------------
// Metadata
// ---------------------------------------------------------------------------

// SAFETY: every localization resource Apple returns from a `...Localizations`
// collection carries a `locale` string; a member without one would be a
// malformed collection, and the Map key would be `undefined` either way.
const byLocale = (rs: Resource[]) => new Map(rs.map((r) => [r.attributes!.locale as string, r]));

if (wantMetadata) {
  const versionLocs = byLocale(
    await client.all(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations?limit=50`),
  );
  const infoLocs = byLocale(await client.all(`/v1/appInfos/${appInfo.id}/appInfoLocalizations?limit=50`));

  // Creating an app info localization requires `name`, and a missing one is a
  // 409 rather than an inherited default. The app name is a brand and is the
  // same in every language, so the live English name is the name — read rather
  // than hardcoded, so renaming the app in App Store Connect does not silently
  // leave twenty-four languages listed under the old one.
  const appName = infoLocs.get(BASE_LOCALE.asc)?.attributes?.name;

  for (const locale of targets) {
    const path = join(METADATA, `${locale.asc}.json`);
    if (!existsSync(path)) {
      console.log(`  ${locale.asc.padEnd(8)} no metadata file, skipped`);
      continue;
    }
    const data = JSON.parse(readFileSync(path, "utf8"));

    // Version localization. Created if the language is new to the listing,
    // patched if it is not — the API has no upsert, and POSTing over an
    // existing locale is a 409 rather than an update.
    // Empty is not the same as unset. `whatsNew` is empty on a first release
    // and App Store Connect rejects the field outright on a version that has
    // never shipped, so an empty string has to be left out rather than sent.
    const versionAttrs = Object.fromEntries(
      VERSION_FIELDS.filter((f) => data[f]).map((f) => [f, data[f]]),
    );
    const existingVersion = versionLocs.get(locale.asc);
    if (existingVersion) {
      const differs = Object.entries(versionAttrs).filter(
        ([k, v]) => existingVersion.attributes![k] !== v,
      );
      if (differs.length) {
        note(`${locale.asc} update ${differs.map(([k]) => k).join(", ")}`);
        if (apply) {
          await client.patch(
            `/v1/appStoreVersionLocalizations/${existingVersion.id}`,
            body("appStoreVersionLocalizations", Object.fromEntries(differs), undefined, existingVersion.id),
          );
        }
      }
    } else {
      note(`${locale.asc} create listing`);
      if (apply) {
        const created = await client.post(
          "/v1/appStoreVersionLocalizations",
          body("appStoreVersionLocalizations", { locale: locale.asc, ...versionAttrs }, {
            appStoreVersion: { data: { type: "appStoreVersions", id: version.id } },
          }),
        );
        versionLocs.set(locale.asc, created.data);
      }
    }

    // App info localization. `name` is only sent for languages other than the
    // base: renaming the primary language renames the app.
    const infoAttrs = Object.fromEntries(
      INFO_FIELDS.filter((f) => data[f]).map((f): [string, string] => [f, data[f]]),
    );
    if (locale.asc !== BASE_LOCALE.asc) infoAttrs.name = data.name ?? appName;

    if (!Object.keys(infoAttrs).length) continue;
    // Creating the version localization creates the app info localization for
    // the same language as a side effect, which the map read before the loop
    // does not know about — so a language that looked new a moment ago is a 409
    // by the time it is asked for. Re-read rather than assume either way.
    if (apply && !infoLocs.has(locale.asc)) {
      const fresh = await client.all(
        `/v1/appInfos/${appInfo.id}/appInfoLocalizations?filter[locale]=${locale.asc}`,
      );
      if (fresh[0]) infoLocs.set(locale.asc, fresh[0]);
    }
    const existingInfo = infoLocs.get(locale.asc);
    if (existingInfo) {
      const differs = Object.entries(infoAttrs).filter(([k, v]) => existingInfo.attributes![k] !== v);
      if (differs.length) {
        note(`${locale.asc} update ${differs.map(([k]) => k).join(", ")}`);
        if (apply) {
          await client.patch(
            `/v1/appInfoLocalizations/${existingInfo.id}`,
            body("appInfoLocalizations", Object.fromEntries(differs), undefined, existingInfo.id),
          );
        }
      }
    } else {
      note(`${locale.asc} create app info`);
      if (apply) {
        await client.post(
          "/v1/appInfoLocalizations",
          body("appInfoLocalizations", { locale: locale.asc, ...infoAttrs }, {
            appInfo: { data: { type: "appInfos", id: appInfo.id } },
          }),
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Screenshots
// ---------------------------------------------------------------------------

/**
 * Uploads one image.
 *
 * Three calls, and all three are required. Reserving the asset returns a list
 * of upload operations — Apple chunks large files, so this is a list and not a
 * URL — and an asset that is uploaded but never committed with its checksum
 * sits in the set forever as "processing" and blocks submission with an error
 * that points at the screenshot rather than at the missing PATCH.
 */
async function upload(setId: string, file: string) {
  const bytes = readFileSync(file);
  const fileName = file.split("/").pop()!;

  const reserved = await client.post(
    "/v1/appScreenshots",
    body("appScreenshots", { fileSize: statSync(file).size, fileName }, {
      appScreenshotSet: { data: { type: "appScreenshotSets", id: setId } },
    }),
  );
  const asset = reserved.data;

  for (const op of asset.attributes.uploadOperations ?? []) {
    const headers = Object.fromEntries(
      (op.requestHeaders ?? []).map((h: any) => [h.name, h.value]),
    );
    const res = await fetch(op.url, {
      method: op.method,
      headers,
      body: bytes.subarray(op.offset, op.offset + op.length),
    });
    if (!res.ok) throw new Error(`upload ${fileName} → ${res.status} ${await res.text()}`);
  }

  await client.patch(
    `/v1/appScreenshots/${asset.id}`,
    body(
      "appScreenshots",
      { uploaded: true, sourceFileChecksum: createHash("md5").update(bytes).digest("hex") },
      undefined,
      asset.id,
    ),
  );
  // SAFETY: `asset` is the resource this function just created via POST, and
  // every App Store Connect resource comes back with an `id`.
  return asset.id as string;
}

if (wantShots) {
  const versionLocs = byLocale(
    await client.all(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations?limit=50`),
  );

  for (const locale of targets) {
    const localization = versionLocs.get(locale.asc);
    if (!localization) {
      // Only reachable on a dry run, where the localization was never created.
      console.log(`  ${locale.asc.padEnd(8)} no listing yet, screenshots skipped`);
      continue;
    }

    const sets = new Map(
      (await client.all(`/v1/appStoreVersionLocalizations/${localization.id}/appScreenshotSets`)).map(
        // SAFETY: a screenshot set exists only for a display type, so the
        // attribute is present on every member of this collection.
        (s) => [s.attributes!.screenshotDisplayType as string, s],
      ),
    );

    for (const [device, displayType] of Object.entries(DISPLAY_TYPES)) {
      const dir = join(SHOTS, locale.asc, device);
      if (!existsSync(dir)) continue;
      // Sorted by name, which is why the capture writes an ordinal prefix: the
      // order in this array is the order on the product page, and the API does
      // not sort anything for you.
      const files = readdirSync(dir).filter((f) => f.endsWith(".png")).sort();
      if (!files.length) continue;

      let set = sets.get(displayType);
      const existing = set
        ? await client.all(`/v1/appScreenshotSets/${set.id}/appScreenshots`)
        : [];

      if (existing.length && !replace) {
        console.log(`  ${locale.asc.padEnd(8)} ${device.padEnd(11)} ${existing.length} already there, kept`);
        continue;
      }

      note(`${locale.asc} ${device} ${files.length} screenshots${existing.length ? ` (replacing ${existing.length})` : ""}`);
      if (!apply) continue;

      for (const old of existing) await client.delete(`/v1/appScreenshots/${old.id}`);

      if (!set) {
        const created = await client.post(
          "/v1/appScreenshotSets",
          body("appScreenshotSets", { screenshotDisplayType: displayType }, {
            appStoreVersionLocalization: {
              data: { type: "appStoreVersionLocalizations", id: localization.id },
            },
          }),
        );
        set = created.data;
        sets.set(displayType, set!);
      }

      const ids: string[] = [];
      for (const f of files) ids.push(await upload(set!.id, join(dir, f)));

      // Uploads finish out of order often enough that this is not optional.
      // The set's relationship is the display order, and it is the only way to
      // set it.
      await client.patch(`/v1/appScreenshotSets/${set!.id}/relationships/appScreenshots`, {
        data: ids.map((id) => ({ type: "appScreenshots", id })),
      });
    }
  }
}

console.log(
  `\n${changes.length} change${changes.length === 1 ? "" : "s"}${apply ? " applied" : " — dry run, nothing written. Add --apply."}`,
);
