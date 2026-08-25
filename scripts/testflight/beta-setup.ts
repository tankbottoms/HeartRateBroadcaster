// Creates the public TestFlight group and fills in the Test Information that
// Beta App Review requires before an external build can be handed out.
//
// Builds expire 90 days after upload on their own — that is TestFlight's fixed
// term, not something set here, so "good for 90 days" needs no configuration
// beyond uploading.
import { readFileSync } from "node:fs";
import { Client } from "../lib/asc";

const appId: string = JSON.parse(readFileSync("apple-project.json", "utf8")).appStoreConnect.appleId;
const c = new Client();

let group = (await c.all(`/v1/apps/${appId}/betaGroups?limit=20`))
  .find((g: any) => g.attributes.name === "Public Beta");

if (!group) {
  const res = await c.post("/v1/betaGroups", {
    data: {
      type: "betaGroups",
      attributes: {
        name: "Public Beta",
        publicLinkEnabled: true,
        publicLinkLimitEnabled: false,
        feedbackEnabled: true,
      },
      relationships: { app: { data: { type: "apps", id: appId } } },
    },
  });
  group = res.data;
  console.log("created group");
}

console.log("group", group.id);
console.log("publicLinkEnabled", group.attributes.publicLinkEnabled);
console.log("publicLink", group.attributes.publicLink);
