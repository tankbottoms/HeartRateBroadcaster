#!/usr/bin/env bun
/**
 * The one place that talks to a translation model.
 *
 * Shared by `localize.ts` (String Catalogs) and `site.ts` (the marketing page)
 * so that the app and the website cannot end up using different words for the
 * same thing in the same language — which is what happens when two scripts each
 * grow their own prompt.
 */

import { readFileSync } from "node:fs";
import type { Locale } from "./locales";

const PROJECT = JSON.parse(readFileSync("apple-project.json", "utf8"));

/**
 * A 35B local model, chosen over the smaller shared pools because those route
 * to an 8B whose German came back as "Streamend an", and over the Gemma builds
 * because this is the only one that reliably left the product name alone.
 * About a second per batch of twenty.
 *
 * The endpoint is an address on a private network, so it lives in the
 * gitignored apple-project.json alongside the other machine-specific values
 * rather than in this file. LOCALIZE_URL overrides it for a single run; the
 * localhost default is what a fresh clone gets, and it is meant to fail
 * loudly rather than to silently reach someone else's machine.
 */
export const URL =
  process.env.LOCALIZE_URL ??
  PROJECT.tooling?.localizeUrl ??
  "http://127.0.0.1:8080/v1/chat/completions";
export const MODEL = process.env.LOCALIZE_MODEL ?? "qwen3.6-35b-a3b";
const KEY = process.env.LOCALIZE_KEY;

/**
 * Names that must survive translation. Every one of these has been mangled by
 * some model in testing — the Japanese run turned the app's own name into
 * 心拍数ブロードキャスター, which is a reasonable translation of the words and a
 * useless thing to show someone looking for the app they installed.
 */
export const KEEP = [
  // The app's own name and its publisher, from the one file that knows them.
  // Both spacings of the name are listed because both appear in the strings and
  // a model will happily translate whichever one it was not told about.
  PROJECT.app.name,
  PROJECT.app.name.replace(/([a-z])([A-Z])/g, "$1 $2"),
  PROJECT.site?.publisher,
  // Everything below is Apple's or the industry's, and is the same in every
  // project — which is why it is spelled out here rather than configured.
  "Apple Watch",
  "AirPods",
  "AirPods Pro",
  "iPhone",
  "iPad",
  "Bluetooth",
  "HealthKit",
  "Live Activity",
  "Dynamic Island",
  "Picture in Picture",
  "ANT+",
  "MyWhoosh",
  "Zwift",
  "Garmin",
  "Wahoo",
  // A project with no marketing site has no publisher to protect, and a name
  // with no internal capital yields the same string twice. Both are dropped
  // here rather than special-cased above.
].filter((n, i, all): n is string => Boolean(n) && all.indexOf(n) === i);

/**
 * Every `%…` conversion specifier, in order of appearance.
 *
 * Two things here exist only to stop prose being mistaken for code, because a
 * percent sign in a sentence used to fail every language at once:
 *
 *   `(?<![0-9])` — `%o` is a real specifier (octal), so "About 24% of what you
 *   burn" reads as one, and every translation then "loses a placeholder"
 *   because the word after the percent sign is not "of" in German. A `%`
 *   directly after a digit is a percentage. A specifier never begins that way:
 *   its own digits come after the `%`, not before it.
 *
 *   no space — a space is a legal printf flag (`% d`, meaning "pad positive
 *   numbers"), and it was also, by what looks like a typo, in the conversion
 *   set. Between them, "24 % de" in French and "24 % av" in Swedish both
 *   matched. Nothing in this project's strings has ever used the space flag —
 *   checked — and half the world writes a space before the percent sign, so
 *   prose wins the ambiguity.
 *
 * `%%` is matched first and exempt from the digit guard, because an escaped
 * literal percent is written `100%%` — digit and all — and has to stay one
 * token rather than being read as a `%` plus whatever word follows.
 */
const SPECIFIER = /%%|(?<![0-9])%(?:\d+\$)?[-+#0]*[\d.*]*(?:hh?|ll?|q|L|z|j|t)?[@diouxXeEfgGaAcspn%]/g;

export const specifiers = (s: string) => s.match(SPECIFIER) ?? [];

/** Every HTML tag, normalised to just the tag name, in order of appearance. */
export const tags = (s: string) => (s.match(/<\/?([a-z][a-z0-9]*)\b/gi) ?? []).map((t) => t.toLowerCase());

/**
 * A translation that drops a placeholder does not fail at build time — it fails
 * at run time, in a language nobody on this team reads, with a crash or a
 * literal "%@" on screen. Same for a dropped tag on the website, which silently
 * unstyles a paragraph or swallows a link. So both are checked here rather than
 * trusted.
 */
/**
 * Puts the source's conversion specifiers back, when a translation kept the
 * right number of them but changed what they are.
 *
 * The recurring case is `%llds ago` coming back as `%@ Sekunden`: the sentence
 * is right, the slot is in the right place, and the type is wrong — which would
 * format a boxed integer through `%@` and print something like `Optional(4)`,
 * or crash. Rewriting positionally is safe precisely because the count matches;
 * a translation that reordered its slots would have to reorder the specifiers
 * too, and that is caught by the count check in `validate`.
 *
 * Deliberately narrow: same count, different tokens. Anything else is a
 * translation to reject, not to repair.
 */
export function repairSpecifiers(source: string, out: string): string {
  const want = specifiers(source);
  const got = specifiers(out);
  if (want.length !== got.length || !want.length) return out;

  let i = 0;
  return out.replace(SPECIFIER, () => want[i++] ?? "");
}

export function validate(source: string, out: unknown): string | null {
  if (typeof out !== "string" || !out.trim()) return "empty";

  const wantSpec = specifiers(source).slice().sort().join(",");
  const gotSpec = specifiers(out).slice().sort().join(",");
  if (wantSpec !== gotSpec) return `placeholders ${wantSpec || "none"} became ${gotSpec || "none"}`;

  const wantTags = tags(source).slice().sort().join(",");
  const gotTags = tags(out).slice().sort().join(",");
  if (wantTags !== gotTags) return `tags ${wantTags || "none"} became ${gotTags || "none"}`;

  const wantInflect = (source.match(/\^\[/g) ?? []).length;
  const gotOpen = (out.match(/\^\[/g) ?? []).length;
  const gotClose = (out.match(/\]\(inflect: true\)/g) ?? []).length;
  if (wantInflect !== gotOpen || gotOpen !== gotClose) return "inflection markup broken";

  // A paragraph that comes back as a sentence is a summary, not a translation.
  // It happens on long inputs and it is invisible afterwards: the file is
  // present, the JSON is valid, and one language quietly ships a third of the
  // description. A quarter is well under any real ratio — Chinese and Japanese
  // run about forty per cent of the English, and nothing runs below that — so
  // this only ever fires on a translation that gave up.
  if ([...source].length > 200 && [...out].length * 4 < [...source].length) {
    return `${[...out].length} characters against ${[...source].length}: a summary, not a translation`;
  }

  return null;
}

/** Generous for a batch of twenty, short enough that a stall is not a hang. */
const TIMEOUT_MS = Number(process.env.LOCALIZE_TIMEOUT_MS ?? 90_000);

/** Retries a timeout or a 5xx, because both are usually the queue and not us. */
async function withRetry<T>(fn: () => Promise<T>, attempts = 3): Promise<T> {
  let last: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (e) {
      last = e;
      if (i < attempts - 1) await new Promise((r) => setTimeout(r, 1000 * 2 ** i));
    }
  }
  throw last;
}

export interface Job {
  /** What is being translated, so the prompt can set the right register. */
  kind: "interface" | "marketing";
  /** Optional per-string context for the translator, aligned with `batch`. */
  comments?: (string | undefined)[];
}

/** Translates one batch and returns the same number of strings, in order. */
export async function translate(batch: string[], locale: Locale, job: Job): Promise<string[]> {
  const numbered = batch
    .map((s, i) => {
      const c = job.comments?.[i];
      return c ? `${i}. ${JSON.stringify(s)}   // ${c}` : `${i}. ${JSON.stringify(s)}`;
    })
    .join("\n");

  const register =
    job.kind === "interface"
      ? "This is interface text on a small screen. Match the register and the length of the original; prefer the wording Apple's own apps use in this language."
      : "This is marketing copy for a product page. It is plain and technical rather than breathless — keep it that way, and keep sentences about the same length as the original.";

  // Sized from the batch rather than fixed, because a batch here is anything
  // from twenty interface strings to a four-thousand-character App Store
  // description. Scripts outside ASCII cost close to a token a character.
  const chars = batch.reduce((n, s) => n + s.length, 0);
  const budget = Math.min(32000, Math.max(8000, chars * 2 + 2000));

  // The server constrains its own output to this shape, so what comes back is
  // JSON whether or not the model was going to co-operate. Asking politely in
  // the system prompt is what the code did before, and it worked for
  // twenty-three languages: Czech ran past the array without closing it, and
  // Arabic put an unescaped quote inside a string, which reads downstream as
  // "no JSON array in reply" and "Unrecognized token" — two spellings of the
  // same missing guarantee. An object rather than a bare array because a
  // top-level array is not something every server's JSON mode will accept.
  const schema = {
    type: "object",
    properties: {
      translations: {
        type: "array",
        items: { type: "string" },
        minItems: batch.length,
        maxItems: batch.length,
      },
    },
    required: ["translations"],
    additionalProperties: false,
  };

  const body = {
    model: MODEL,
    temperature: 0,
    max_tokens: budget,
    response_format: {
      type: "json_schema",
      json_schema: { name: "translations", strict: true, schema },
    },
    messages: [
      {
        role: "system",
        content:
          "You translate strings for a software product. You reply with a JSON object " +
          "whose only key is \"translations\", holding an array of strings and nothing " +
          "else — no prose, no markdown fence, no numbering. Every string is translated " +
          "in full: the reply carries as much text as the original, never a summary of it.",
      },
      {
        role: "user",
        content: [
          `Translate these ${batch.length} strings from English into ${locale.name} (${locale.endonym}), locale code ${locale.ios}.`,
          "",
          `Return a JSON array of exactly ${batch.length} strings in the same order.`,
          "",
          "Rules:",
          "- Copy every %@ %lld %1$@ and similar placeholder verbatim, in the same order. They are substituted at run time.",
          "- Keep ^[...](inflect: true) markup exactly as written, translating only the words inside the square brackets. iOS uses it to make the number and the noun agree.",
          "- Copy every HTML tag verbatim, in the same order, with its attributes unchanged. Translate only the text between tags.",
          "- Keep \\n line breaks and leading or trailing spaces.",
          `- Do not translate these names: ${KEEP.join(", ")}.`,
          `- ${register}`,
          "- A // comment after a string is context for you, not text to translate.",
          "",
          numbered,
        ].join("\n"),
      },
    ],
  };

  // A batch takes about a second. Without a deadline, one request that the
  // server never answers stops the whole run — which is exactly what happened
  // the first time this was pointed at all twenty-four languages: eleven
  // minutes at zero percent CPU, waiting on a socket.
  // Parsing is inside the retry, not after it. A truncated or malformed array is
  // by far the more common failure — the same batch will fail for one language
  // and succeed for the next — and it is exactly as retryable as a 503. Leaving
  // it outside cost twenty strings a language on the first full run.
  // A local endpoint takes no key, so the header is added only when there is
  // one to send rather than sent empty.
  const headers = KEY
    ? { "content-type": "application/json", authorization: `Bearer ${KEY}` }
    : { "content-type": "application/json" };

  return await withRetry(async () => {
    const res = await fetch(URL, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!res.ok) throw new Error(`${res.status} ${(await res.text()).slice(0, 200)}`);
    const raw: string = (await res.json()).choices?.[0]?.message?.content ?? "";

    // Models fence their JSON about half the time no matter what the system
    // prompt says, so the fence is stripped rather than argued with. A server
    // that ignores `response_format` still lands here, and a bare array is
    // still accepted — the object is what is asked for, not what is required.
    const text = raw.replace(/^\s*```(?:json)?/i, "").replace(/```\s*$/, "").trim();
    const open = text.search(/[[{]/);
    const close = Math.max(text.lastIndexOf("]"), text.lastIndexOf("}"));
    if (open < 0 || close < open) throw new Error(`no JSON in reply: ${text.slice(0, 200)}`);
    const object = JSON.parse(text.slice(open, close + 1));
    const parsed = Array.isArray(object) ? object : object?.translations;
    if (!Array.isArray(parsed)) throw new Error("reply was not an array");
    if (parsed.length !== batch.length) throw new Error(`asked for ${batch.length} strings, got ${parsed.length}`);
    // SAFETY: length and array-ness are both checked above, and every element
    // is handed to `validate()` by the caller before it is written anywhere —
    // a non-string element fails that check and is left untranslated.
    return parsed as string[];
  });
}
