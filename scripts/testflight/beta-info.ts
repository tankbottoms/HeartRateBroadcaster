// Fills in TestFlight "Test Information": the beta app description and support
// URLs external testers see, and the review contact Beta App Review requires.
//
// Both records already exist for any app that has a build, so these are PATCHes
// rather than POSTs; App Store Connect creates them empty.
import { readFileSync } from "node:fs";
import { Client } from "../lib/asc";

const project = JSON.parse(readFileSync("apple-project.json", "utf8"));
const appId: string = project.appStoreConnect.appleId;
const review = project.review;
const c = new Client();

const SITE: string = project.listing.marketingUrl ?? "https://heart-rate.atsignhandle.xyz";
const EMAIL: string = review.contactEmail;

const DESCRIPTION = `HeartRate Broadcaster turns an iPhone into a standard Bluetooth LE heart rate sensor. It reads live heart rate from an Apple Watch and, optionally, AirPods Pro 3, reconciles the two into a single value, and re-advertises it as the Bluetooth Heart Rate Service (0x180D). Bike computers and training apps — MyWhoosh, Zwift, TrainerRoad, Wahoo, Bluetooth-capable Garmin Edge units — pair with the phone as though it were a chest strap.

What to test:
- Pair the phone from a head unit or training app while the HRB app is in the foreground, then confirm the subscriber count rises and BPM tracks the watch.
- Set Heart Rate Source to Test Signal to verify pairing without wearing anything.
- With both watch and AirPods selected, check the Sensor Agreement row: readings that agree are averaged, an outlier is rejected.
- Lock the phone after pairing and confirm the broadcast survives.

Known limits: discovery requires the app in the foreground, because iOS stops advertising a backgrounded app's service UUID. ANT+ is not supported and cannot be — an iPhone has no ANT+ radio.

No account, no server, no analytics. Heart rate is read on device and leaves only over Bluetooth.`;

const NOTES = `A watchOS companion app ships with the build and must be installed for the primary heart rate source. To test without a watch, open the app and set Heart Rate Source to "Test Signal", which generates a synthetic 50-100 BPM on the phone itself and exercises the whole Bluetooth path.

No sign-in of any kind exists, so no demo account is needed. HealthKit permission is requested on first launch; Bluetooth permission is requested when broadcasting starts.`;

// Test Information — one record per locale; only the primary is required.
for (const l of await c.all(`/v1/apps/${appId}/betaAppLocalizations?limit=50`)) {
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
  console.log("test info", l.attributes.locale);
}

// Beta App Review contact — required before an external build can be reviewed.
const detail = (await c.request("GET", `/v1/apps/${appId}/betaAppReviewDetail`)).data;

if (detail) {
  await c.patch(`/v1/betaAppReviewDetails/${detail.id}`, {
    data: {
      type: "betaAppReviewDetails",
      id: detail.id,
      attributes: {
        contactEmail: review.contactEmail,
        contactFirstName: review.contactFirstName,
        contactLastName: review.contactLastName,
        contactPhone: review.contactPhone,
        demoAccountRequired: false,
        notes: NOTES,
      },
    },
  });
  console.log("review detail", detail.id);
} else {
  console.log("no betaAppReviewDetail found");
}
