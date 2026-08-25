#!/usr/bin/env bun
/**
 * Builds `appstore/` at the repo root: the exact files to drag into App Store
 * Connect, in the order they should be uploaded.
 *
 * The press folder holds the curated captures at their native size. This
 * groups them by App Store Connect upload slot, names each file for what it
 * shows, and derives the smaller slots that ask for a different pixel size.
 *
 * Deriving matters because the aspect ratios are not identical — 6.9" is
 * 0.46025 and 6.5" is 0.46220 — so a plain resize lands a pixel or two off
 * and App Store Connect rejects the file. Each derived shot is scaled to
 * cover the target and then cropped, anchored so the status bar survives and
 * the trim comes off the bottom. The crop is ~12px of 2790, invisible.
 *
 * Regenerate the press folder first if screenshots changed:
 *   bun scripts/prepare-screenshots.ts && bun scripts/publish-press-kit.ts
 */

import { $ } from "bun";
import { readFileSync } from "node:fs";
import { copyFile, mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

/** Only used to name the drop folder in the instructions this writes. */
const BRAND: string = JSON.parse(readFileSync("apple-project.json", "utf8")).site.brand;
const ROOT = join(import.meta.dir, "..", "..");
const PRESS = join(ROOT, "web", "press", "screenshots");
const OUT = join(ROOT, "appstore");

type Shot = { src: string; name: string; caption: string };

const IPHONE: Shot[] = [
  ["iphone-6.9-01", "live-and-reconciled", "Live reading, both sensors reconciled into one broadcast"],
  ["iphone-6.9-02", "bluetooth-detail", "Every Bluetooth detail: service, characteristic, frames on the wire"],
  ["iphone-6.9-03", "bridge-settings", "Bridge settings — advertised name, service, live subscriber count"],
  ["iphone-6.9-04", "permissions", "Every permission, its real state, and a direct link to change it"],
  ["iphone-6.9-05", "settings", "Source, push frequency, Dynamic Island, Picture in Picture"],
  ["iphone-6.9-06", "watch-controls", "Watch controls, and one tap back to permissions"],
  ["iphone-6.9-07", "access", "Health and Bluetooth access, changeable without leaving the app"],
].map(([src, name, caption]) => ({ src, name, caption }));

const IPAD: Shot[] = [
  ["ipad-13-01", "broadcasting-airpods", "Broadcasting from the iPad, live from AirPods Pro 3"],
  ["ipad-13-02", "broadcast-detail", "Broadcast detail: advertised name, service, subscribers, value"],
  ["ipad-13-03", "permissions", "Every permission, its real state, and what denying it costs"],
  ["ipad-13-04", "settings", "Source, push frequency, Dynamic Island, Picture in Picture"],
].map(([src, name, caption]) => ({ src, name, caption }));

const WATCH: Shot[] = [
  ["watch-46mm-01", "live-on-the-wrist", "Live heart rate on the wrist, link state at a glance"],
  ["watch-46mm-02", "watch-status", "Watch status: phone link, bridge, and HealthKit"],
].map(([src, name, caption]) => ({ src, name, caption }));

type Group = {
  dir: string;
  label: string;
  w: number;
  h: number;
  shots: Shot[];
  /** Where the trim comes off when the aspect ratio does not match. */
  gravity: "north" | "center";
  /** Copied byte-for-byte when the source is already this size. */
  native: boolean;
  note?: string;
};

const GROUPS: Group[] = [
  {
    dir: "iphone-6.9",
    label: 'iPhone 6.9" (16 Pro Max, 17 Pro Max)',
    w: 1320,
    h: 2868,
    shots: IPHONE,
    gravity: "north",
    native: true,
  },
  {
    dir: "iphone-6.5",
    label: 'iPhone 6.5" / 6.7" (11 Pro Max through 15 Plus)',
    w: 1284,
    h: 2778,
    shots: IPHONE,
    gravity: "north",
    native: false,
    note: "Derived from the 6.9\" captures. This is the slot that lists 1242x2688 or 1284x2778.",
  },
  {
    dir: "ipad-13",
    label: 'iPad 13"',
    w: 2752,
    h: 2064,
    shots: IPAD,
    gravity: "center",
    native: true,
    note: "Captured on an iPad mini and padded up to the 13\" slot. Read CAVEATS.md first.",
  },
  {
    dir: "watch-46mm",
    label: "Apple Watch 46mm / Ultra",
    w: 416,
    h: 496,
    shots: WATCH,
    gravity: "center",
    native: true,
  },
  {
    dir: "watch-45mm",
    label: "Apple Watch 45mm / 44mm",
    w: 396,
    h: 484,
    shots: WATCH,
    gravity: "center",
    native: false,
    note: "Derived from the 46mm captures.",
  },
];

async function dims(file: string): Promise<[number, number]> {
  const out = await $`sips -g pixelWidth -g pixelHeight ${file}`.text();
  const n = [...out.matchAll(/pixel(?:Width|Height): (\d+)/g)].map((m) => Number(m[1]));
  return [n[0], n[1]];
}

await rm(OUT, { recursive: true, force: true });
await mkdir(join(OUT, "icon"), { recursive: true });

const lines: string[] = [];
let bad = 0;

for (const g of GROUPS) {
  await mkdir(join(OUT, g.dir), { recursive: true });
  lines.push(`\n## ${g.label} — ${g.w} x ${g.h}\n`);
  if (g.note) lines.push(`${g.note}\n`);
  lines.push("| # | File | What it shows |");
  lines.push("| --- | --- | --- |");

  for (const [i, s] of g.shots.entries()) {
    const n = String(i + 1).padStart(2, "0");
    const file = `${n}-${s.name}.png`;
    const src = join(PRESS, `${s.src}.png`);
    const dest = join(OUT, g.dir, file);

    if (g.native) {
      await copyFile(src, dest);
    } else {
      // `^` scales to cover rather than fit, so extent crops instead of padding.
      await $`magick ${src} -resize ${`${g.w}x${g.h}^`} -gravity ${g.gravity} -extent ${`${g.w}x${g.h}`} -alpha off -strip ${dest}`.quiet();
    }

    const [w, h] = await dims(dest);
    if (w !== g.w || h !== g.h) {
      console.error(`  WRONG SIZE  ${g.dir}/${file} is ${w}x${h}, expected ${g.w}x${g.h}`);
      bad++;
    }
    lines.push(`| ${n} | \`${file}\` | ${s.caption} |`);
  }
}

await copyFile(join(PRESS, "..", "icon-1024.png"), join(OUT, "icon", "app-icon-1024.png"));

await writeFile(
  join(OUT, "ipad-13", "CAVEATS.md"),
  `# Read before uploading the iPad set\n\n` +
    `Recaptured 2026-08-04. The set these replaced predated the rename and led\n` +
    `with a grey heart reading "No samples yet" — the worst possible frame for\n` +
    `the one Apple shows in search results. These lead with a live reading\n` +
    `sourced from AirPods Pro 3, paired directly to the iPad.\n\n` +
    `Two things are still true of them, neither fixable by capturing again on\n` +
    `the same hardware.\n\n` +
    `## 1. The bands top and bottom are structural\n\n` +
    `Captured on an iPad mini at its native 2266 x 1488, then scaled to fit and\n` +
    `padded to 2752 x 2064 with the app's own grouped background colour. The\n` +
    `mini's size is not on Apple's accepted list and never will be, so it must\n` +
    `be padded into the 13" slot. Only a physically larger iPad removes the\n` +
    `bands.\n\n` +
    `## 2. There are four, not five\n\n` +
    `The fifth capture was the About sheet. The iPad was still running build 31\n` +
    `when these were taken, so that one screen renders the pre-rename heading —\n` +
    `the single defect the recapture exists to remove. It was dropped rather\n` +
    `than uploaded. Apple accepts up to ten and requires far fewer. The iPhone\n` +
    `set is short by one for exactly the same reason.\n\n` +
    `## Regenerating\n\n` +
    `Drop fresh captures in \`~/Downloads/${BRAND}\`, update the \`IPAD\` list in\n` +
    `\`scripts/publish-press-kit.ts\`, then run:\n\n` +
    `    bun scripts/publish-press-kit.ts ~/Downloads/${BRAND}\n` +
    `    bun scripts/export-appstore.ts\n\n` +
    `\`prepare-screenshots.ts\` is only needed when a capture is not already at\n` +
    `its target size — it clears its output directories first, so running it\n` +
    `against a set that needs no resizing destroys work rather than doing any.\n`,
);

const readme = `# App Store Connect upload set

Drag each folder's contents into the matching device tab, in filename order.
That order is deliberate: the first three appear in search results.

App Store Connect shows one tab per display size and states the pixel sizes it
will take. Match the folder to the numbers on the tab:

| The tab says | Use |
| --- | --- |
| 1320 x 2868 | \`iphone-6.9/\` |
| 1242 x 2688 or 1284 x 2778 | \`iphone-6.5/\` |
| 2752 x 2064 | \`ipad-13/\` — read \`CAVEATS.md\` first |
| 416 x 496 | \`watch-46mm/\` |
| 396 x 484 | \`watch-45mm/\` |

Every file is already an exact match with no alpha channel. Nothing needs
resizing or converting.

Generated by \`bun scripts/export-appstore.ts\` — regenerate rather than editing
in place. Not tracked in git; the source of truth is \`web/press/\`.

## App icon

\`icon/app-icon-1024.png\` — 1024 x 1024, no alpha.
${lines.join("\n")}
`;

await writeFile(join(OUT, "README.md"), readme);

console.log("appstore/");
for (const g of GROUPS) {
  const how = g.native ? "native" : "derived";
  console.log(`  ${g.dir.padEnd(12)} ${String(g.shots.length).padStart(2)}  ${`${g.w}x${g.h}`.padEnd(10)} ${how}`);
}
console.log(bad ? `\n${bad} file(s) the wrong size` : `\nAll sizes verified.`);
