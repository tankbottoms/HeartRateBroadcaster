# Before submitting for review

State as of 4 August 2026. Done items are recorded so a second pass does not
redo them.

## Done

- [x] **Privacy manifests** — `PrivacyInfo.xcprivacy` in the app, the watch app,
      and the widget extension. Every bundle in an archive is scanned
      separately, so one in the app alone would have triggered ITMS-91053.
      The app declares `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1`,
      its only required-reason API.
- [x] **Privacy policy** — <https://heart-rate.atsignhandle.xyz/privacy.html>.
      App Store Connect requires the URL for every app and enforces it for
      HealthKit apps.
- [x] **Export compliance** — `ITSAppUsesNonExemptEncryption` is `false` in the
      Info.plist, so the per-build question is answered automatically.
- [x] **Version 1.0** — `MARKETING_VERSION` matches the listing. Build number
      auto-increments per build.
- [x] **Permission prompt wording** — the HealthKit and Bluetooth dialogs name
      the app correctly.
- [x] **Screenshots** — iPhone 6.9" and Apple Watch, exact sizes, published to
      the press folder with a manifest.

## Blocking

- [ ] **Upload a build.** Nothing has been archived or uploaded. Xcode ›
      Product › Archive › Distribute App › App Store Connect, or `xcodebuild
      -exportArchive` plus Transporter. Until a build finishes processing, the
      version cannot be submitted no matter how complete the metadata is.

- [ ] **App Review notes.** This is the most likely rejection. A reviewer has
      no AirPods Pro 3 and probably no paired Apple Watch, so the app will show
      no heart rate and read as broken. The notes must say, in the App Review
      Information box:

      > This app rebroadcasts heart rate from an Apple Watch or AirPods Pro 3.
      > Neither is required to review it: open Settings inside the app and set
      > Source to "Test Signal", which generates a simulated heart rate. The
      > main screen will then show a live BPM and the Broadcast section will
      > show frames being sent. To see a device subscribe, run any app that
      > pairs a Bluetooth heart rate strap on a second device and pair with the
      > advertised sensor named "HRB".
      >
      > No account or login is required.

- [ ] **iPad screenshots, or drop iPad.** The listing declares iOS including
      iPadOS. Either capture 13" iPad screenshots on the current build — every
      existing capture predates the iPad fixes — or set the app to iPhone-only.
      Note `TARGETED_DEVICE_FAMILY` is `"1,2"`, so the binary claims iPad
      support and reviewers will run it there.

- [ ] **Agreements, Tax, and Banking.** For a free app, the Free Applications
      agreement must be active. For a paid app, add tax forms and banking or the
      app cannot go on sale. Nothing can be made available for sale until this
      is green.

- [ ] **Marketing page contradicts the listing.** The hero note and the
      "Getting it" section still say there is no App Store build and describe
      sideloading. The support URL points at that page.

## Check while filling the form

- **Age rating** — every question "None"/"No", expected result 4+.
- **App privacy** — "No, we do not collect data from this app." Must agree with
  the privacy manifests, which declare no collection and no tracking.
- **Content rights** — does not contain third-party content.
- **Pricing and availability** — this is what "make available for sale" means.
  Set it, but only after a build has been accepted.

## Not required

- **Demo account** — there is no login.
- **Sign in with Apple** — no third-party sign-in, so it does not apply.
- **Attached watch app** — a watchOS app embedded in an iOS app is submitted as
  part of the same record, not separately.
