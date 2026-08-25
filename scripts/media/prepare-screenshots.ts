#!/usr/bin/env bun
/**
 * Turn a folder of raw device screenshots into the exact pixel sizes App Store
 * Connect will accept, plus the web-sized copies the marketing page uses.
 *
 * App Store Connect rejects anything that is not one of a short list of exact
 * dimensions, and it rejects the whole upload rather than the offending file.
 * An iPad mini screenshot (2266x1488) is not on that list — no iPad screenshot
 * from a mini ever is — so it is scaled to fit and padded out to the 13-inch
 * size on a matching background rather than stretched, which would be visibly
 * wrong at the aspect ratios involved.
 *
 * Usage:  bun scripts/prepare-screenshots.ts [sourceDir]
 * Source defaults to ~/Downloads/<brand>. Nothing in the source folder is
 * modified.
 */

import { $ } from "bun";
import { readFileSync } from "node:fs";
import { mkdir, readdir, rm } from "node:fs/promises";
import { join, basename } from "node:path";
import { homedir } from "node:os";

/** The drop folder is named after the project so two projects can share ~/Downloads. */
const BRAND: string = JSON.parse(readFileSync("apple-project.json", "utf8")).site.brand;
const SRC = process.argv[2] ?? join(homedir(), "Downloads", BRAND);
const OUT = join(SRC, "appstore");
const WEB = join(import.meta.dir, "..", "..", "web", "static", "img", "screens");
const PRESS = join(import.meta.dir, "..", "..", "web", "press");

/** The app's own light background, so padding is invisible rather than a frame. */
const PAD = "#F2F2F7";

type Target = { w: number; h: number; dir: string };

/**
 * Only the sizes Apple currently requires. A 6.9" iPhone set covers every
 * smaller iPhone, and a 13" iPad set covers every smaller iPad — Apple
 * downscales the rest, so uploading more sizes buys nothing.
 */
/** Device slug -> the size to render it at. Looked up by a runtime string. */
type TargetMap = Record<string, Target>;

/** Source file stem -> the name the website references it by. */
type WebNames = Record<string, string>;

/** Device slug -> how many shots were written for it. */
type Counts = Record<string, number>;

const TARGETS = {
  iphone: { w: 1320, h: 2868, dir: "iphone-6.9" },   // 6.9" — iPhone 17 Pro Max
  ipad: { w: 2752, h: 2064, dir: "ipad-13" },        // 13" landscape
  watch: { w: 416, h: 496, dir: "watch-46mm" },      // Series 10, 46mm
} satisfies TargetMap;

/**
 * Camera-roll names mean nothing six months from now, and the marketing page
 * has to reference these by hand. Only the shots the page actually uses are
 * given a name; everything else is still resized for the App Store, but is not
 * copied to the site.
 */
const WEB_NAMES = {
  IMG_4195: "live",
  IMG_4179: "connected",
  IMG_4187: "bridge",
  IMG_4178: "settings",
  IMG_4189: "diagnostics",
  IMG_4181: "permissions",
  IMG_4176: "airpods",
  IMG_4191: "about",
  // From a ride with the meters actually connected. The simulator has no
  // Bluetooth radio at all, so a screen showing real pedals and a real trainer
  // can only come off a device.
  IMG_4235: "status",
  IMG_4236: "bike-control",
  IMG_4240: "summary",
  "incoming-37C592E9-3F42-4CE0-B90C-0D6B1D714D05": "watch-live",
  "incoming-A1F21C1B-4CDA-4538-8D34-080209A35FE4": "watch-status",
} satisfies WebNames;

/** Classify by pixel dimensions — the filenames carry no device information. */
function classify(w: number, h: number): keyof typeof TARGETS | null {
  if (w <= 500) return "watch";
  if (h > w) return "iphone";
  return "ipad";
}

async function dimensions(file: string): Promise<[number, number]> {
  const out = await $`sips -g pixelWidth -g pixelHeight ${file}`.text();
  const nums = [...out.matchAll(/pixel(?:Width|Height): (\d+)/g)].map((m) => Number(m[1]));
  return [nums[0], nums[1]];
}

/**
 * Scale to fit inside the target and centre it on a solid background. `-resize`
 * with a `>` is deliberately absent: a screenshot smaller than the target is
 * scaled up, because Apple wants the exact size and a padded thumbnail would
 * read as a mistake.
 */
async function fit(src: string, dest: string, t: Target) {
  await $`magick ${src} -resize ${t.w}x${t.h} -background ${PAD} -gravity center -extent ${t.w}x${t.h} ${dest}`;
}

async function webCopy(src: string, dest: string, width: number) {
  await $`magick ${src} -resize ${width}x -quality 82 ${dest}`;
}

const files = (await readdir(SRC)).filter((f) => /\.(png|jpe?g)$/i.test(f));
if (files.length === 0) {
  console.error(`No screenshots in ${SRC}`);
  process.exit(1);
}

await rm(OUT, { recursive: true, force: true });
// Only this script's own output is cleared, so a screenshot dropped from
// WEB_NAMES stops being served rather than lingering as an orphan. Emptying the
// whole directory would take the simulator-rendered screens with it —
// `workout-screens.ts` writes into the same folder and does not know this ran.
for (const owned of Object.values(WEB_NAMES)) {
  await rm(join(WEB, `shot-${owned}.jpg`), { force: true });
}
for (const t of Object.values(TARGETS)) await mkdir(join(OUT, t.dir), { recursive: true });
await mkdir(WEB, { recursive: true });
await mkdir(PRESS, { recursive: true });

const counts: Counts = {};

for (const f of files) {
  const src = join(SRC, f);
  const [w, h] = await dimensions(src);
  const kind = classify(w, h);
  if (!kind) continue;
  const t = TARGETS[kind];
  const name = basename(f).replace(/\.[^.]+$/, "");
  const dest = join(OUT, t.dir, `${name}.png`);

  if (w === t.w && h === t.h) {
    await $`cp ${src} ${dest}`;
  } else {
    await fit(src, dest, t);
  }
  counts[kind] = (counts[kind] ?? 0) + 1;

  // Web copies: wide enough to stay sharp on a 2x display at the size they are
  // actually drawn, small enough that the page still loads on a phone.
  const webName = WEB_NAMES[name];
  if (webName) {
    const webWidth = kind === "ipad" ? 1600 : kind === "watch" ? 500 : 720;
    await webCopy(src, join(WEB, `shot-${webName}.jpg`), webWidth);
  }
}

console.log(`Source: ${SRC}`);
for (const [kind, n] of Object.entries(counts)) {
  const t = TARGETS[kind];
  console.log(`  ${kind.padEnd(7)} ${String(n).padStart(2)} -> ${t.w}x${t.h}  ${join(OUT, t.dir)}`);
}
console.log(`Web copies: ${WEB}`);
