// Read-only. What happens the moment review approves 1.0: does it go on sale by
// itself, at what price, and in which territories.
import { readFileSync } from "node:fs";
import { Client } from "../lib/asc";

const appId: string = JSON.parse(readFileSync("apple-project.json", "utf8")).appStoreConnect.appleId;
const c = new Client();

const v = (await c.all(`/v1/apps/${appId}/appStoreVersions?limit=1`))[0];
const a = v.attributes;
console.log("version", a.versionString, a.appStoreState);
console.log("  releaseType", a.releaseType, "| earliestRelease", a.earliestReleaseDate ?? "none");
console.log("  downloadable", a.downloadable);

for (const p of ["appAvailabilityV2", "appPriceSchedule"]) {
  try {
    const r = await c.request("GET", `/v1/apps/${appId}/${p}`);
    console.log(p, JSON.stringify(r.data?.attributes ?? r.data?.id ?? {}));
  } catch (e) {
    console.log(p, String(e).slice(0, 140));
  }
}

// The price itself lives one hop away, on the schedule's manual prices.
try {
  const prices = await c.all(`/v1/appPriceSchedules/${appId}/manualPrices?include=appPricePoint&limit=5`);
  for (const p of prices) console.log("manual price", p.id, JSON.stringify(p.attributes));
} catch (e) {
  console.log("manualPrices", String(e).slice(0, 140));
}

try {
  const terr = await c.all(`/v1/appAvailabilities/${appId}/territoryAvailabilities?limit=200`);
  console.log("territories", terr.length, "available:", terr.filter((t: any) => t.attributes.available).length);
} catch (e) {
  console.log("territoryAvailabilities", String(e).slice(0, 140));
}
