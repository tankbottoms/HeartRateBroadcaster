// Hands the newest processed build to the public TestFlight group and submits it
// for Beta App Review, which is what external testing requires. Also writes the
// per-build "What to Test" note.
import { readFileSync } from "node:fs";
import { Client } from "../lib/asc";

const project = JSON.parse(readFileSync("apple-project.json", "utf8"));
const appId: string = project.appStoreConnect.appleId;
const c = new Client();

const WHATS_NEW = `First public beta.

Pair a head unit or training app while the app is in the foreground, then check that the subscriber count rises and BPM tracks the watch. Set Heart Rate Source to Test Signal to verify pairing without wearing anything. With watch and AirPods both selected, the Sensor Agreement row shows what was averaged and what was rejected.

The About screen and Settings both carry a language picker; the app is translated into twenty-five languages and follows the device by default.`;

const builds = await c.all(`/v1/builds?filter[app]=${appId}&limit=5&sort=-version`);
const build = builds.find((b: any) => b.attributes.processingState === "VALID" && !b.attributes.expired);
if (!build) {
  console.log("no processed build yet:", builds.map((b: any) => `${b.attributes.version} ${b.attributes.processingState}`).join(", "));
  process.exit(0);
}
console.log("build", build.attributes.version, build.id);

// What to Test, per build and per locale. Created empty by App Store Connect.
for (const l of await c.all(`/v1/builds/${build.id}/betaBuildLocalizations?limit=50`)) {
  await c.patch(`/v1/betaBuildLocalizations/${l.id}`, {
    data: { type: "betaBuildLocalizations", id: l.id, attributes: { whatsNew: WHATS_NEW } },
  });
  console.log("whats new", l.attributes.locale);
}

const group = (await c.all(`/v1/apps/${appId}/betaGroups?limit=20`))
  .find((g: any) => g.attributes.name === "Public Beta");

await c.post(`/v1/betaGroups/${group.id}/relationships/builds`, {
  data: [{ type: "builds", id: build.id }],
});
console.log("added to Public Beta");

// External testing is gated on Beta App Review; internal testers get the build
// the moment it is added to a group, external ones only after this passes.
try {
  await c.post("/v1/betaAppReviewSubmissions", {
    data: {
      type: "betaAppReviewSubmissions",
      relationships: { build: { data: { type: "builds", id: build.id } } },
    },
  });
  console.log("submitted for beta app review");
} catch (e) {
  console.log("beta review submit:", String(e).slice(0, 300));
}
