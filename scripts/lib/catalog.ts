#!/usr/bin/env bun
/**
 * Extracts every localizable string from source, then keeps each catalog's
 * language list equal to `locales.ts`.
 *
 * Xcode will happily create an `.xcstrings` file itself, but only for the
 * languages someone remembered to tick in the target editor, and only on the
 * machine that ticked them. Twenty-five languages across three catalogs is 75
 * checkboxes and no way to review the result in a diff. This does it from the
 * one list instead, so adding a language is a one-line change to `locales.ts`.
 *
 * What it does *not* do is invent translations. A catalog entry with no
 * translation is `"state": "new"`, which is exactly what Xcode writes for a
 * string it has just extracted, and exactly what `localize.ts` looks for.
 * Running this on an existing catalog preserves every translation already in it.
 *
 *   bun scripts/catalog.ts             # build, extract, sync, add slots
 *   bun scripts/catalog.ts --no-build  # skip the build, just fix the slots
 *   bun scripts/catalog.ts --prune     # also drop languages no longer in locales.ts
 */

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BASE, IOS_CODES, LOCALES } from "./locales";

/**
 * The project's own facts, not this script's. Which catalogs exist, which target
 * feeds each one, and what the project is called all live in apple-project.json,
 * so this file names nothing and can be copied into another project unchanged.
 *
 * Each catalog belongs to exactly one target — see the comments on the
 * `stringCatalogs` block for why they are not merged into one shared file.
 */
const PATHS = JSON.parse(readFileSync("apple-project.json", "utf8")).paths;

const CATALOGS: { path: string; what: string; target: string | null }[] = PATHS.stringCatalogs;

/**
 * One build per platform. The strings are a by-product: `SWIFT_EMIT_LOC_STRINGS`
 * makes the compiler write a `.stringsdata` beside each object file, listing
 * every `LocalizedStringKey` and `String(localized:)` it *type-checked*.
 *
 * That type-awareness is the whole reason this is a build and not a text scan.
 * `xcstringstool extract` parses Swift "lightweightly" and only recognises the
 * shapes it knows — it would miss every literal we pass to a component whose
 * parameter we declared as `LocalizedStringKey`, which is most of the app.
 */
const BUILDS: { scheme: string; destination: string }[] = PATHS.builds;

interface Unit {
  stringUnit?: { state: string; value: string };
  variations?: unknown;
}
interface Entry {
  extractionState?: string;
  comment?: string;
  localizations?: Record<string, Unit>;
}
interface Catalog {
  sourceLanguage: string;
  strings: Record<string, Entry>;
  version: string;
}

const prune = process.argv.includes("--prune");
const noBuild = process.argv.includes("--no-build");
const wanted = new Set(IOS_CODES);

function run(cmd: string, args: string[]) {
  const r = spawnSync(cmd, args, { encoding: "utf8" });
  if (r.status !== 0) {
    // xcodebuild's useful line is usually a long way from the end of stdout,
    // so print the tail of both rather than a bare exit code.
    console.error(r.stdout?.split("\n").slice(-40).join("\n"));
    console.error(r.stderr);
    throw new Error(`${cmd} exited ${r.status}`);
  }
  return r.stdout;
}

/** Every `.stringsdata` a target's compiler wrote, one per source file. */
function stringsData(root: string, target: string): string[] {
  const found = new Map<string, string>();
  const walk = (dir: string) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, e.name);
      if (e.isDirectory()) walk(p);
      // The watch builds twice, arm64 and arm64_32, and the two agree by
      // construction. Keying on the file name keeps one of each.
      else if (e.name.endsWith(".stringsdata")) found.set(e.name, p);
    }
  };
  const base = join(root, PATHS.derivedBuildDir);
  if (!existsSync(base)) return [];
  for (const config of readdirSync(base)) {
    const dir = join(base, config, `${target}.build`);
    if (existsSync(dir)) walk(dir);
  }
  return [...found.values()];
}

let derived: string | null = null;
try {
  if (!noBuild) {
    derived = mkdtempSync(join(tmpdir(), "xcstrings-"));
    for (const { scheme, destination } of BUILDS) {
      console.log(`building ${scheme} for ${destination}`);
      run("xcodebuild", [
        "-project", PATHS.xcodeproj,
        "-scheme", scheme,
        "-destination", destination,
        "-derivedDataPath", derived,
        "-configuration", "Debug",
        "CODE_SIGNING_ALLOWED=NO",
        "build",
      ]);
    }
    for (const { path, target, what } of CATALOGS) {
      if (!target) continue;
      const data = stringsData(derived, target);
      if (!data.length) throw new Error(`no .stringsdata for ${target} — did the build run?`);
      run("xcrun", [
        "xcstringstool", "sync", path,
        // Without this, every string not seen in *this* build is marked stale.
        // Both catalogs of a shared source file would fight over that.
        "--skip-marking-strings-stale",
        "--stringsdata", ...data,
      ]);
      console.log(`  synced ${data.length} file${data.length === 1 ? "" : "s"} → ${what}`);
    }
  }

for (const { path, what } of CATALOGS) {
  const catalog: Catalog = existsSync(path)
    ? JSON.parse(readFileSync(path, "utf8"))
    : { sourceLanguage: BASE.ios, strings: {}, version: "1.0" };

  // A catalog whose source language disagrees with ours would silently treat
  // English entries as translations of something else.
  if (catalog.sourceLanguage !== BASE.ios) {
    throw new Error(`${path}: sourceLanguage is ${catalog.sourceLanguage}, expected ${BASE.ios}`);
  }

  let added = 0;
  let removed = 0;

  // `xcstringstool sync` adds and marks stale but never deletes — Xcode does
  // that when a human saves the catalog. Nobody is going to open five catalogs
  // to delete a key that only exists because some Swift expression had a `?? ""`
  // in it, so it goes here.
  for (const [key, entry] of Object.entries(catalog.strings)) {
    if (!key.trim() || entry.extractionState === "stale") {
      delete catalog.strings[key];
      removed++;
    }
  }

  for (const entry of Object.values(catalog.strings)) {
    entry.localizations ??= {};
    for (const locale of LOCALES) {
      if (locale.ios === BASE.ios) continue;
      if (!entry.localizations[locale.ios]) {
        // "new" is Xcode's own word for extracted-but-untranslated. Writing an
        // empty string with state "translated" would look done and ship blank.
        entry.localizations[locale.ios] = { stringUnit: { state: "new", value: "" } };
        added++;
      }
    }
    if (prune) {
      for (const code of Object.keys(entry.localizations)) {
        if (code !== BASE.ios && !wanted.has(code)) {
          delete entry.localizations[code];
          removed++;
        }
      }
    }
  }

  writeFileSync(path, JSON.stringify(catalog, null, 2) + "\n");
  const total = Object.keys(catalog.strings).length;
  console.log(
    `${path}  ${total} string${total === 1 ? "" : "s"} · +${added} slot${added === 1 ? "" : "s"}` +
      (removed ? ` · -${removed}` : "") +
      `  (${what})`,
  );
}
} finally {
  // A DerivedData tree for this project is roughly a gigabyte. It exists only
  // to carry the .stringsdata out of the compiler, and nothing downstream reads
  // it, so it goes even when the build above failed.
  if (derived) rmSync(derived, { recursive: true, force: true });
}
