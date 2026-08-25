// The beta app localization (TestFlight "Test Information") did not exist, so
// it has to be created rather than patched. Also caps the public link at 100
// testers, which is what makes the link hand out installs rather than sit there.
import { readFileSync } from "node:fs";
import { Client } from "../lib/asc";

const project = JSON.parse(readFileSync("apple-project.json", "utf8"));
const appId: string = project.appStoreConnect.appleId;
const c = new Client();

const SITE: string = project.listing.marketingUrl;
const EMAIL: string = project.review.contactEmail;

const DESCRIPTION = `HeartRate Broadcaster turns an iPhone into a standard Bluetooth LE heart rate sensor. It reads live heart rate from an Apple Watch and, optionally, AirPods Pro 3, reconciles the two into a single value, and re-advertises it as the Bluetooth Heart Rate Service (0x180D). Bike computers and training apps - MyWhoosh, Zwift, TrainerRoad, Wahoo, Bluetooth-capable Garmin Edge units - pair with the phone as though it were a chest strap.

What to test:
- Pair from a head unit or training app with the app in the foreground, then confirm the subscriber count rises and BPM tracks the watch.
- Set Heart Rate Source to Test Signal to verify pairing without wearing anything.
- With both watch and AirPods selected, check the Sensor Agreement row: readings that agree are averaged, an outlier is rejected.
- Lock the phone after pairing and confirm the broadcast survives.

Known limits: discovery needs the app in the foreground, because iOS stops advertising a backgrounded app's service UUID. ANT+ is not supported and cannot be, as an iPhone has no ANT+ radio.

No account, no server, no analytics. Heart rate is read on device and leaves only over Bluetooth.`;

const existing = await c.all(`/v1/apps/${appId}/betaAppLocalizations?limit=50`);
if (existing.length === 0) {
  await c.post("/v1/betaAppLocalizations", {
    data: {
      type: "betaAppLocalizations",
      attributes: {
        locale: "en-US",
        description: DESCRIPTION,
        feedbackEmail: EMAIL,
        marketingUrl: SITE,
        privacyPolicyUrl: project.listing.privacyPolicyUrl,
      },
      relationships: { app: { data: { type: "apps", id: appId } } },
    },
  });
  console.log("created en-US test information");
} else {
  for (const l of existing) {
    await c.patch(`/v1/betaAppLocalizations/${l.id}`, {
      data: {
        type: "betaAppLocalizations",
        id: l.id,
        attributes: {
          description: DESCRIPTION,
          feedbackEmail: EMAIL,
          marketingUrl: SITE,
          privacyPolicyUrl: project.listing.privacyPolicyUrl,
        },
      },
    });
    console.log("updated", l.attributes.locale);
  }
}

// A public link with no cap is accepted by the API but reads as unlimited in
// App Store Connect; 100 is the number asked for and can be raised later
// without breaking the URL.
const group = (await c.all(`/v1/apps/${appId}/betaGroups?limit=20`))
  .find((g: any) => g.attributes.name === "Public Beta");

if (group) {
  const res = await c.patch(`/v1/betaGroups/${group.id}`, {
    data: {
      type: "betaGroups",
      id: group.id,
      attributes: { publicLinkEnabled: true, publicLinkLimitEnabled: true, publicLinkLimit: 100 },
    },
  });
  const a = res.data.attributes;
  console.log("link", a.publicLink, "limit", a.publicLinkLimit, "enabled", a.publicLinkLimitEnabled);
}
