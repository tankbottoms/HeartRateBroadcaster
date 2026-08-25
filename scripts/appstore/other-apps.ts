// Read-only. Lists every app on the team and, for anything that is not HRB, its
// TestFlight groups and unexpired builds — so "remove Reed's Black Box from
// TestFlight" can be aimed at a specific build before anything is expired.
import { Client } from "../lib/asc";

const c = new Client();

for (const app of await c.all("/v1/apps?limit=50")) {
  console.log("app", app.id, app.attributes.name, app.attributes.bundleId);
  for (const g of await c.all(`/v1/apps/${app.id}/betaGroups?limit=20`)) {
    const a = g.attributes;
    console.log("   group", g.id, a.name, "public:", a.publicLinkEnabled, a.publicLink ?? "");
  }
  for (const b of await c.all(`/v1/builds?filter[app]=${app.id}&limit=5&sort=-version`)) {
    console.log("   build", b.id, b.attributes.version, "expired:", b.attributes.expired);
  }
}
