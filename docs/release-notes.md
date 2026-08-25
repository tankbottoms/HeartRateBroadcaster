First public release. HeartRate Broadcaster turns an iPhone into a standard
Bluetooth LE heart rate sensor: it reads live heart rate from an Apple Watch and,
optionally, AirPods Pro 3, reconciles the two into one value, and re-advertises
it as the Bluetooth Heart Rate Service (`0x180D`). MyWhoosh, Zwift, TrainerRoad,
Wahoo and Bluetooth-capable Garmin Edge units pair with the phone as though it
were a chest strap.

## Three ways to get it

| | Cost | Needs | Lasts |
| --- | --- | --- | --- |
| [TestFlight](https://testflight.apple.com/join/VUJCa5Gw) | Free | Apple's TestFlight app | 90 days per build |
| Sideload the `.ipa` below | Free | A paid Apple Developer account | Your provisioning profile |
| App Store | USD 4.99 once | Nothing | Indefinitely |

The binary is the same in all three. There is no free edition, no in-app
purchase and no subscription — the two free routes cost effort instead of money.

### TestFlight

The beta is public: no invitation, no code, no approval step.

1. Install **TestFlight** from the App Store on the iPhone.
2. Open <https://testflight.apple.com/join/VUJCa5Gw> on that same iPhone, then
   tap Accept and Install.
3. Install the watch app from the Watch app on the iPhone. The watch is the
   sensor, so this step is not optional.

A build works for 90 days from publication; each new build restarts the clock.

### Sideloading `HeartRateBroadcaster.ipa`

The attached `.ipa` is signed for App Store distribution, so it will not install
as shipped — it has to be re-signed with your own identity.

HealthKit and background Bluetooth are unavailable to free provisioning
profiles, so this route needs a **paid Apple Developer account**. A free Apple ID
signs the app and then fails at runtime, which is worse than not installing.

**Xcode** — rename the `.ipa` to `.zip`, unzip, take
`Payload/HeartRateBroadcaster.app`, then open Xcode → Window → Devices and
Simulators and drag the `.app` into *Installed Apps*.

**Sideloadly or AltStore** — open the `.ipa`, sign in with the Apple ID holding
your developer membership, and install to the connected iPhone.

**From source** — clone, `xcodegen generate`, set `DEVELOPMENT_TEAM` in
`signing.xcconfig`, build to the device. No re-signing step at all.

## Requirements

iOS 26 or later, watchOS 11 or later for the watch app. AirPods Pro 3 are
optional; the watch alone is a complete source, and so are the AirPods.

## Notes

Discovery needs the app in the foreground — iOS stops advertising a backgrounded
app's service UUID. Once a head unit has connected, the link survives locking the
phone. ANT+ is not supported and cannot be: an iPhone has no ANT+ radio.

No account, no server, no analytics. Heart rate is read on device and leaves only
over Bluetooth. Source under the MIT licence.
