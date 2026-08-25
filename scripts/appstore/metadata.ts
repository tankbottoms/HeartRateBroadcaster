#!/usr/bin/env bun
/**
 * Translates the App Store listing into every language.
 *
 * `appstore/metadata/en-US.json` is the English listing and the only file
 * anyone edits. This writes `appstore/metadata/<asc>.json` for the other
 * twenty-four, keyed by App Store Connect's locale codes rather than iOS's —
 * they disagree on six of the twenty-five, and the difference is silent.
 *
 * The character limits are the reason this is a script and not a spreadsheet.
 * App Store Connect rejects an overlong subtitle at upload time with a message
 * that names the field and not the language, and German is reliably a third
 * longer than English. Every field is measured, and anything over is sent back
 * to the model with the limit stated until it fits.
 *
 *   bun scripts/metadata.ts              # fill what is missing
 *   bun scripts/metadata.ts --lang de,ja
 *   bun scripts/metadata.ts --retranslate de
 *
 * Uploading these is `scripts/asc-push.ts`. This only writes files.
 */

import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { BASE, LOCALES, type Locale } from "../lib/locales";
import { translate, validate } from "../lib/translator";
import { message } from "../lib/errors";

const DIR = "appstore/metadata";

/**
 * App Store Connect's limits, in characters. Exceeding one is a 409 at upload
 * with no partial write, so the whole language fails on one long word.
 */
/** Field name -> its ceiling in characters. Looked up by a runtime string. */
type Limits = Record<string, number>;

const LIMITS = {
  subtitle: 30,
  promotionalText: 170,
  keywords: 100,
  description: 4000,
  whatsNew: 4000,
} satisfies Limits;

/** Fields that are prose or search terms. The URLs are the same everywhere. */
const FIELDS = ["subtitle", "promotionalText", "description", "keywords"] as const;

const CONTEXT = {
  subtitle:
    "App Store subtitle, at most 30 characters including spaces. It sits under the app name in search results. Shorter than the English if the language needs it — drop words rather than run over.",
  promotionalText:
    "App Store promotional text, at most 170 characters. The first thing someone reads on the product page.",
  description:
    "Full App Store description. Keep the blank lines and the all-capitals section headings exactly where they are; capitalise the headings the way this language does, or leave them capitalised if it has no case.",
  keywords:
    "App Store search keywords: a comma-separated list, no spaces after the commas, at most 100 characters in total. These are search terms, not a sentence — translate each term into what someone would actually type in this language, drop any that do not translate, and keep the brand names as they are. Fewer good terms beat a truncated list.",
} satisfies Record<(typeof FIELDS)[number], string>;

const argv = process.argv.slice(2);
const flag = (n: string) => (argv.indexOf(n) >= 0 ? argv[argv.indexOf(n) + 1] : undefined);
const only = flag("--lang")?.split(",").map((s) => s.trim());
const redo = flag("--retranslate")?.split(",").map((s) => s.trim()) ?? [];

const english = JSON.parse(readFileSync(join(DIR, `${BASE.asc}.json`), "utf8"));
const targets = LOCALES.filter(
  (l) => l.asc !== BASE.asc && (!only || only.includes(l.ios) || only.includes(l.asc)),
);

/** Counts the way App Store Connect counts: characters, not bytes, not glyphs. */
const len = (s: string) => [...s].length;

/**
 * Trims a keyword list to the limit by dropping whole terms from the end.
 *
 * Deterministic on purpose. Keywords are a comma-separated list with no
 * grammar, so the shortest correct answer is fewer of them — and asking a model
 * to "make this shorter" reliably returns a list that is shorter by rewriting
 * the terms into ones nobody searches for. The order in the English file is the
 * priority order, so the terms that fall off are the ones that matter least.
 */
function trimKeywords(value: string, limit: number) {
  const terms = value.split(",").map((t) => t.trim()).filter(Boolean);
  while (terms.length > 1 && len(terms.join(",")) > limit) terms.pop();
  return terms.join(",");
}

/**
 * Rewrites a field until it fits, up to three attempts.
 *
 * Translating the over-long translation was the first attempt at this and it
 * does not work: handing German text to a translator that has been told to
 * translate into German produces the same sentence back, and every subtitle in
 * the run came out fifty characters against a limit of thirty. So the source is
 * always the English, the budget is stated as the primary instruction, and each
 * attempt asks for a little less than the one before — the shortfall is usually
 * a few characters, and a model that has just missed by two will sail past if
 * you simply ask again for the same number.
 *
 * Three, because the first attempt fails for a language with long compounds,
 * the second usually lands, and a third that also misses is a subtitle that
 * needs a human rather than another minute.
 */
async function fit(field: string, english: string, value: string, limit: number, locale: Locale) {
  // Five at a time rather than five in a row. The model is not bad at being
  // brief, it is bad at counting — asked once for thirty characters it returns
  // thirty-four, and asked again it returns thirty-four again, because nothing
  // about the second request is different. Asking for five phrasings of varying
  // aggression in one call and measuring them here puts the counting on the
  // side that can count.
  const angles = [
    `at most ${limit} characters`,
    `at most ${limit - 4} characters — drop any word that is not load-bearing`,
    `at most ${limit - 8} characters — a noun phrase, not a sentence`,
    `as few words as possible while still naming what the app does`,
    `two or three words, the way this language would label a product category`,
  ];

  let best = value;
  for (let round = 0; round < 2; round++) {
    let out: string[];
    try {
      out = await translate(angles.map(() => english), locale, {
        kind: "marketing",
        comments: angles.map(
          (a) =>
            `App Store ${field} in ${locale.name}: ${a}, including spaces. ` +
            `Meaning over literalness — say the same thing shorter, do not translate word for word. ` +
            `Reply with the ${locale.name} text only, no quotes.`,
        ),
      });
    } catch {
      continue;
    }
    const fits = out
      .filter((s): s is string => typeof s === "string" && !!s.trim() && !validate(english, s))
      .sort((a, b) => len(b) - len(a));
    // The longest that fits, not the shortest: a two-word subtitle is within
    // the limit and tells nobody anything. The limit is the constraint; length
    // is the thing being maximised under it.
    const winner = fits.find((s) => len(s) <= limit);
    if (winner) return winner;
    const closest = fits.at(-1);
    if (closest && len(closest) < len(best)) best = closest;
  }
  return best;
}

/**
 * Drops whole sentences from the end until the text fits.
 *
 * The last resort for prose, and a good one: promotional text is two or three
 * independent sentences, and losing the last is a smaller loss than a paragraph
 * cut off mid-word. Only used when the model has been asked twice and is still
 * over — never in place of asking, because a shorter rewrite beats a truncation
 * every time it is available.
 */
function trimSentences(value: string, limit: number) {
  // Latin, CJK and Arabic full stops. A language whose sentences this does not
  // split simply comes back unchanged and is reported, which is the honest
  // outcome — better than cutting Thai at an arbitrary character.
  const parts = value.split(/(?<=[.!?。！？؟])\s*/).filter(Boolean);
  while (parts.length > 1 && len(parts.join(" ")) > limit) parts.pop();
  const out = parts.join(" ").trim();
  return len(out) <= limit ? out : value;
}

let wrote = 0;
const short: string[] = [];

for (const locale of targets) {
  const path = join(DIR, `${locale.asc}.json`);
  const existing = existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : {};
  const force = redo.includes(locale.ios) || redo.includes(locale.asc);
  // Over the limit counts as missing. App Store Connect rejects the whole
  // language on one long subtitle, so a file that is present but unshippable is
  // worse than one that is absent — and re-running the script is the obvious
  // thing to do about it, which only helps if re-running fixes it.
  const todo = FIELDS.filter(
    (f) => force || !existing[f] || (LIMITS[f] && len(existing[f]) > LIMITS[f]),
  );
  if (!todo.length) continue;

  // Only the fields with nothing usable go through the translator; a field that
  // is merely too long already has a translation, and the shortening pass is a
  // different question from the translation.
  const fresh = todo.filter((f) => force || !existing[f]);
  let out: string[] = [];
  if (fresh.length) {
    try {
      out = await translate(fresh.map((f) => english[f]), locale, {
        kind: "marketing",
        comments: fresh.map((f) => CONTEXT[f]),
      });
    } catch (e) {
      console.error(`${locale.asc}: ${message(e)}`);
      continue;
    }
  }

  const result = { ...existing };
  for (const field of todo) {
    const i = fresh.indexOf(field);
    let value = i >= 0 ? out[i] : existing[field];
    const problem = validate(english[field], value);
    if (problem) {
      console.error(`${locale.asc} ${field}: ${problem}`);
      continue;
    }
    const limit = LIMITS[field];
    if (limit && len(value) > limit) {
      value = field === "keywords"
        ? trimKeywords(value, limit)
        : await fit(field, english[field], value, limit, locale);
      // Prose that survived two rounds of rewriting loses its last sentence
      // rather than the whole language.
      if (len(value) > limit && field !== "subtitle") value = trimSentences(value, limit);
      if (len(value) > limit) {
        // Written anyway, and reported. A field that is 32 characters when the
        // limit is 30 is two characters of a human's attention; silently
        // dropping it would leave the language half-listed with no sign why.
        short.push(`${locale.asc} ${field}: ${len(value)}/${limit}`);
      }
    }
    result[field] = value;
  }

  // The URLs and the product name are identical in every language, so they are
  // carried across rather than translated — a translated support URL is a 404.
  for (const k of ["marketingUrl", "supportUrl", "privacyPolicyUrl", "whatsNew"]) {
    if (english[k] !== undefined) result[k] = english[k];
  }
  result._source = `Machine-translated from ${BASE.asc} by scripts/metadata.ts. Not reviewed by a speaker.`;

  writeFileSync(path, JSON.stringify(result, null, 2) + "\n");
  wrote++;
  console.log(`${locale.asc.padEnd(8)} ${todo.join(", ")}`);
}

const have = readdirSync(DIR).filter((f) => f.endsWith(".json")).length;
console.log(`\n${wrote} written, ${have}/${LOCALES.length} languages on disk`);
if (short.length) {
  console.log("\nOver the App Store limit — these need a human to cut:");
  for (const s of short) console.log(`  ${s}`);
}
