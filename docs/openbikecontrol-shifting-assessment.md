# Virtual shifting in HRB — what it would take

Assessment only. Nothing here is built, and nothing starts until the verification
ride shows the watch, headphones, phone and Health path solid end to end.

Surveyed: `~/Developer/bikecontrol-local`, a Flutter fork of
`OpenBikeControl/bikecontrol`. The whole OpenBikeControl surface there is 1082
lines of Dart across six files — it is a small protocol, not a large one.

## The finding that decides the architecture

`MyWhoosh.connections` lists exactly two transports:

```dart
(AppConnectionMethod.myWhooshLink, ConnectionSupport.supported),
(AppConnectionMethod.obpMdns,      ConnectionSupport.supported),
```

`obpBle` is not among them. **MyWhoosh does not accept an OpenBikeControl
controller over Bluetooth.** It accepts one over the network: a Bonjour service
of type `_openbikecontrol._tcp`, preferred port 36867, carrying button frames on
a TCP socket. The BLE emulator in the fork exists for other games.

This inverts the obvious guess. HRB already owns a BLE peripheral role, so
"advertise a second service" looked like the cheap path — but it would not reach
MyWhoosh. The cheap path is the one HRB has none of today: a listener.

## Shifting is two button identifiers

From `protocol_parser.dart`:

| Byte | Button     |
|------|------------|
| 0x01 | Shift Up   |
| 0x02 | Shift Down |
| 0x03 | Gear Set   |

A press is a list of `(identifier, state)` pairs where state is 1 for down and 0
for up, run through `encodeButtonState` and pushed to the client. A tap is a
down frame followed by an up frame. That is the entire shifting protocol; the
other ~30 identifiers are steering, emotes, menu navigation, and are not needed.

No Zwift Click, no Kickr Clicks, no Wahoo shifter. The controller is emulated
outright, which is exactly what you asked for.

## "Direct to the Kickr" is a different problem, and a weaker one

The Kickr Core has no gears. Shifting it directly means changing its resistance
— FTMS target power stepping or a simulated grade — written to the trainer's
control point. Two things spoil it:

- A trainer takes one control-point owner. During a MyWhoosh ride, MyWhoosh is
  it. HRB would be fighting the game for the connection.
- Even if it won, the game's own gradient simulation would be fighting the
  resistance HRB imposed. This is why BikeControl's virtual shifting defaults to
  `VirtualShiftingMode.targetPower` *and* announces itself to the game as the
  trainer — it interposes rather than competes.

So: the MyWhoosh path is the feature. Direct-to-trainer is a fallback for apps
that have no virtual shifting of their own, and it should stay out of a first
version.

The Kickr UUIDs in the fork's plan (`a026ee0d…` service, `a026e03c…`
characteristic) are for reading the *Kickr Bike's own shifter buttons* — an
input source, not a way to command a Core. They are not useful here.

## What HRB would have to grow

1. **A TCP listener and a Bonjour advertisement.** `NWListener` gives both in
   one object; no third-party mDNS is needed on Apple platforms.
2. **A frame encoder** for button state. Small.
3. **Gear state** — current gear, gear count, ratios. HRB would own the number,
   because HRB is the thing drawing it.
4. **Two buttons on the workout screen**, and gear up/down plus a gear readout on
   the watch. The `WCPayload` bridge already carries session state both ways and
   can carry these.
5. **Info.plist**: `NSLocalNetworkUsageDescription` and `NSBonjourServices`.

## Two things worth deciding before any code

**The privacy claim changes.** The FAQ and the App Store copy currently say the
app makes no network requests at all and works in airplane mode. A local
listener is not a network *request*, and nothing leaves the LAN — but iOS will
show the local-network permission prompt, and the copy as written would no
longer be strictly true. The honest version is a sentence saying the shifter
listens on the local network and nothing else does. This is a positioning
decision, not a technical one.

**The licence forbids reuse of the code.** `bikecontrol-local` is under a
Non-Commercial Software License Agreement v1.0: source-form redistribution only,
no commercial use, no bundling into a monetised product. HRB is a paid app under
MIT. No Dart may be copied and no line-by-line translation of it may ship. What
is safe is the *protocol* — service names, port, button identifiers are
interoperability facts, and OpenBikeControl publishes a spec. The clean route is
to implement from that public spec rather than from the fork, and to say so in
the commit. Worth being deliberate about rather than assuming.

## Open questions I could not answer from the source

- Whether MyWhoosh requires the APPINFO handshake before it will accept button
  frames. The fork carries an `app_info_reassembler.dart`, which suggests the
  game sends chunked app info *to* the controller; inbound, probably ignorable,
  but unconfirmed.
- The exact TCP framing on the mDNS path. `protocol_parser.dart` is shared with
  the BLE path, so the payload is very likely the same `encodeButtonState`
  bytes with a length header — I did not read the framing itself.

Both are answerable in an afternoon with a packet capture against MyWhoosh, and
neither changes the shape above.

## Size

The MyWhoosh-only path is a few hundred lines of Swift plus UI. It is genuinely
small. The two decisions above are the real cost, and the second one is the one
that can bite.

## What ships today: gear 15, broadcast-only

The assessment above describes what a full integration would take. What HRB
actually ships is narrower, deliberately, and the reason is a gap in the
protocol rather than a gap in the app.

**There is no API for reading initial gear.** OpenBikeControl exposes no
setting, characteristic, or handshake that reports the Wahoo KICKR's current
gear at connect time. The gear is a number the *controller* owns; the trainer
neither publishes it nor accepts a query for it. So there is nothing to read,
and no amount of care on our side produces a value we did not choose.

**So HRB starts at gear 15.** That is not a guess at the trainer's state — it
is HRB's own starting gear, chosen and owned by HRB, and it is what the app
does. Every subsequent shift is relative to it, so the sequence is coherent
from the first shift onward whatever the hardware believed beforehand.

**Shifts are published, not acknowledged.** HRB broadcasts the gear change and
the write completes. What does not come back is confirmation that the trainer
applied it — the protocol carries no acknowledgement frame, no gear-state
readback, no error path for a rejected shift. A write that succeeds at the BLE
layer is the entire signal available. Absent an acknowledgement channel, an
unverified shift is not a defect in HRB; it is the protocol's silence, and
there is no version of this app that could report otherwise.

In practice this works for our purposes: the shift lands, the resistance
changes, the rider feels it. The open item is verification, not function.

**What would change this.** Either would be integrated if it materialised:

1. A gear-setting or gear-reading API on OpenBikeControl's side — a
   characteristic that reports current gear, or accepts one and confirms it.
   Then HRB reads the real starting gear instead of asserting 15, and reports
   real failures instead of assuming success.
2. Further reverse engineering of the wire protocol establishing whether an
   acknowledgement or state frame exists and is simply undocumented. The
   packet capture named under *Open questions* would answer this at the same
   time it answers the framing question.

Until one of those lands, broadcast-only at a known starting gear is the
correct design, and the limitation is documented here so it is not rediscovered
as a bug.
