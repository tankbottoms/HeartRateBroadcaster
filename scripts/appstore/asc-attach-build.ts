#!/usr/bin/env bun
/**
 * Attaches the newest processed build to the editable version.
 *
 * Uploading a build and selecting it are separate acts. `altool` finishes the
 * moment the bytes are accepted; the build then processes for ten to thirty
 * minutes, and until it reaches VALID it cannot be selected at all. A version
 * left with an older build attached looks finished in every screen except the
 * one that matters, so this waits and then makes the selection.
 *
 *   bun scripts/asc-attach-build.ts            # attach the newest VALID build
 *   bun scripts/asc-attach-build.ts --wait     # poll until one is VALID
 */

import { readFileSync } from "node:fs";
import { Client } from "../lib/asc";

const appId: string = JSON.parse(readFileSync("apple-project.json", "utf8")).appStoreConnect.appleId;
const c = new Client();
const wait = process.argv.includes("--wait");

const EDITABLE = new Set([
  "PREPARE_FOR_SUBMISSION",
  "DEVELOPER_REJECTED",
  "REJECTED",
  "METADATA_REJECTED",
  "INVALID_BINARY",
]);

const versions = await c.all(`/v1/apps/${appId}/appStoreVersions?limit=50`);
const version = versions.find((v: any) => EDITABLE.has(v.attributes.appStoreState));
if (!version) throw new Error("no editable version");

// `sort` is rejected on the app's builds relationship — "The parameter 'sort'
// can not be used with this request" — and the default order is not newest
// first, so sort here. The build number is a string holding an integer.
const newest = async () => {
  const builds = await c.all(`/v1/apps/${appId}/builds?limit=20`);
  return builds.sort(
    (a: any, b: any) => Number(b.attributes.version) - Number(a.attributes.version),
  )[0];
};

// A build does not appear in this list at all for the first several minutes
// after upload, so "the newest one visible" is the newest *older* build for a
// while — long enough to attach the wrong binary and think it worked. Naming
// the expected number makes that impossible.
const flag = process.argv.indexOf("--build");
const want = flag === -1 ? null : Number(process.argv[flag + 1]);

let build = want
  ? (await c.all(`/v1/apps/${appId}/builds?limit=20`)).find(
      (b: any) => Number(b.attributes.version) === want,
    )
  : await newest();

// PROCESSING is the normal state for the first half hour. FAILED and INVALID
// are terminal and waiting on them is waiting forever, so stop on those.
while (wait && (!build || build.attributes.processingState === "PROCESSING")) {
  console.log(build ? `build ${build.attributes.version} still processing` : `waiting for build ${want}`);
  await new Promise((r) => setTimeout(r, 60_000));
  build = want
    ? (await c.all(`/v1/apps/${appId}/builds?limit=20`)).find(
        (b: any) => Number(b.attributes.version) === want,
      )
    : await newest();
}

if (!build) throw new Error("no builds");
const state = build.attributes.processingState;
if (state !== "VALID") {
  console.log(`build ${build.attributes.version} is ${state}, not attaching`);
  process.exit(1);
}

const current = (await c.request("GET", `/v1/appStoreVersions/${version.id}/build`))?.data;
if (current?.id === build.id) {
  console.log(`build ${build.attributes.version} already attached`);
  process.exit(0);
}

await c.request("PATCH", `/v1/appStoreVersions/${version.id}/relationships/build`, {
  data: { type: "builds", id: build.id },
});

console.log(
  `attached build ${build.attributes.version} to ${version.attributes.versionString}` +
    (current?.id ? ` (was ${current.id})` : ""),
);
