// Export compliance on the build. Left null, App Store Connect blocks the
// submission and asks the question in the UI instead; false is the answer for an
// app whose only cryptography is Apple's own TLS, of which there is none here.
import { readFileSync } from "node:fs";
import { Client } from "../lib/asc";

const appId: string = JSON.parse(readFileSync("apple-project.json", "utf8")).appStoreConnect.appleId;
const c = new Client();

const build = (await c.all(`/v1/builds?filter[app]=${appId}&limit=3&sort=-version`))[0];
await c.patch(`/v1/builds/${build.id}`, {
  data: { type: "builds", id: build.id, attributes: { usesNonExemptEncryption: false } },
});
console.log("build", build.attributes.version, "export compliance set");
