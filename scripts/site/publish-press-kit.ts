#!/usr/bin/env bun
/**
 * Curate the App Store Connect screenshot set and publish it, plus the app
 * icon, to an unlinked path on the marketing site.
 *
 * The path is unlinked rather than protected. Anything the web server can hand
 * to a browser extension can be handed to anyone who guesses the URL, so this
 * holds only material that is going on the App Store anyway. It is not a place
 * to put anything private.
 *
 * Run `prepare-screenshots.ts` first — this reads its output.
 *
 * This wipes the press directory, so `publish-listing.ts` has to run after it,
 * not before: the localized listing it writes lives under the same root and
 * would otherwise be deleted by the next capture.
 *
 * Usage:  bun scripts/publish-press-kit.ts [sourceDir]
 */

import { $ } from "bun";
import { readFileSync } from "node:fs";
import { mkdir, rm, writeFile, copyFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";

const PROJECT = JSON.parse(readFileSync("apple-project.json", "utf8"));
/** The drop folder is named after the project so two projects can share ~/Downloads. */
const SRC = process.argv[2] ?? join(homedir(), "Downloads", PROJECT.site.brand);
const SHOTS = join(SRC, "appstore");
const REPO = join(import.meta.dir, "..", "..");
const PRESS = join(REPO, "web", "press");

/**
 * Order is the App Store's display order, and the first three are the ones that
 * appear in search results — so they lead with a live reading rather than with
 * a settings form.
 *
 * Recaptured 2026-08-04 against a build that carries the final name; the set
 * these replaced showed the app's previous name in every navigation bar.
 *
 * `IMG_4211` is deliberately absent. It is the About sheet, and the phone was
 * still on build 31 when these were taken — so it renders the pre-rename
 * heading, which is the one defect this recapture exists to remove. Seven
 * screenshots is well inside what Apple accepts; an eighth that reintroduces
 * the problem is not worth the slot.
 */
const IPHONE = [
  ["IMG_4205", "Live reading, both sensors reconciled into one broadcast"],
  ["IMG_4212", "Every Bluetooth detail: service, characteristic, frames on the wire"],
  ["IMG_4207", "Bridge settings — advertised name, service, live subscriber count"],
  ["IMG_4209", "Every permission, its real state, and a direct link to change it"],
  ["IMG_4206", "Source, push frequency, Dynamic Island, Picture in Picture"],
  ["IMG_4208", "Watch controls, and one tap back to permissions"],
  ["IMG_4210", "Health and Bluetooth access, changeable without leaving the app"],
] as const;

const WATCH = [
  ["watch-46mm-01", "Live heart rate on the wrist, link state at a glance"],
  ["watch-46mm-02", "Watch status: phone link, bridge, and HealthKit"],
] as const;

/**
 * Captured on an iPad mini (2266x1488) and padded up to the 13" slot, because
 * Apple only asks for the largest iPad size and scales the rest. The mini is
 * never itself an accepted size, so the bands top and bottom are structural —
 * recapturing on a mini cannot remove them, only a larger iPad could.
 *
 * Recaptured 2026-08-04. The set these replace predated the rename and led with
 * a grey heart reading "No samples yet", which is a poor thing to put in the
 * frame Apple shows in search results. These lead with a live AirPods reading.
 *
 * `IMG_0017` is dropped for the same reason as the iPhone About shot: the iPad
 * was still on build 31, so that sheet renders the pre-rename heading.
 */
const IPAD = [
  ["IMG_0013", "Broadcasting from the iPad, live from AirPods Pro 3"],
  ["IMG_0015", "Broadcast detail: advertised name, service, subscribers, value"],
  ["IMG_0016", "Every permission, its real state, and what denying it costs"],
  ["IMG_0014", "Source, push frequency, Dynamic Island, Picture in Picture"],
] as const;

type Group = { dir: string; picks: ReadonlyArray<readonly [string, string]>; label: string };

const GROUPS: Group[] = [
  { dir: "iphone-6.9", picks: IPHONE, label: "iPhone 6.9\" (1320x2868)" },
  { dir: "ipad-13", picks: IPAD, label: "iPad 13\" (2752x2064)" },
  { dir: "watch-46mm", picks: WATCH, label: "Apple Watch 46mm (416x496)" },
];

await rm(PRESS, { recursive: true, force: true });
await mkdir(join(PRESS, "screenshots"), { recursive: true });

/** One capture as the kit lists it. */
interface Shot {
  file: string;
  caption: string;
}

/**
 * What `manifest.json` promises anything consuming the kit. Named rather than
 * inline so the two writers below cannot drift from the readers.
 */
interface PressKit {
  app: string;
  bundleId: string;
  generated: string;
  icon: string;
  screenshots: Record<string, Shot[]>;
}

const manifest: PressKit = {
  app: PROJECT.app.name,
  bundleId: PROJECT.app.bundleId,
  // Stamped so anything consuming this kit can tell how old the captures are.
  // The App Store Connect upload prompt refuses to run against a manifest older
  // than the last rename, because replacing a stale screenshot set with the
  // same stale files looks like success and is not.
  generated: new Date().toISOString(),
  icon: "icon-1024.png",
  screenshots: {},
};

await copyFile(join(REPO, "web", "static", "img", "icon.png"), join(PRESS, "icon-1024.png"));

const lines: string[] = [];
for (const g of GROUPS) {
  const entries: Array<{ file: string; caption: string }> = [];
  if (g.picks.length) lines.push(`<h2>${g.label}</h2>`, "<ul>");
  for (const [i, [name, caption]] of g.picks.entries()) {
    const n = String(i + 1).padStart(2, "0");
    const out = `${g.dir}-${n}.png`;
    await copyFile(join(SHOTS, g.dir, `${name}.png`), join(PRESS, "screenshots", out));
    entries.push({ file: `screenshots/${out}`, caption });
    lines.push(`<li><a href="screenshots/${out}">${out}</a> — ${caption}</li>`);
  }
  manifest.screenshots[g.dir] = entries;
  if (entries.length) lines.push("</ul>");
}

await writeFile(join(PRESS, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");

// A plain index so a browser extension pointed at the folder has something to
// read; robots are told to stay away because this is an upload staging area,
// not a page anyone should find in a search result.
const index = `<!doctype html>
<meta charset="utf-8">
<meta name="robots" content="noindex, nofollow">
<title>${PROJECT.app.name} — press kit</title>
<style>body{font:15px/1.6 -apple-system,system-ui,sans-serif;max-width:52rem;margin:3rem auto;padding:0 1.5rem;color:#26262b}
h1{font-size:1.4rem}h2{font-size:1rem;margin-top:2rem}code{background:#f2f2f7;padding:.1em .35em;border-radius:4px}
ul{padding-left:1.1rem}a{color:#0a58ca}</style>
<h1>${PROJECT.app.name} — App Store assets</h1>
<p>Unlinked staging area for the App Store Connect listing. Machine-readable index:
<a href="manifest.json">manifest.json</a>. App icon: <a href="icon-1024.png">icon-1024.png</a> (1024x1024).</p>
${lines.join("\n")}
`;
await writeFile(join(PRESS, "index.html"), index);

const total = GROUPS.reduce((n, g) => n + g.picks.length, 0);
console.log(`Press kit: ${PRESS}`);
console.log(`  ${total} screenshots + icon-1024.png + manifest.json`);
for (const g of GROUPS) console.log(`  ${g.label.padEnd(28)} ${g.picks.length}`);
await $`ls ${join(PRESS, "screenshots")}`.quiet();
