#!/usr/bin/env bun
// Validates and uploads an .ipa to App Store Connect via the asc CLI.
//
// Replaces the former upload-build.sh, which drove `xcrun altool --validate-app`
// and `--upload-app`. asc does the same work in one authenticated call and can
// read back what Apple actually recorded, which altool cannot.
//
// Apple identifiers come from apple-project.json (gitignored). Nothing here
// takes a key path: asc resolves the signing key from its own keychain profile,
// so the .p8 never has to be located, copied, or passed on a command line.
//
// The build number is deliberately NOT passed. asc extracts CFBundleVersion
// from the archive, so the number uploaded is the number that was built -- there
// is no second source of truth to drift. What this script does instead is ask
// Apple for the next safe number and compare it against the local counter,
// because an upload that collides with an existing build is rejected and a
// rejected upload still burns the number.

import { existsSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { homedir } from "node:os";

const ASC = "/opt/homebrew/bin/asc";

function findRepoRoot(from: string): string {
  let dir = resolve(from);
  for (;;) {
    if (existsSync(join(dir, "apple-project.json"))) return dir;
    const up = dirname(dir);
    if (up === dir) throw new Error("apple-project.json not found in any parent directory");
    dir = up;
  }
}

const root = findRepoRoot(process.cwd());
const cfg = await Bun.file(join(root, "apple-project.json")).json();

const appId: string = cfg.appStoreConnect?.appleId ?? "";
const scheme: string = cfg.paths?.scheme ?? "";
const brand: string = cfg.site?.brand ?? cfg.app?.name ?? scheme;
const version: string = cfg.app?.marketingVersion ?? "";
if (!appId) throw new Error("apple-project.json: appStoreConnect.appleId is required");
if (!scheme) throw new Error("apple-project.json: paths.scheme is required");

const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const positional = args.filter((a) => !a.startsWith("--"));
const ipa = resolve(positional[0] ?? join(homedir(), "Downloads", brand, "build", `${scheme}.ipa`));

if (!existsSync(ipa)) {
  console.error(`no archive at ${ipa}`);
  console.error("pass a path explicitly, or run the export step first");
  process.exit(1);
}
const mb = (statSync(ipa).size / 1_048_576).toFixed(1);
console.log(`archive  ${ipa} (${mb} MB)`);
console.log(`app      ${appId}  ${cfg.app?.name ?? ""}  version ${version || "(unset)"}`);

// What Apple already has. A failure here is informational, not fatal: it must
// not become the reason an otherwise-valid upload does not happen.
let liveNext: number | null = null;
let liveLatest: number | null = null;
const nbn = Bun.spawnSync([ASC, "builds", "next-build-number", "--app", appId, "--output", "json"]);
if (nbn.exitCode === 0) {
  try {
    const j = JSON.parse(nbn.stdout.toString());
    const d = j.data ?? j;
    liveNext = d.nextBuildNumber == null ? null : Number(d.nextBuildNumber);
    liveLatest = d.latestObservedBuildNumber == null ? null : Number(d.latestObservedBuildNumber);
    console.log(`live     latest observed ${liveLatest ?? "none"}, next safe ${liveNext ?? "unknown"}`);
  } catch {
    console.log("live     build numbers unreadable (asc returned non-JSON)");
  }
} else {
  console.log(`live     build-number query failed: ${nbn.stderr.toString().trim().split("\n")[0]}`);
}

// The local counter is incremented by the xcodegen prebuild step and committed,
// so it is the number inside the archive. If Apple has already seen it, the
// upload will be rejected.
const xcconfig = join(root, "build_number.xcconfig");
if (existsSync(xcconfig)) {
  const m = (await Bun.file(xcconfig).text()).match(/^\s*CURRENT_PROJECT_VERSION\s*=\s*(\d+)/m);
  const local = m ? Number(m[1]) : null;
  if (local != null) {
    console.log(`local    build_number.xcconfig CURRENT_PROJECT_VERSION = ${local}`);
    if (liveLatest != null && local <= liveLatest) {
      console.error(`\nlocal build number ${local} is not ahead of Apple's ${liveLatest}; this upload would be rejected.`);
      console.error(`set CURRENT_PROJECT_VERSION to ${liveNext ?? liveLatest + 1} and rebuild before uploading.`);
      process.exit(1);
    }
  }
}

// --verify-timeout watches for immediate post-commit processing failures. asc
// rejects it alongside --dry-run, which commits nothing and so has nothing to watch.
const cmd = [ASC, "builds", "upload", "--app", appId, "--ipa", ipa];
if (dryRun) cmd.push("--dry-run");
else cmd.push("--verify-timeout", "180s");
console.log(`\n${dryRun ? "reserving (dry run)" : "uploading"}...`);
const up = Bun.spawnSync(cmd, { stdout: "inherit", stderr: "inherit" });
if (up.exitCode !== 0) process.exit(up.exitCode ?? 1);

if (!dryRun) {
  console.log("\nrecorded by App Store Connect:");
  Bun.spawnSync([ASC, "builds", "info", "--app", appId, "--latest"], { stdout: "inherit", stderr: "inherit" });
}
