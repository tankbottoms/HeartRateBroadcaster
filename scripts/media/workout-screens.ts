#!/usr/bin/env bun
/**
 * Captures the workout screens for the marketing site.
 *
 *   bun scripts/workout-screens.ts
 *
 * Runs `Screenshots/WorkoutScreens.swift` once, in English, on the iPhone
 * simulator, and writes `web/static/img/screens/shot-<name>.jpg` at the same
 * 720px width as the screenshots already on the page.
 *
 * Body details are written into the app's defaults before the run, because the
 * calorie figure is only as interesting as the profile behind it: with no date
 * of birth the summary can only say "rough estimate". `simctl spawn defaults`
 * is the only way in — a UI test runs in its own process and cannot write the
 * app's preferences, and the argument domain has no way to express a date.
 *
 * The simulator has no Bluetooth radio, so the test launches the app with
 * `-demoMeters 1` and a fabricated trainer, crank and pedal pair stand in for
 * ones that cannot exist here. The grouping, the arithmetic and the choice of
 * which source counts are all the app's own; only the radio is missing.
 */

import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";

const PROJECT = JSON.parse(readFileSync("apple-project.json", "utf8"));
const SCHEME: string = PROJECT.paths.screenshotTarget;
const BUNDLE: string = PROJECT.app.bundleId;
const SIMULATOR = "iPhone 17 Pro Max";
const WORK = ".screenshots/workout";
const OUT = "web/static/img/screens";
/** Matches the width of every other screenshot on the page. */
const WIDTH = 720;

/** The first available simulator with this name, newest runtime first. */
function udid(name: string): string {
  const raw = Bun.spawnSync(["xcrun", "simctl", "list", "devices", "available", "--json"]).stdout.toString();
  // SAFETY: same `simctl list devices --json` contract as scripts/screenshots.ts —
  // `devices` maps a runtime identifier to an array carrying these three fields.
  const all = JSON.parse(raw).devices as Record<string, { name: string; udid: string; isAvailable: boolean }[]>;
  for (const list of Object.values(all)) {
    const hit = [...list].reverse().find((d) => d.name === name && d.isAvailable);
    if (hit) return hit.udid;
  }
  throw new Error(`No available simulator named "${SIMULATOR}".`);
}

const id = udid(SIMULATOR);

/**
 * A body the estimate can actually use: 82 kg, 5 ft 11 in, born in 1979.
 * Imperial, because the point of the picture is the feet-and-inches row.
 */
function writeBodyDefaults() {
  const sim = ["xcrun", "simctl", "spawn", id, "defaults", "write", BUNDLE];
  Bun.spawnSync(["xcrun", "simctl", "boot", id]);
  Bun.spawnSync(["xcrun", "simctl", "bootstatus", id, "-b"]);
  // The language runner leaves the device on whatever locale it finished with,
  // and `-AppleLanguages` as a launch argument only reaches the app — the status
  // bar keeps drawing Arabic-Indic digits over an English screenshot. Setting
  // the global domain and rebooting is what actually moves the device.
  Bun.spawnSync(["xcrun", "simctl", "spawn", id, "defaults", "write", "-g", "AppleLanguages", "-array", "en"]);
  Bun.spawnSync(["xcrun", "simctl", "spawn", id, "defaults", "write", "-g", "AppleLocale", "-string", "en_US"]);
  Bun.spawnSync(["xcrun", "simctl", "shutdown", id]);
  Bun.spawnSync(["xcrun", "simctl", "boot", id]);
  Bun.spawnSync(["xcrun", "simctl", "bootstatus", id, "-b"]);
  Bun.spawnSync([...sim, "body.massKg", "-float", "82"]);
  Bun.spawnSync([...sim, "body.heightCm", "-float", "180.3"]);
  Bun.spawnSync([...sim, "body.metric", "-bool", "NO"]);
  Bun.spawnSync([...sim, "body.dob", "-date", "1979-04-02 12:00:00 +0000"]);
  Bun.spawnSync([...sim, "body.sex", "-string", "male"]);
  // A fixed 97 BPM, the same reading the rest of the site's screenshots carry.
  // Zero swing matters as much as the value: the readout animates digit by
  // digit, so a number that is still moving photographs as two ghosted glyphs
  // on top of each other. A constant never animates. 97 is also low enough to
  // be a believable warm-up. The calories come from the primary power source
  // rather than from this number, but the live capture still sits on the screen
  // for three minutes so the elapsed time reads like a ride rather than a test.
  // Written here rather than passed as a launch argument because the argument
  // domain did not deliver these two keys.
  Bun.spawnSync([...sim, "testSignalCentre", "-float", "97"]);
  Bun.spawnSync([...sim, "testSignalSwing", "-float", "0"]);
  // Same reason, and found the same way: the launch argument alone left the
  // Sensors screen empty with the red "cannot connect" line under it, which is
  // exactly what a screen with no fabricated meters looks like.
  Bun.spawnSync([...sim, "demoMeters", "-bool", "YES"]);
  // A previous run's meters are persisted under this key, and the fabricated
  // ones are remembered through the same door a real pairing uses. Clearing it
  // first keeps the list to the four this run puts there.
  Bun.spawnSync(["xcrun", "simctl", "spawn", id, "defaults", "delete", BUNDLE, "meters.paired"]);
}

function run(): number {
  const bundle = join(WORK, "run.xcresult");
  rmSync(bundle, { recursive: true, force: true });
  const r = Bun.spawnSync([
    "xcodebuild", "test",
    "-project", PROJECT.paths.xcodeproj,
    "-scheme", SCHEME,
    "-destination", `id=${id}`,
    "-resultBundlePath", bundle,
    "-derivedDataPath", join(WORK, "DerivedData"),
    "-only-testing:HeartRateBroadcasterScreenshots/WorkoutScreens",
    "CODE_SIGNING_ALLOWED=NO",
  ], { stdout: "pipe", stderr: "pipe" });
  // Kept even on success: a run that captures four screens out of five passes,
  // and the accessibility tree printed by the missing control is the only thing
  // that says which handle went stale.
  const log = join(WORK, "xcodebuild.log");
  Bun.write(log, r.stdout.toString() + r.stderr.toString());
  if (r.exitCode !== 0) throw new Error(`xcodebuild failed — see ${log}`);
  return files(bundle);
}

/**
 * Pulls the attachments out of the result bundle and files them by the name the
 * test gave them. Without the manifest the export is a folder of UUIDs in
 * nondeterministic order.
 */
function files(bundle: string): number {
  const staging = join(WORK, "export");
  rmSync(staging, { recursive: true, force: true });
  mkdirSync(staging, { recursive: true });
  const r = Bun.spawnSync(["xcrun", "xcresulttool", "export", "attachments",
                           "--path", bundle, "--output-path", staging]);
  if (r.exitCode !== 0) throw new Error(`xcresulttool: ${r.stderr.toString().slice(0, 300)}`);

  // SAFETY: `xcresulttool export attachments` writes this manifest itself and
  // the exit code was checked above, so the file is the tool's own output in
  // its documented shape. Both fields read below are treated as optional.
  const manifest = JSON.parse(readFileSync(join(staging, "manifest.json"), "utf8")) as
    { attachments?: { suggestedHumanReadableName?: string; exportedFileName: string }[] }[];
  mkdirSync(OUT, { recursive: true });

  let n = 0;
  for (const test of manifest) {
    for (const a of test.attachments ?? []) {
      const raw = a.suggestedHumanReadableName;
      if (!raw || !/^\d\d-/.test(raw)) continue;
      // XCTest appends `_0_<uuid>.png` to whatever name it was handed.
      const name = raw.replace(/_\d+_[0-9A-F-]{36}\.png$/i, "").replace(/\.png$/i, "").slice(3);
      const png = join(staging, `${name}.png`);
      renameSync(join(staging, a.exportedFileName), png);
      // `--resampleWidth`, not `-Z`: `-Z` constrains the *largest* dimension,
      // so on a portrait screenshot it sets the height and leaves the width at
      // 331 — under half the resolution of the shots already on the page.
      Bun.spawnSync(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "80",
                     "--resampleWidth", String(WIDTH), png, "--out", join(OUT, `shot-${name}.jpg`)]);
      n++;
    }
  }
  rmSync(staging, { recursive: true, force: true });
  return n;
}

if (!existsSync(WORK)) mkdirSync(WORK, { recursive: true });
writeBodyDefaults();
const count = run();
console.log(`${count} screens -> ${OUT}`);
const MINE = ["shot-body.jpg", "shot-sensors.jpg"];
for (const f of readdirSync(OUT).filter((f) => f.startsWith("shot-workout") || MINE.includes(f))) {
  console.log(`  ${f}`);
}
