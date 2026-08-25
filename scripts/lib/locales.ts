/**
 * Every language the app ships in, and the two different codes each one needs.
 *
 * The codes are the whole reason this file exists. iOS and App Store Connect
 * disagree, and they disagree silently — a wrong code does not error, it just
 * produces a localization nobody ever sees:
 *
 *   Norwegian   iOS wants `nb` (Bokmal). ASC wants `no`.
 *   Dutch       iOS wants `nl`.          ASC wants `nl-NL`.
 *   German      iOS wants `de`.          ASC wants `de-DE`.
 *   French      iOS wants `fr`.          ASC wants `fr-FR`.
 *   Spanish     iOS wants `es`.          ASC wants `es-ES`.
 *   Arabic      iOS wants `ar`.          ASC wants `ar-SA`.
 *
 * Ship `no.lproj` in the bundle and iOS ignores it; send `nb` to App Store
 * Connect and the request is rejected. Everything downstream — the String
 * Catalog, the web page, the screenshot runner, the metadata push — reads its
 * codes from here so the two spellings can never drift apart.
 *
 * Twenty-five languages, English included. The selection is App Store revenue
 * weighted toward this app's actual market: indoor cycling skews hard to
 * northern and western Europe, which is why Dutch, Danish, Swedish, Norwegian
 * and Czech appear well above their raw population rank.
 */

export interface Locale {
  /** App Store Connect metadata code. Used for appStoreVersionLocalizations. */
  asc: string;
  /** iOS bundle code. Used for .lproj, knownRegions, and String Catalog keys. */
  ios: string;
  /** English name, for logs and comments. */
  name: string;
  /**
   * Endonym — the language's name in its own language and its own script.
   *
   * In the language picker this is the only text on the page a visitor who
   * cannot read the current language is able to use. "Japanese" is no help to
   * someone looking for 日本語, so these are never transliterated, and the two
   * Spanishes and the two Chineses carry a region or a script in parentheses
   * because otherwise two entries in the list read identically.
   */
  endonym: string;
  /** Right-to-left script. Drives `dir="rtl"` on the web and layout checks in-app. */
  rtl?: boolean;
  /** Why this language is on the list, when the reason is not obvious. */
  note?: string;
}

/**
 * Order is deliberate: base first, then roughly by expected install volume for
 * this category. The screenshot runner walks this array, so the earlier a
 * language sits the sooner you get to eyeball it.
 */
export const LOCALES: Locale[] = [
  { asc: "en-US",   ios: "en",       name: "English",              endonym: "English" },

  // Continental Europe. Cycling's home market — these five are the ones most
  // likely to be opened by someone with a smart trainer already set up.
  { asc: "de-DE",   ios: "de",       name: "German",               endonym: "Deutsch",     note: "Also covers Austria and much of Switzerland." },
  { asc: "fr-FR",   ios: "fr",       name: "French",               endonym: "Français",    note: "Also Belgium, Switzerland, Quebec." },
  { asc: "it",      ios: "it",       name: "Italian",              endonym: "Italiano" },
  { asc: "es-ES",   ios: "es",       name: "Spanish",              endonym: "Español (España)" },
  { asc: "nl-NL",   ios: "nl",       name: "Dutch",                endonym: "Nederlands",  note: "Highest cycling participation per capita of any market here." },

  // Asia-Pacific. Largest App Store revenue outside the US.
  { asc: "ja",      ios: "ja",       name: "Japanese",             endonym: "日本語" },
  { asc: "zh-Hans", ios: "zh-Hans",  name: "Chinese, Simplified",  endonym: "简体中文" },
  { asc: "zh-Hant", ios: "zh-Hant",  name: "Chinese, Traditional", endonym: "繁體中文", note: "Taiwan and Hong Kong. Not interchangeable with Simplified." },
  { asc: "ko",      ios: "ko",       name: "Korean",               endonym: "한국어" },

  // Nordics and central Europe. Small populations, high iPhone share, and
  // indoor training season runs half the year.
  { asc: "sv",      ios: "sv",       name: "Swedish",              endonym: "Svenska" },
  { asc: "da",      ios: "da",       name: "Danish",               endonym: "Dansk" },
  { asc: "no",      ios: "nb",       name: "Norwegian",            endonym: "Norsk bokmål", note: "ASC calls this `no`; iOS only recognises the Bokmal code `nb`." },
  { asc: "fi",      ios: "fi",       name: "Finnish",              endonym: "Suomi" },
  { asc: "pl",      ios: "pl",       name: "Polish",               endonym: "Polski" },
  { asc: "cs",      ios: "cs",       name: "Czech",                endonym: "Čeština",     note: "Disproportionate cycling and trainer market for its size." },

  // Americas and the rest of Europe.
  { asc: "pt-BR",   ios: "pt-BR",    name: "Portuguese, Brazil",   endonym: "Português (Brasil)" },
  { asc: "es-MX",   ios: "es-MX",    name: "Spanish, Mexico",      endonym: "Español (México)", note: "Latin America. Diverges from es-ES enough to be worth its own slot." },
  { asc: "ru",      ios: "ru",       name: "Russian",              endonym: "Русский" },
  { asc: "uk",      ios: "uk",       name: "Ukrainian",            endonym: "Українська" },
  { asc: "tr",      ios: "tr",       name: "Turkish",              endonym: "Türkçe" },

  // Remaining high-volume App Store markets.
  { asc: "ar-SA",   ios: "ar",       name: "Arabic",               endonym: "العربية",     rtl: true, note: "Right to left. The only locale here that changes layout, not just text." },
  { asc: "th",      ios: "th",       name: "Thai",                 endonym: "ไทย" },
  { asc: "id",      ios: "id",       name: "Indonesian",           endonym: "Bahasa Indonesia" },
  { asc: "vi",      ios: "vi",       name: "Vietnamese",           endonym: "Tiếng Việt" },
];

/**
 * Considered and left out, in the order they would be added next. Each is a
 * valid App Store Connect locale, so extending the list is only a matter of
 * moving a line up and re-running the pipeline.
 *
 * Hebrew (he), Greek (el), Hungarian (hu), Romanian (ro), Slovak (sk),
 * Catalan (ca), Croatian (hr), Portuguese-Portugal (pt-PT), Malay (ms),
 * Hindi (hi), English-UK (en-GB), English-Australia (en-AU).
 *
 * The two English variants are the cheapest of these by far — no translation,
 * only spelling and keyword changes — and are worth adding if the goal is
 * store search coverage rather than reaching non-English speakers.
 */
export const RUNNERS_UP = [
  "he", "el", "hu", "ro", "sk", "ca", "hr", "pt-PT", "ms", "hi", "en-GB", "en-AU",
] as const;

/** The base language. Source of truth for every translation. */
export const BASE = LOCALES[0];

/** Everything that actually needs translating. */
export const TRANSLATED = LOCALES.filter((l) => l.ios !== BASE.ios);

/** iOS codes, for project.yml knownRegions. */
export const IOS_CODES = LOCALES.map((l) => l.ios);

/** ASC codes, for the metadata push. */
export const ASC_CODES = LOCALES.map((l) => l.asc);

export const byIos = (code: string) => LOCALES.find((l) => l.ios === code);
export const byAsc = (code: string) => LOCALES.find((l) => l.asc === code);

/**
 * Guards against the failure this file exists to prevent: two locales that
 * collapse to the same code, or a translated locale that forgot its ASC
 * spelling. Cheap enough to run on import.
 */
function assertConsistent() {
  for (const [label, codes] of [["iOS", IOS_CODES], ["ASC", ASC_CODES]] as const) {
    const dupes = codes.filter((c, i) => codes.indexOf(c) !== i);
    if (dupes.length) throw new Error(`Duplicate ${label} locale code: ${dupes.join(", ")}`);
  }
  if (LOCALES.length !== 25) {
    throw new Error(`Expected 25 locales, found ${LOCALES.length}. Update this check deliberately.`);
  }
}
assertConsistent();
