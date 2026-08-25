# App Store Connect — HeartRate Broadcaster

Everything needed to create the App Store Connect record, plus a prompt to hand
to the Claude extension in Chrome so it can do the data entry with the browser
already signed in.

Assets live at an unlinked path on the marketing site so the extension can fetch
them directly rather than being handed files:

```
https://heart-rate.atsignhandle.xyz/press/
```

That folder is `noindex` and is not linked from anywhere, but it is not
protected. It holds only material that is going on the App Store anyway.
Regenerate it with `bun scripts/prepare-screenshots.ts && bun scripts/publish-press-kit.ts`,
then `cd web && bunx wrangler deploy`.

---

## Prompt for the Claude extension in Chrome

The prompt lives on its own in [`asc-chrome-prompt.md`](asc-chrome-prompt.md) so
the whole file can be selected and pasted without picking it out of surrounding
notes. Open App Store Connect, sign in, then paste it. What follows here is the
same content annotated — read this one, paste that one.

---

You are working in App Store Connect for the Apple Developer account that is
already signed in to this browser. Create and populate the app record for
**HeartRate Broadcaster**. Do not submit for review, and do not change pricing or
availability — stop before any irreversible step and tell me what is left.

All assets are published at
`https://heart-rate.atsignhandle.xyz/press/`. Start by
fetching `manifest.json` from that folder — it lists the app icon and every
screenshot with its caption and its App Store Connect device class, keyed by
`iphone-6.9`, `ipad-13`, and `watch-46mm`. Resolve each `file` path relative to
the press folder. Upload screenshots in the numeric order of their filenames;
that order is deliberate, because the first three are what appear in search
results.

### 1. Create the app

| Field | Value |
| --- | --- |
| Platforms | iOS (includes iPadOS), watchOS |
| Name | HeartRate Broadcaster |
| Primary language | English (U.S.) |
| Bundle ID | `xyz.atsignhandle.heart-rate-broadcaster` |
| SKU | HEARTRATE-BROADCAST-001 |
| User access | Full Access |

If the bundle ID is not in the dropdown, stop and tell me — it has to be
registered on the Developer portal first.

### 2. App information

- **Subtitle:** Apple Watch heart rate, on any bike computer
- **Category:** Primary — Health & Fitness. Secondary — Sports.
- **Content rights:** does not contain, show, or access third-party content.
- **Age rating:** answer every question "None" / "No". Expected result: 4+.

### 3. Version information (1.0)

**Promotional text**

> Your Apple Watch already measures your heart rate. This puts that number on
> your bike computer, your trainer app, or anything else that pairs a Bluetooth
> chest strap.

**Description**

> HeartRate Broadcaster turns your iPhone into a standard Bluetooth heart rate
> monitor, fed by the sensors you already wear.
>
> Your Apple Watch and AirPods Pro 3 measure your heart rate continuously, but
> nothing else can read them. Training apps and bike computers expect a
> Bluetooth chest strap. HeartRate Broadcaster bridges the two: it reads live
> heart rate from your watch and AirPods, reconciles them into a single reading,
> and rebroadcasts it as a standard Bluetooth LE Heart Rate Service. Your
> training app sees an ordinary strap.
>
> TWO SENSORS, ONE NUMBER
> When the watch and AirPods both report, the app averages readings that agree
> and rejects the outlier when they disagree, preferring whichever is closer to
> the trend it has already seen. Head units only ever see one sensor. The
> Sensor Agreement row shows which sensors are live, how far apart they are, and
> which number went out — so you never have to take the app's word for it.
>
> GLANCEABLE WHILE YOU RIDE
> A Live Activity puts the current BPM, its source, and whether a head unit is
> actually subscribed on the Lock Screen and in the Dynamic Island. Picture in
> Picture keeps the number floating over your training app. On the watch, a
> one-second press locks the touch screen against a jersey sleeve or a grab at
> the bar tape; another press releases it.
>
> DIAGNOSTICS THAT TELL THE TRUTH
> Connected devices by identifier, frames sent per subscriber, live frame rate,
> the exact bytes of the last frame, and how long ago it went out. When
> something is not working, you can see which half of the link is at fault. A
> permissions screen shows every permission the app needs, what it is currently
> set to, and a direct link to change it.
>
> WHAT IT CANNOT DO
> Apple provides no API for a third-party app to read a Bluetooth chest strap or
> another phone's sensors, so this app cannot import one. It broadcasts over
> Bluetooth LE only — ANT+ is a separate radio that iPhones do not have.
>
> Works with MyWhoosh, Zwift, TrainerRoad, Wahoo, and Bluetooth-capable Garmin
> Edge units. Requires iOS 26 and, for the watch app, watchOS 11.

**Keywords** (100 characters max, no spaces after commas)

```
heart rate,bluetooth,cycling,zwift,mywhoosh,strap,ANT,watch,airpods,broadcast,trainer,BLE,sensor
```

**Support URL:** `https://heart-rate.atsignhandle.xyz/`
**Marketing URL:** `https://heart-rate.atsignhandle.xyz/`
**Privacy Policy URL:** `https://heart-rate.atsignhandle.xyz/privacy.html`

**What's New in This Version:** leave blank — this is version 1.0.

### 4. Screenshots

Upload from the manifest, in filename order:

- **iPhone 6.9"** — all eight, already exactly 1320x2868.
- **Apple Watch** — both, already exactly 416x496.
- **iPad 13"** — the manifest lists none. Skip iPad entirely and tell me it is
  outstanding; do not substitute an iPhone screenshot.

The `caption` in the manifest is context for you, not a field to fill in — App
Store Connect has no caption field for screenshots.

### 5. App icon

`icon-1024.png` from the press folder, 1024x1024, no alpha.

### 6. App privacy

The app collects no data. Answer "No, we do not collect data from this app."
Heart rate is read from HealthKit and broadcast over Bluetooth to devices the
user pairs; it is never sent to a server and never leaves the user's own
devices. If a HealthKit questionnaire appears, state that health data is used
only to display and broadcast the reading, is not shared with third parties, and
is not used for advertising or tracking.

### 7. Stop here

Do not click "Add for Review" or "Submit". Report:

- the app's Apple ID once created,
- every field you filled and every one you could not,
- anything App Store Connect rejected, quoting its exact wording.

---

## Outstanding before submission

- **iPad screenshots.** Every existing iPad capture predates the iPad fixes and
  shows the source defaulting to Apple Watch. Recapture on the current build,
  drop into `~/Downloads/HRB`, add the filenames to the `IPAD` list in
  `scripts/publish-press-kit.ts`, and republish.
- **The marketing page says there is no App Store build.** The hero note and
  the "Getting it" section both describe sideloading. Both need rewriting once
  a listing exists.
- **Export compliance.** The app uses only the platform's Bluetooth and HTTPS,
  so the standard exemption applies, but the question is asked per build.
