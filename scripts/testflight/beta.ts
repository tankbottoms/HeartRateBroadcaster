// Reads the TestFlight side of the app: beta groups, public links, and the
// processing state of recent builds. Nothing here mutates.
import { readFileSync } from "node:fs";
import { Client } from "../lib/asc";

const appId: string = JSON.parse(readFileSync("apple-project.json", "utf8")).appStoreConnect.appleId;
const c = new Client();

for (const g of await c.all(`/v1/apps/${appId}/betaGroups?limit=20`)) {
  const a = g.attributes;
  console.log("group", g.id, JSON.stringify({
    name: a.name,
    internal: a.isInternalGroup,
    publicLinkEnabled: a.publicLinkEnabled,
    publicLink: a.publicLink,
    publicLinkLimitEnabled: a.publicLinkLimitEnabled,
    publicLinkLimit: a.publicLinkLimit,
    autoNotify: a.feedbackEnabled,
  }));
}

for (const b of await c.all(`/v1/builds?filter[app]=${appId}&limit=5&sort=-version`)) {
  const a = b.attributes;
  console.log("build", b.id, a.version, a.processingState, "expired:", a.expired, "expiry:", a.expirationDate);
}
