#!/usr/bin/env bun
/**
 * Writes the TestFlight "What to Test" note onto the newest build, and hands
 * that build to the testers.
 *
 *   bun scripts/asc-testflight.ts            # newest build
 *   bun scripts/asc-testflight.ts 271        # a particular build number
 *   bun scripts/asc-testflight.ts --notes    # write the note, distribute nothing
 *
 * Uploading a build does not release it. A build that nobody has added to a
 * group is visible in App Store Connect and invisible to every tester, which is
 * how three builds in a row came to be uploaded while the public link still
 * served the one from a week earlier. Adding it to the public group is the step
 * that publishes it, and for an external group that also submits it to beta
 * review — a shorter queue than the App Store's, and a separate one.
 *
 * Separate from `asc-push.ts` on purpose. That one edits the App Store listing,
 * which is locked the moment a version enters review; a build's beta
 * localization is a different resource and stays editable throughout — so this
 * is the one thing that can still be said to testers while 1.0 waits in the
 * queue.
 *
 * The text comes from `whatsNew` in `appstore/metadata/en-US.json`, so the note
 * testers read and the note the App Store will carry are the same sentence
 * rather than two descriptions of the same release that drifted apart. Apple
 * allows 4000 characters here.
 *
 * A build that is still processing has no beta localization to patch yet and
 * this will say so rather than inventing one.
 */

import { readFileSync } from "node:fs";
import { Client, body } from "../lib/asc";

const LIMIT = 4000;
const LOCALE = "en-US";

const project = JSON.parse(readFileSync("apple-project.json", "utf8"));
const appId: string = project.appStoreConnect.appleId;
const notes: string = JSON.parse(readFileSync(`appstore/metadata/${LOCALE}.json`, "utf8")).whatsNew;

if (!notes) throw new Error(`No whatsNew in appstore/metadata/${LOCALE}.json`);
if (notes.length > LIMIT) throw new Error(`whatsNew is ${notes.length} characters, over ${LIMIT}`);

const args = process.argv.slice(2);
const notesOnly = args.includes("--notes");
const wanted = args.find((a) => !a.startsWith("-"));
const client = new Client();

const builds = await client.all(
  `/v1/builds?filter[app]=${appId}&sort=-version&limit=20` +
  `&fields[builds]=version,processingState,uploadedDate,expired`,
);
const build = wanted
  ? builds.find((b) => b.attributes?.version === wanted)
  : builds[0];

if (!build) throw new Error(wanted ? `No build ${wanted}` : "No builds at all");

const state = build.attributes?.processingState;
console.log(`Build ${build.attributes?.version} — ${state}, uploaded ${build.attributes?.uploadedDate}`);
if (state !== "VALID") {
  console.log("Still processing. Run this again once it is VALID.");
  process.exit(0);
}

// One localization per language, created on first use and patched after that.
// Apple returns the existing one rather than a second, but only if it is asked
// for by build; creating blind gives a 409 that reads like a permissions error.
const existing = await client.all(`/v1/builds/${build.id}/betaBuildLocalizations`);
const mine = existing.find((l) => l.attributes?.locale === LOCALE);

if (mine) {
  await client.patch(`/v1/betaBuildLocalizations/${mine.id}`,
                     body("betaBuildLocalizations", { whatsNew: notes }, undefined, mine.id));
  console.log(`Updated ${LOCALE} release notes (${notes.length} characters).`);
} else {
  await client.post("/v1/betaBuildLocalizations",
                    body("betaBuildLocalizations", { locale: LOCALE, whatsNew: notes },
                         { build: { data: { type: "builds", id: build.id } } }));
  console.log(`Created ${LOCALE} release notes (${notes.length} characters).`);
}

if (notesOnly) process.exit(0);

// A build's own `betaGroups` relationship answers only to CREATE and DELETE —
// asking it which groups a build is in is a 403. The membership is read from
// the other end, one group at a time, which is also the only way to find out
// which build the public link is currently serving.
const groups = await client.all(
  `/v1/apps/${appId}/betaGroups?fields[betaGroups]=name,isInternalGroup,publicLinkEnabled`,
);
if (!groups.length) {
  console.log("No beta groups on this app. Nothing to distribute to.");
  process.exit(0);
}

for (const group of groups) {
  const name = group.attributes?.name ?? group.id;
  const already = await client.all(`/v1/betaGroups/${group.id}/builds?fields[builds]=version&limit=50`);
  if (already.some((b) => b.id === build.id)) {
    console.log(`${name}: already has build ${build.attributes?.version}.`);
    continue;
  }

  // Adding a build to a group is a relationship POST rather than a resource
  // one, so it carries no attributes and returns 204 with an empty body.
  await client.post(`/v1/betaGroups/${group.id}/relationships/builds`, {
    data: [{ type: "builds", id: build.id }],
  });

  const external = group.attributes?.isInternalGroup === false;
  console.log(
    `${name}: build ${build.attributes?.version} distributed` +
      (external ? " and submitted to beta review." : "."),
  );
}
