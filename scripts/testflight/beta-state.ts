// Read-only. Why the public link says it is not taking testers, and what state
// version 1.0 is in after the developer rejection.
import { readFileSync } from "node:fs";
import { Client } from "../lib/asc";

const appId: string = JSON.parse(readFileSync("apple-project.json", "utf8")).appStoreConnect.appleId;
const c = new Client();

for (const g of await c.all(`/v1/apps/${appId}/betaGroups?limit=20`)) {
  const a = g.attributes;
  console.log("group", g.id, a.name,
    "public:", a.publicLinkEnabled, "limitOn:", a.publicLinkLimitEnabled, "limit:", a.publicLinkLimit,
    "\n  link", a.publicLink);
  for (const b of await c.all(`/v1/betaGroups/${g.id}/builds?limit=10`)) {
    console.log("  build", b.attributes.version, b.attributes.processingState, "expired:", b.attributes.expired);
  }
}

for (const b of await c.all(`/v1/builds?filter[app]=${appId}&limit=4&sort=-version`)) {
  const d = (await c.request("GET", `/v1/builds/${b.id}/buildBetaDetail`)).data;
  console.log("build", b.attributes.version, b.attributes.processingState,
    "internal:", d?.attributes?.internalBuildState, "external:", d?.attributes?.externalBuildState);
}

for (const b of await c.all(`/v1/builds?filter[app]=${appId}&limit=1&sort=-version`)) {
  for (const s of await c.all(`/v1/betaAppReviewSubmissions?filter[build]=${b.id}`)) {
    console.log("beta review submission", s.id, s.attributes.betaReviewState);
  }
}

for (const v of await c.all(`/v1/apps/${appId}/appStoreVersions?limit=3`)) {
  console.log("version", v.attributes.versionString, v.attributes.appStoreState, v.id);
  for (const s of await c.all(`/v1/appStoreVersions/${v.id}/appStoreVersionSubmission`).catch(() => [])) {
    console.log("  submission", s.id);
  }
}
