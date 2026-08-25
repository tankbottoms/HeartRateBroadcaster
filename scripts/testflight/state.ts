import { readFileSync } from "node:fs";
import { Client } from "../lib/asc";

const appId: string = JSON.parse(readFileSync("apple-project.json", "utf8")).appStoreConnect.appleId;
const c = new Client();

for (const v of await c.all(`/v1/apps/${appId}/appStoreVersions?limit=10`)) {
  console.log("version", v.attributes.versionString, v.attributes.appStoreState, v.attributes.createdDate);
}
for (const s of await c.all(`/v1/apps/${appId}/reviewSubmissions?limit=5`).catch(() => [])) {
  console.log("submission", s.attributes.state, s.attributes.submittedDate);
}
