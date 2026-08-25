#!/usr/bin/env bun
/**
 * Captures the App Store screenshot set in every language, from the simulator.
 *
 *   bun scripts/screenshots.ts                 # every language, both devices
 *   bun scripts/screenshots.ts --lang de,ja
 *   bun scripts/screenshots.ts --device iphone-6.9
 *   bun scripts/screenshots.ts --keep-going    # do not stop on a failed language
 *
 * Output: `appstore/localized/<asc>/<device>/NN-name.png`.
 *
 * The hand-captured English set in `appstore/iphone-6.9` and `appstore/ipad-13`
 * is deliberately not touched. It came off real hardware with a real head unit
 * subscribed, and no simulator can reproduce that — see CAVEATS below.
 *
 * HOW THE LANGUAGE IS SET
 * Not by rebuilding: `Screenshots/ScreenshotRunner.swift` launches the app with
 * `-AppleLanguages (xx) -AppleLocale xx_YY`, which land in `NSArgumentDomain` at
 * the top of the `UserDefaults` search order. One build, twenty-five languages.
 * `-source testSignal` rides along the same way, so every language shows a live
 * BPM rather than an em dash.
 *
 * CAVEATS, WHICH ARE NOT SMALL
 * CoreBluetooth peripheral mode does not exist in the simulator, so the bridge
 * reports unsupported and nothing ever subscribes. HealthKit has no watch and no
 * AirPods behind it either. These images are honest pictures of the app's
 * interface in each language; they are not pictures of it broadcasting. Use them
 * for the localized listings and keep the English hardware set as the reference
 * — or recapture all of it on hardware if the two ever have to match.
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import { LOCALES, type Locale } from "../lib/locales";
import { message } from "../lib/errors";

const PROJECT = JSON.parse(readFileSync("apple-project.json", "utf8"));
const SCHEME: string = PROJECT.paths.screenshotTarget;
const BUNDLE: string = PROJECT.app.bundleId;
const OUT = "appstore/localized";
const WORK = ".screenshots";

interface Device {
  /** Directory name. Matches the existing hand-captured folders. */
  slug: string;
  /** `simctl` device type name, matched against the available simulators. */
  simulator: string;
}

/**
 * Two devices, because App Store Connect requires exactly two screenshot sets
 * for an app that runs on both: a 6.9-inch iPhone and a 13-inch iPad. Every
 * smaller size is scaled from these by the store itself.
 */
const DEVICES: Device[] = [
  { slug: "iphone-6.9", simulator: "iPhone 17 Pro Max" },
  { slug: "ipad-13", simulator: "iPad Pro 13-inch (M5)" },
];

/**
 * `AppleLocale` wants a POSIX identifier — language plus region — and a bare
 * language code is accepted and then quietly ignored, which shows up as numbers
 * and dates in US format inside an otherwise translated screen. Only the ones
 * that are not `xx_XX` are listed; the rest are derived.
 */
/** Language code -> POSIX locale. Looked up by a runtime string. */
type PosixMap = Record<string, string>;

const POSIX = {
  en: "en_US",
  ja: "ja_JP",
  "zh-Hans": "zh_Hans_CN",
  "zh-Hant": "zh_Hant_TW",
  ko: "ko_KR",
  sv: "sv_SE",
  da: "da_DK",
  nb: "nb_NO",
  cs: "cs_CZ",
  "pt-BR": "pt_BR",
  "es-MX": "es_MX",
  uk: "uk_UA",
  ar: "ar_SA",
  el: "el_GR",
  vi: "vi_VN",
  he: "he_IL",
} satisfies PosixMap;
const posix = (l: Locale) => POSIX[l.ios] ?? `${l.ios}_${l.ios.toUpperCase()}`;

const argv = process.argv.slice(2);
const flag = (n: string) => (argv.indexOf(n) >= 0 ? argv[argv.indexOf(n) + 1] : undefined);
const has = (n: string) => argv.includes(n);

const onlyLangs = flag("--lang")?.split(",").map((s) => s.trim());
const onlyDevice = flag("--device");
const keepGoing = has("--keep-going");
const force = has("--force");

const languages = LOCALES.filter(
  (l) => !onlyLangs || onlyLangs.includes(l.ios) || onlyLangs.includes(l.asc),
);
const devices = DEVICES.filter((d) => !onlyDevice || d.slug === onlyDevice);

/** The first booted-or-available simulator whose name matches, by UDID. */
function udid(name: string): string {
  const raw = Bun.spawnSync(["xcrun", "simctl", "list", "devices", "available", "--json"]).stdout.toString();
  // SAFETY: `simctl list devices --json` documents `devices` as an object of
  // runtime identifier to device array, and the three fields read below are
  // present on every entry. A schema change would surface as an empty walk
  // and the "no simulator named" throw below, not a silent wrong answer.
  const all = JSON.parse(raw).devices as Record<string, { name: string; udid: string; isAvailable: boolean }[]>;
  for (const [runtime, list] of Object.entries(all)) {
    // Newest runtime wins. `simctl` lists them in ascending order, so this walks
    // to the end rather than taking the first match — an iOS 26.2 simulator and
    // an iOS 26.5 one have the same name and only the newer has the current SDK.
    void runtime;
    const hit = [...list].reverse().find((d) => d.name === name && d.isAvailable);
    if (hit) return hit.udid;
  }
  throw new Error(`No available simulator named "${name}". \`xcrun simctl list devices available\` to see what there is.`);
}

/**
 * Exports the attachments out of the result bundle and files them by name.
 *
 * The runner names each attachment `NN-what`; `manifest.json` maps that back to
 * the opaque filename `xcresulttool` writes. Without the manifest the export is
 * a directory of UUIDs in nondeterministic order, which is how a screenshot set
 * ends up with settings first and the home screen fourth.
 */
function fileAttachments(bundle: string, dest: string): number {
  const staging = join(WORK, "export");
  rmSync(staging, { recursive: true, force: true });
  mkdirSync(staging, { recursive: true });

  const r = Bun.spawnSync([
    "xcrun", "xcresulttool", "export", "attachments",
    "--path", bundle, "--output-path", staging,
  ]);
  if (r.exitCode !== 0) throw new Error(`xcresulttool: ${r.stderr.toString().slice(0, 300)}`);

  const manifest = JSON.parse(readFileSync(join(staging, "manifest.json"), "utf8"));
  mkdirSync(dest, { recursive: true });
  for (const old of readdirSync(dest)) rmSync(join(dest, old), { force: true });

  let n = 0;
  for (const test of manifest) {
    for (const a of test.attachments ?? []) {
      // `suggestedHumanReadableName` is what the runner set; the exported file is
      // named by `exportedFileName`. Anything without a screenshot name is a
      // system attachment (a crash log, a diagnostic) and is not ours.
      //
      // XCTest appends its own `_0_<uuid>.png` to the name it was given, so the
      // suffix is cut back to what the runner actually chose. Left on, every
      // filename is unique per run and a re-capture looks like a new set rather
      // than a replacement.
      const raw: string | undefined = a.suggestedHumanReadableName;
      if (!raw || !/^\d\d-/.test(raw)) continue;
      const name = raw.replace(/_\d+_[0-9A-F-]{36}\.png$/i, "").replace(/\.png$/i, "");
      renameSync(join(staging, a.exportedFileName), join(dest, `${name}.png`));
      n++;
    }
  }
  rmSync(staging, { recursive: true, force: true });
  return n;
}

/**
 * Sets the simulator's own language, and leaves it shut down so the next boot
 * comes up in it.
 *
 * The runner already passes `-AppleLanguages` as a launch argument, which is the
 * documented way to do this and does work — when it arrives. It does not always
 * arrive: the same test, unchanged, produced a German app on one run and an
 * English one on the next, while `simctl launch` with the identical arguments
 * was German every time. Rather than keep bisecting an XCTest behaviour, the
 * language is set in two independent places. The launch argument is still there
 * and still wins when it lands; this is what the app falls back to when it does
 * not, and it is a fallback to the right language instead of to English.
 *
 * `defaults write` on a booted device only reaches processes started afterwards,
 * so the device is shut down here and left for `xcodebuild` to boot.
 */
function setDeviceLanguage(device: Device, locale: Locale) {
  const id = udid(device.simulator);
  Bun.spawnSync(["xcrun", "simctl", "boot", id]);
  Bun.spawnSync(["xcrun", "simctl", "bootstatus", id, "-b"]);
  Bun.spawnSync(["xcrun", "simctl", "spawn", id, "defaults", "write", "-g", "AppleLanguages", "-array", locale.ios]);
  Bun.spawnSync(["xcrun", "simctl", "spawn", id, "defaults", "write", "-g", "AppleLocale", "-string", posix(locale)]);

  // Same problem, same fix, one domain over: `-source testSignal` is dropped
  // along with the language arguments, and without it every screenshot shows an
  // em dash where the heart rate should be. The app's own defaults domain
  // outlives a reinstall, so this only has to be written, not re-written after
  // each build. Picture in Picture stays off — a detached window over the app is
  // nondeterminism in a picture that has to look the same in 25 languages.
  Bun.spawnSync(["xcrun", "simctl", "spawn", id, "defaults", "write", BUNDLE, "source", "testSignal"]);
  Bun.spawnSync(["xcrun", "simctl", "spawn", id, "defaults", "write", BUNDLE, "pictureInPicture", "-bool", "false"]);

  Bun.spawnSync(["xcrun", "simctl", "shutdown", id]);
}

function runTest(locale: Locale, device: Device, bundle: string) {
  rmSync(bundle, { recursive: true, force: true });
  setDeviceLanguage(device, locale);

  return Bun.spawnSync(
    [
      "xcodebuild", "test",
      "-project", PROJECT.paths.xcodeproj,
      "-scheme", SCHEME,
      "-destination", `id=${udid(device.simulator)}`,
      "-resultBundlePath", bundle,
      // The target holds a second capture class for the website's workout
      // screens. Without this filter it would run once per language and record
      // twenty-five identical workouts nobody asked for.
      "-only-testing:HeartRateBroadcasterScreenshots/ScreenshotRunner",
      // The build is identical for every language — only the launch arguments
      // change — so nothing is gained by cleaning between runs and about four
      // minutes a language is lost.
      "-derivedDataPath", join(WORK, "DerivedData"),
      "CODE_SIGNING_ALLOWED=NO",
    ],
    {
      // The `TEST_RUNNER_` prefix is load-bearing. A UI test runs in its own
      // process on the simulator, and xcodebuild forwards exactly the variables
      // named this way, stripping the prefix on the way in. Set plainly, they
      // never arrive, the runner falls back to its default, and every language
      // produces an identical set of English screenshots that looks like the
      // capture worked.
      env: {
        ...process.env,
        TEST_RUNNER_SCREENSHOT_LANG: locale.ios,
        TEST_RUNNER_SCREENSHOT_LOCALE: posix(locale),
      },
      stdout: "pipe",
      stderr: "pipe",
    },
  );
}

function capture(locale: Locale, device: Device): number {
  const bundle = join(WORK, `${locale.asc}-${device.slug}.xcresult`);

  // Three attempts, with the simulator shut down and given longer to settle
  // each time. The failure this is for is not in the test:
  //
  //   The request was denied by service delegate (SBMainWorkspace) for reason:
  //   Busy ("Application failed preflight checks")
  //
  // — SpringBoard is still tearing the previous run down when the next one asks
  // to launch. Five seconds clears it most of the time and did not clear it for
  // Dutch on the iPad, so the wait grows: five, then twenty. Over fifty runs
  // this is not a rare event, and losing a language to it costs far more than
  // the minute a retry takes.
  let r = runTest(locale, device, bundle);
  for (const attempt of [1, 2, 3, 4]) {
    if (r.exitCode === 0) break;
    Bun.spawnSync(["xcrun", "simctl", "shutdown", udid(device.simulator)]);
    // The third attempt stops asking nicely. Over a fifty-launch run the
    // failures cluster rather than scatter — two languages in a row, then none
    // for ten — which is the signature of the service getting into a state and
    // not of any one language being unlucky. Shutting every device down and
    // killing CoreSimulatorService is the only thing that has cleared it; the
    // service is launchd-managed and comes back on the next simctl call. Safe
    // here because no test is running at this point in the loop.
    if (attempt === 3) {
      Bun.spawnSync(["xcrun", "simctl", "shutdown", "all"]);
      Bun.spawnSync(["killall", "-9", "com.apple.CoreSimulator.CoreSimulatorService"]);
    }
    // And the fourth erases the device, because restarting the service is not
    // always enough: two combinations — Russian on the iPad, Arabic on the
    // phone — failed six times each across three runs and a service restart,
    // while the same language on the other device passed on the first try. That
    // asymmetry rules out both the service and the language and leaves the
    // device's own state, which only `erase` clears. It costs a few minutes of
    // re-provisioning and it is the last thing tried, so nothing pays for it
    // that a shorter wait would have fixed.
    if (attempt === 4) Bun.spawnSync(["xcrun", "simctl", "erase", udid(device.simulator)]);
    Bun.spawnSync(["sleep", String(attempt === 1 ? 5 : 20)]);
    r = runTest(locale, device, bundle);
  }

  if (r.exitCode !== 0) {
    const log = join(WORK, `${locale.asc}-${device.slug}.log`);
    Bun.write(log, r.stdout.toString() + "\n" + r.stderr.toString());
    throw new Error(`xcodebuild failed — see ${log}`);
  }

  return fileAttachments(bundle, join(OUT, locale.asc, device.slug));
}

mkdirSync(WORK, { recursive: true });

const failures: string[] = [];
for (const locale of languages) {
  for (const device of devices) {
    const label = `${locale.asc.padEnd(8)} ${device.slug.padEnd(11)}`;
    // Already captured, so skip it. A run is fifty simulator launches and an
    // hour; something in it will fail, and the fix for that is re-running the
    // script, which is only a fix if the second run costs the languages that
    // failed rather than all of them. `--force` recaptures regardless.
    const dest = join(OUT, locale.asc, device.slug);
    if (!force && existsSync(dest) && readdirSync(dest).some((f) => f.endsWith(".png"))) {
      console.log(`${label} have`);
      continue;
    }
    try {
      const n = capture(locale, device);
      console.log(`${label} ${n} screenshots`);
      if (n === 0) failures.push(`${locale.asc} ${device.slug}: ran clean but produced nothing`);
    } catch (e) {
      console.error(`${label} ${message(e)}`);
      failures.push(`${locale.asc} ${device.slug}`);
      if (!keepGoing) {
        console.error("\nStopped. --keep-going to carry on past a failing language.");
        process.exit(1);
      }
    }
  }
}

// The result bundles are large and only useful while something is wrong. The
// derived data stays: it is what makes the second language take one minute
// instead of five.
for (const f of readdirSync(WORK)) {
  if (f.endsWith(".xcresult")) rmSync(join(WORK, f), { recursive: true, force: true });
}

console.log(`\n${languages.length} languages × ${devices.length} devices → ${OUT}/`);
if (failures.length) {
  console.log("\nFailed:");
  for (const f of failures) console.log(`  ${f}`);
  process.exit(1);
}
