import { readFileSync } from "node:fs";
import { Client } from "../lib/asc";

const appId: string = JSON.parse(readFileSync("apple-project.json", "utf8")).appStoreConnect.appleId;
const c = new Client();

for (const s of await c.all(`/v1/apps/${appId}/reviewSubmissions?limit=5`)) {
  if (s.attributes.state !== "WAITING_FOR_REVIEW" && s.attributes.state !== "READY_FOR_REVIEW") continue;
  await c.patch(`/v1/reviewSubmissions/${s.id}`, {
    data: { type: "reviewSubmissions", id: s.id, attributes: { canceled: true } },
  });
  console.log("cancelled", s.id);
}
for (const v of await c.all(`/v1/apps/${appId}/appStoreVersions?limit=5`)) {
  console.log("version", v.attributes.versionString, v.attributes.appStoreState);
}
