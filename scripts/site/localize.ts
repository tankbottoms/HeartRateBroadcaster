#!/usr/bin/env bun
/**
 * Fills the empty translation slots in the String Catalogs.
 *
 * `catalog.ts` extracts the strings and opens a slot per language; this fills
 * the ones still marked `"state": "new"` and leaves everything else alone. That
 * is the whole idempotency story — run it as often as you like, and it only
 * ever touches what has never been translated. Reviewed strings are never
 * overwritten, so a human correction survives the next run.
 *
 * Machine output is written as `needs_review`, not `translated`. That is Xcode's
 * own state for exactly this situation: the string ships and the app is in the
 * user's language, but the catalog records honestly that no human has read it.
 * Promoting a language to `translated` is a separate, deliberate act.
 *
 *   bun scripts/localize.ts                    # fill every empty slot
 *   bun scripts/localize.ts --lang de,fr,ja    # only these
 *   bun scripts/localize.ts --dry-run          # translate, validate, write nothing
 *   bun scripts/localize.ts --retranslate de   # redo de, including needs_review
 *
 * The model and endpoint live in translator.ts, shared with the website.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { LOCALES, BASE, type Locale } from "../lib/locales";
import { repairSpecifiers, translate, validate } from "../lib/translator";
import { message } from "../lib/errors";

/**
 * The same list catalog.ts opens the slots in, read from the one place that
 * knows it. Keeping a second copy here is how a newly added catalog ends up
 * with empty slots that nothing ever fills.
 */
const CATALOGS: string[] = JSON.parse(
  readFileSync("apple-project.json", "utf8"),
).paths.stringCatalogs.map((c: { path: string }) => c.path);

/** Small enough that one bad string doesn't cost the batch, big enough to be fast. */
const BATCH = 20;

/**
 * How many languages are in flight at once. The endpoint is a single GPU, so
 * this is about keeping its queue full rather than about parallelism — past
 * four, requests just wait in a different place, and the failure modes get
 * harder to read.
 */
const LANES = Number(process.env.LOCALIZE_LANES ?? 4);

interface Unit { state: string; value: string }
interface Entry {
  extractionState?: string;
  comment?: string;
  localizations?: Record<string, { stringUnit?: Unit }>;
}
interface Catalog { sourceLanguage: string; strings: Record<string, Entry>; version: string }

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};
const dryRun = argv.includes("--dry-run");
const only = flag("--lang")?.split(",").map((s) => s.trim());
const retranslate = flag("--retranslate")?.split(",").map((s) => s.trim()) ?? [];

const targets = LOCALES.filter(
  (l) => l.ios !== BASE.ios && (!only || only.includes(l.ios) || only.includes(l.asc)),
);

/** Runs `work` over `items`, `lanes` at a time, preserving nothing but order of completion. */
async function pool<T>(items: T[], lanes: number, work: (item: T) => Promise<void>) {
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(lanes, items.length) }, async () => {
      while (next < items.length) await work(items[next++]);
    }),
  );
}

let filled = 0;
let rejected = 0;

for (const path of CATALOGS) {
  const catalog: Catalog = JSON.parse(readFileSync(path, "utf8"));
  const keys = Object.keys(catalog.strings);
  if (!keys.length) continue;
  const label = path.split("/")[0];

  await pool(targets, LANES, async (locale: Locale) => {
    const redo = retranslate.includes(locale.ios) || retranslate.includes(locale.asc);
    const source = (k: string) => catalog.strings[k].localizations?.[BASE.ios]?.stringUnit?.value ?? k;

    const todo = keys.filter((k) => {
      // A key with no text in it has nothing to translate, and asking a model
      // for the empty string in Polish gets an apology back.
      if (!source(k).trim()) return false;
      const unit = catalog.strings[k].localizations?.[locale.ios]?.stringUnit;
      if (!unit) return false;
      return redo ? unit.state !== "translated" : unit.state === "new" || !unit.value;
    });
    if (!todo.length) return;

    let ok = 0;
    let bad = 0;

    /// Translates a slice, halving it and trying again when the whole thing
    /// comes back unusable.
    ///
    /// The failures this is for are not per-string — they are `JSON Parse error:
    /// Expected ']'` and `asked for 20 strings, got 19`, which are what a reply
    /// that ran out of tokens or lost count looks like. Three retries at the
    /// same size reproduce the same failure three times; six languages sat at
    /// 0/20 across two full runs for exactly that reason. Half the batch is a
    /// different question, and usually an answerable one.
    ///
    /// Down to one string, so a batch can never be lost to a single bad member.
    const run = async (slice: string[], depth = 0): Promise<void> => {
      const sources = slice.map(source);

      let out: string[];
      try {
        out = await translate(sources, locale, {
          kind: "interface",
          comments: slice.map((k) => catalog.strings[k].comment),
        });
      } catch (e) {
        if (slice.length > 1) {
          const half = Math.ceil(slice.length / 2);
          await run(slice.slice(0, half), depth + 1);
          await run(slice.slice(half), depth + 1);
          return;
        }
        console.error(`  ${locale.ios} ${label} ${JSON.stringify(sources[0]).slice(0, 40)}: ${message(e)}`);
        bad += 1;
        return;
      }

      slice.forEach((key, n) => {
        // Repair before validating, not instead of it: the repair only touches
        // a translation whose specifier count already matches, and whatever it
        // hands back still has to pass every other check.
        out[n] = typeof out[n] === "string" ? repairSpecifiers(sources[n], out[n]) : out[n];
        const problem = validate(sources[n], out[n]);
        if (problem) {
          // Left as "new" on purpose: a slot that failed validation should be
          // retried by the next run, not shipped and not silently skipped.
          console.error(`  ${locale.ios} ${JSON.stringify(sources[n]).slice(0, 44)}: ${problem}`);
          bad++;
          return;
        }
        // Mutating the shared catalog from four lanes is safe here: each lane
        // owns one language, and no two lanes ever touch the same slot.
        if (!dryRun) {
          catalog.strings[key].localizations![locale.ios]!.stringUnit = {
            state: "needs_review",
            value: out[n],
          };
        }
        ok++;
      });
    };

    for (let i = 0; i < todo.length; i += BATCH) await run(todo.slice(i, i + BATCH));

    filled += ok;
    rejected += bad;
    console.log(`${locale.ios.padEnd(8)} ${label.padEnd(26)} ${ok}/${todo.length}${bad ? ` · ${bad} rejected` : ""}`);
  });

  if (!dryRun) writeFileSync(path, JSON.stringify(catalog, null, 2) + "\n");
}

console.log(
  `\n${filled} translated${rejected ? `, ${rejected} left for the next run` : ""}${dryRun ? " (dry run, nothing written)" : ""}`,
);
