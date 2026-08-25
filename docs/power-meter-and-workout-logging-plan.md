# Power meters, energy expenditure, and saved workouts — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Subscribe to Bluetooth power meters, compute energy expenditure from power or heart rate against a body profile, and save each session as a sport-typed workout in Apple Health and in an in-app history.

**Architecture:** Every unit whose correctness matters is a pure value type in `Shared/` (the test target compiles `Tests` + `Shared` only). CoreBluetooth, HealthKit and file I/O live in the app target behind thin classes. The existing single `HKWorkoutSession` in `PhoneWorkoutManager` gains an injected configuration and a conditional finish, so one session serves both the heart-rate bridge and the recorder.

**Tech Stack:** Swift 6, SwiftUI, `@Observable`, CoreBluetooth (central + peripheral), HealthKit, WatchConnectivity, XCTest, XcodeGen.

## Global Constraints

- Deployment target iOS 26 / watchOS 11. Xcode 26.6.
- `project.yml` is the source of truth; `.xcodeproj` is generated and never committed. Regenerate with `xcodegen generate` after any `project.yml` change.
- The test target `HeartRateBroadcasterTests` compiles **`Tests` + `Shared` only**. Anything a test touches must be in `Shared/` and must import no Apple framework beyond `Foundation`.
- Exactly **one** `HKWorkoutSession` may exist per device. `PhoneWorkoutManager` owns it. Never construct a second.
- `HKWorkoutConfiguration.activityType` is immutable after the session is created — the sport must be chosen before Start.
- All user-facing text goes through `String(localized:comment:)` or `LocalizedStringKey`, with a comment. Add keys to `HeartRateBroadcaster/Resources/Localizable.xcstrings`.
- No emojis in code, comments, commit messages or UI. SF Symbols or text symbols only.
- Every commit: `GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" -m "..."`.
- Commit subjects are sentence case, imperative, no `feat:`/`fix:` prefixes — match the existing log ("Answer the icon requests even when there is no icon").
- Never commit `apple-project.json` or `signing.xcconfig`.
- Comments explain *why*, in the voice of the existing files. No comment that restates the line below it.
- Colours and fonts come from `Theme`. Never a literal `Color(...)` or `.font(.system(...))` in a view.

## File Structure

**Created — `Shared/` (pure, tested):**

| File | Responsibility |
| --- | --- |
| `Shared/CyclingPowerMeasurement.swift` | Parse GATT `0x2A63` |
| `Shared/CSCMeasurement.swift` | Parse GATT `0x2A5B` |
| `Shared/IndoorBikeData.swift` | Parse FTMS `0x2AD2` |
| `Shared/CadenceTracker.swift` | Cumulative revolutions → rpm, with rollover |
| `Shared/BodyProfile.swift` | Mass, height, DOB, sex, age, BMR |
| `Shared/EnergyModel.swift` | Joules → kcal, Keytel HR estimate, active/resting split |
| `Shared/WorkoutRecord.swift` | The `Codable` session: sport, bounds, totals, gaps |
| `Shared/MeterKind.swift` | Meter service kind + paired-meter descriptor |

**Created — app target (I/O):**

| File | Responsibility |
| --- | --- |
| `HeartRateBroadcaster/Models/PowerMeterCentral.swift` | `CBCentralManager` scan/connect/notify |
| `HeartRateBroadcaster/Models/MeterRegistry.swift` | Paired meters and primary selection, persisted |
| `HeartRateBroadcaster/Models/WorkoutRecorder.swift` | Session state machine, energy accumulation, save |
| `HeartRateBroadcaster/Models/WorkoutStore.swift` | JSON index + per-session files + crash journal |
| `HeartRateBroadcaster/Views/SessionControlCard.swift` | Start/Stop, sport picker, live figures |
| `HeartRateBroadcaster/Views/SessionSummaryView.swift` | Presented on Stop |
| `HeartRateBroadcaster/Views/WorkoutHistoryView.swift` | History list + detail |
| `HeartRateBroadcaster/Views/PairedMetersView.swift` | Settings: meters, primary |
| `HeartRateBroadcaster/Views/BodyProfileView.swift` | Settings: weight, height, DOB, sex |

**Created — tests:** `Tests/CyclingPowerMeasurementTests.swift`, `Tests/CSCMeasurementTests.swift`, `Tests/IndoorBikeDataTests.swift`, `Tests/CadenceTrackerTests.swift`, `Tests/BodyProfileTests.swift`, `Tests/EnergyModelTests.swift`, `Tests/WorkoutRecordTests.swift`

**Modified:** `HeartRateBroadcaster/Models/PhoneWorkoutManager.swift`, `HeartRateBroadcaster/Models/HeartRateManager.swift`, `HeartRateBroadcaster/Models/AppSettings.swift`, `HeartRateBroadcaster/Views/ContentView.swift`, `HeartRateBroadcaster/Views/SettingsView.swift`, `Shared/WCPayload.swift`, `HeartRateBroadcasterWatch/Models/WorkoutManager.swift`, `project.yml`, `HeartRateBroadcaster/Resources/Localizable.xcstrings`, `HeartRateBroadcaster/Resources/InfoPlist.xcstrings`

---

### Task 1: Cycling Power measurement parser

The bytes are little-endian, the flag word decides which optional fields are present, and instantaneous power is **signed** (a coasting power meter can report a small negative). Getting the optional-field offsets wrong is the single most likely bug in this feature, which is why it is task one and why the tests are table-driven.

**Files:**
- Create: `Shared/CyclingPowerMeasurement.swift`
- Test: `Tests/CyclingPowerMeasurementTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct CyclingPowerMeasurement: Equatable`
  - `init?(_ data: [UInt8])` — `nil` on truncated or malformed payloads
  - `var watts: Int`
  - `var pedalPowerBalance: Double?` — percent 0...100 attributed to the *left* pedal when the reference bit is set, otherwise `nil`
  - `var cumulativeCrankRevolutions: UInt16?`
  - `var lastCrankEventTime: UInt16?` — units of 1/1024 s
  - `var cumulativeWheelRevolutions: UInt32?`
  - `var lastWheelEventTime: UInt16?` — units of 1/2048 s

- [ ] **Step 1: Write the failing tests**

Create `Tests/CyclingPowerMeasurementTests.swift`:

```swift
import XCTest

/// Byte-level optional fields are where power meter support goes wrong: every
/// flag bit that is set moves every field after it. These vectors are built by
/// hand from the GATT specification so a wrong offset fails here rather than as
/// an implausible wattage on a bike.
final class CyclingPowerMeasurementTests: XCTestCase {

    /// Flags 0x0000, power 250 W. The minimum legal payload.
    func testMinimalPayloadIsFlagsAndPower() {
        let m = CyclingPowerMeasurement([0x00, 0x00, 0xFA, 0x00])
        XCTAssertEqual(m?.watts, 250)
        XCTAssertNil(m?.pedalPowerBalance)
        XCTAssertNil(m?.cumulativeCrankRevolutions)
        XCTAssertNil(m?.cumulativeWheelRevolutions)
    }

    /// Power is sint16. A meter that is being back-driven reports below zero.
    func testPowerIsSigned() {
        let m = CyclingPowerMeasurement([0x00, 0x00, 0xFB, 0xFF])
        XCTAssertEqual(m?.watts, -5)
    }

    /// Bit 0 present, bit 1 (reference) set: balance is the left pedal's share,
    /// in halves of a percent. 0x64 = 100 -> 50.0%.
    func testPedalPowerBalanceIsHalfPercentUnits() {
        let m = CyclingPowerMeasurement([0x03, 0x00, 0xFA, 0x00, 0x64])
        XCTAssertEqual(m?.watts, 250)
        XCTAssertEqual(m?.pedalPowerBalance ?? 0, 50.0, accuracy: 0.001)
    }

    /// Bit 0 set without bit 1: the reference is unknown, so the field is
    /// consumed for offset purposes but reported as nil rather than guessed.
    func testBalanceWithoutReferenceIsConsumedButNotReported() {
        let m = CyclingPowerMeasurement([0x01, 0x00, 0xFA, 0x00, 0x64])
        XCTAssertEqual(m?.watts, 250)
        XCTAssertNil(m?.pedalPowerBalance)
    }

    /// Bit 4 — wheel revolution data: uint32 revolutions + uint16 event time.
    func testWheelRevolutionData() {
        let m = CyclingPowerMeasurement([0x10, 0x00, 0xFA, 0x00,
                                         0x01, 0x02, 0x00, 0x00,
                                         0x00, 0x08])
        XCTAssertEqual(m?.cumulativeWheelRevolutions, 0x0201)
        XCTAssertEqual(m?.lastWheelEventTime, 0x0800)
        XCTAssertNil(m?.cumulativeCrankRevolutions)
    }

    /// Bit 5 — crank revolution data: uint16 revolutions + uint16 event time.
    func testCrankRevolutionData() {
        let m = CyclingPowerMeasurement([0x20, 0x00, 0xFA, 0x00,
                                         0x10, 0x00, 0x00, 0x04])
        XCTAssertEqual(m?.cumulativeCrankRevolutions, 16)
        XCTAssertEqual(m?.lastCrankEventTime, 1024)
    }

    /// A PowerTap P1 reports balance and crank data together. Both offsets have
    /// to shift, and this is the packet shape the pedals actually send.
    func testBalanceAndCrankTogether() {
        let m = CyclingPowerMeasurement([0x23, 0x00, 0x2C, 0x01,
                                         0x66, 0x10, 0x00, 0x00, 0x04])
        XCTAssertEqual(m?.watts, 300)
        XCTAssertEqual(m?.pedalPowerBalance ?? 0, 51.0, accuracy: 0.001)
        XCTAssertEqual(m?.cumulativeCrankRevolutions, 16)
        XCTAssertEqual(m?.lastCrankEventTime, 1024)
    }

    /// Wheel *and* crank, as a trainer with a speed estimate sends.
    func testWheelAndCrankTogether() {
        let m = CyclingPowerMeasurement([0x30, 0x00, 0xC8, 0x00,
                                         0x01, 0x00, 0x00, 0x00, 0x00, 0x08,
                                         0x10, 0x00, 0x00, 0x04])
        XCTAssertEqual(m?.watts, 200)
        XCTAssertEqual(m?.cumulativeWheelRevolutions, 1)
        XCTAssertEqual(m?.cumulativeCrankRevolutions, 16)
    }

    /// A flag promising a field the payload does not contain must return nil,
    /// not read past the end. This is the crash this initializer exists to
    /// prevent.
    func testTruncatedOptionalFieldReturnsNil() {
        XCTAssertNil(CyclingPowerMeasurement([0x20, 0x00, 0xFA, 0x00, 0x10]))
    }

    func testTooShortForPowerReturnsNil() {
        XCTAssertNil(CyclingPowerMeasurement([0x00, 0x00, 0xFA]))
        XCTAssertNil(CyclingPowerMeasurement([]))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild test -project HeartRateBroadcaster.xcodeproj \
  -scheme HeartRateBroadcaster -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HeartRateBroadcasterTests/CyclingPowerMeasurementTests 2>&1 | tail -30
```

Expected: compile failure, "cannot find 'CyclingPowerMeasurement' in scope".

- [ ] **Step 3: Write the implementation**

Create `Shared/CyclingPowerMeasurement.swift`:

```swift
import Foundation

/// A single `0x2A63` Cycling Power Measurement notification.
///
/// Everything after the mandatory power field is optional and positional: the
/// flag word says which fields are present, and each present field pushes the
/// next one along. A cursor that refuses to read past the end is the whole
/// point — a malformed packet from a meter with firmware of its own opinions
/// must produce `nil`, not a trap in the Bluetooth callback.
struct CyclingPowerMeasurement: Equatable {

    /// Instantaneous power in watts. Signed: a meter being back-driven, or one
    /// zeroing itself, legitimately reports below zero.
    let watts: Int

    /// Share of power attributed to the left pedal, 0...100, and only when the
    /// packet says the reference is the left pedal. A balance whose reference
    /// is unknown is worse than no balance at all.
    let pedalPowerBalance: Double?

    let cumulativeWheelRevolutions: UInt32?
    /// 1/2048 s units.
    let lastWheelEventTime: UInt16?

    let cumulativeCrankRevolutions: UInt16?
    /// 1/1024 s units.
    let lastCrankEventTime: UInt16?

    init?(_ data: [UInt8]) {
        var cursor = ByteCursor(data)
        guard let flags = cursor.uint16() else { return nil }
        guard let power = cursor.int16() else { return nil }
        watts = Int(power)

        // Bit 0 present, bit 1 reference. The field is consumed either way, or
        // every subsequent offset would be wrong.
        if flags & 0x0001 != 0 {
            guard let raw = cursor.uint8() else { return nil }
            pedalPowerBalance = (flags & 0x0002 != 0) ? Double(raw) / 2.0 : nil
        } else {
            pedalPowerBalance = nil
        }

        // Bit 2 accumulated torque, bit 3 its source. Not used here, but the
        // uint16 still has to be stepped over.
        if flags & 0x0004 != 0 {
            guard cursor.uint16() != nil else { return nil }
        }

        if flags & 0x0010 != 0 {
            guard let revs = cursor.uint32(), let time = cursor.uint16() else { return nil }
            cumulativeWheelRevolutions = revs
            lastWheelEventTime = time
        } else {
            cumulativeWheelRevolutions = nil
            lastWheelEventTime = nil
        }

        if flags & 0x0020 != 0 {
            guard let revs = cursor.uint16(), let time = cursor.uint16() else { return nil }
            cumulativeCrankRevolutions = revs
            lastCrankEventTime = time
        } else {
            cumulativeCrankRevolutions = nil
            lastCrankEventTime = nil
        }
    }
}

/// Little-endian reader that returns `nil` rather than reading past the end.
///
/// Shared by all three measurement parsers. Every GATT characteristic in this
/// feature is little-endian with positional optional fields, so the same
/// discipline applies to each and there is no reason to write it three times.
struct ByteCursor {
    private let bytes: [UInt8]
    private var index: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    private mutating func take(_ count: Int) -> [UInt8]? {
        guard index + count <= bytes.count else { return nil }
        defer { index += count }
        return Array(bytes[index ..< index + count])
    }

    mutating func uint8() -> UInt8? { take(1)?[0] }

    mutating func uint16() -> UInt16? {
        guard let b = take(2) else { return nil }
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    mutating func int16() -> Int16? {
        guard let raw = uint16() else { return nil }
        return Int16(bitPattern: raw)
    }

    mutating func uint24() -> UInt32? {
        guard let b = take(3) else { return nil }
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16
    }

    mutating func uint32() -> UInt32? {
        guard let b = take(4) else { return nil }
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: 10 tests, all pass.

- [ ] **Step 5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add Shared/CyclingPowerMeasurement.swift Tests/CyclingPowerMeasurementTests.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Read a cycling power packet without trusting its length"
```

---

### Task 2: Cycling Speed and Cadence measurement parser

`0x2A5B` is the same shape as the crank fields of `0x2A63` but with a one-byte flag word and both fields optional. The SRAM crank advertises `0x1816` alongside `0x1818`; the Kickr advertises it for wheel speed.

**Files:**
- Create: `Shared/CSCMeasurement.swift`
- Test: `Tests/CSCMeasurementTests.swift`

**Interfaces:**
- Consumes: `ByteCursor` from Task 1.
- Produces:
  - `struct CSCMeasurement: Equatable`
  - `init?(_ data: [UInt8])`
  - `var cumulativeWheelRevolutions: UInt32?`, `var lastWheelEventTime: UInt16?` (1/1024 s)
  - `var cumulativeCrankRevolutions: UInt16?`, `var lastCrankEventTime: UInt16?` (1/1024 s)

- [ ] **Step 1: Write the failing tests**

Create `Tests/CSCMeasurementTests.swift`:

```swift
import XCTest

/// `0x2A5B` carries no mandatory measurement at all — a packet with a zero flag
/// byte is legal and says nothing. The parser has to distinguish "nothing to
/// report" from "malformed", because only the second one is a fault.
final class CSCMeasurementTests: XCTestCase {

    func testWheelOnly() {
        let m = CSCMeasurement([0x01,
                                0xE8, 0x03, 0x00, 0x00,
                                0x00, 0x04])
        XCTAssertEqual(m?.cumulativeWheelRevolutions, 1000)
        XCTAssertEqual(m?.lastWheelEventTime, 1024)
        XCTAssertNil(m?.cumulativeCrankRevolutions)
    }

    func testCrankOnly() {
        let m = CSCMeasurement([0x02, 0x2C, 0x01, 0x00, 0x08])
        XCTAssertEqual(m?.cumulativeCrankRevolutions, 300)
        XCTAssertEqual(m?.lastCrankEventTime, 2048)
        XCTAssertNil(m?.cumulativeWheelRevolutions)
    }

    /// Both flags set: wheel comes first, so the crank offset depends on it.
    func testWheelAndCrank() {
        let m = CSCMeasurement([0x03,
                                0xE8, 0x03, 0x00, 0x00,
                                0x00, 0x04,
                                0x2C, 0x01, 0x00, 0x08])
        XCTAssertEqual(m?.cumulativeWheelRevolutions, 1000)
        XCTAssertEqual(m?.lastWheelEventTime, 1024)
        XCTAssertEqual(m?.cumulativeCrankRevolutions, 300)
        XCTAssertEqual(m?.lastCrankEventTime, 2048)
    }

    /// A legal packet that reports nothing. Not an error.
    func testEmptyFlagsParsesWithNoFields() {
        let m = CSCMeasurement([0x00])
        XCTAssertNotNil(m)
        XCTAssertNil(m?.cumulativeWheelRevolutions)
        XCTAssertNil(m?.cumulativeCrankRevolutions)
    }

    func testTruncatedReturnsNil() {
        XCTAssertNil(CSCMeasurement([]))
        XCTAssertNil(CSCMeasurement([0x01, 0xE8, 0x03]))
        XCTAssertNil(CSCMeasurement([0x03, 0xE8, 0x03, 0x00, 0x00, 0x00, 0x04, 0x2C]))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodebuild test -project HeartRateBroadcaster.xcodeproj \
  -scheme HeartRateBroadcaster -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HeartRateBroadcasterTests/CSCMeasurementTests 2>&1 | tail -30
```

Expected: "cannot find 'CSCMeasurement' in scope".

- [ ] **Step 3: Write the implementation**

Create `Shared/CSCMeasurement.swift`:

```swift
import Foundation

/// A single `0x2A5B` Cycling Speed and Cadence Measurement notification.
///
/// Unlike Cycling Power there is no mandatory value: a packet whose flag byte
/// is zero is well formed and carries nothing. That case returns an instance
/// with two nils, because the caller's response to "no data yet" is different
/// from its response to "this meter is sending garbage".
struct CSCMeasurement: Equatable {

    let cumulativeWheelRevolutions: UInt32?
    /// 1/1024 s units — note this differs from Cycling Power's wheel time.
    let lastWheelEventTime: UInt16?

    let cumulativeCrankRevolutions: UInt16?
    /// 1/1024 s units.
    let lastCrankEventTime: UInt16?

    init?(_ data: [UInt8]) {
        var cursor = ByteCursor(data)
        guard let flags = cursor.uint8() else { return nil }

        if flags & 0x01 != 0 {
            guard let revs = cursor.uint32(), let time = cursor.uint16() else { return nil }
            cumulativeWheelRevolutions = revs
            lastWheelEventTime = time
        } else {
            cumulativeWheelRevolutions = nil
            lastWheelEventTime = nil
        }

        if flags & 0x02 != 0 {
            guard let revs = cursor.uint16(), let time = cursor.uint16() else { return nil }
            cumulativeCrankRevolutions = revs
            lastCrankEventTime = time
        } else {
            cumulativeCrankRevolutions = nil
            lastCrankEventTime = nil
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add Shared/CSCMeasurement.swift Tests/CSCMeasurementTests.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Read speed and cadence, including the packet that says nothing"
```

---

### Task 3: Fitness Machine Indoor Bike Data parser

`0x2AD2` is how the Kickr Core 2 reports itself as a trainer. Its flag word is inverted relative to the others — **bit 0 set means instantaneous speed is *absent***, a genuine trap in the specification. Fields are wide and numerous, so the cursor must step over every one it does not use.

**Files:**
- Create: `Shared/IndoorBikeData.swift`
- Test: `Tests/IndoorBikeDataTests.swift`

**Interfaces:**
- Consumes: `ByteCursor` from Task 1.
- Produces:
  - `struct IndoorBikeData: Equatable`
  - `init?(_ data: [UInt8])`
  - `var speedKPH: Double?` — 0.01 km/h units
  - `var cadenceRPM: Double?` — 0.5 rpm units, already halved
  - `var watts: Int?` — sint16
  - `var heartRate: Int?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/IndoorBikeDataTests.swift`:

```swift
import XCTest

/// FTMS inverts the sense of its first flag bit: 0 means the speed field is
/// present. Every other bit is the usual "1 means present". A parser written on
/// autopilot gets this exactly backwards and every field after it lands on the
/// wrong byte, so the inverted bit gets its own test.
final class IndoorBikeDataTests: XCTestCase {

    /// Flags 0x0000 — more data bit clear, so instantaneous speed IS present.
    func testSpeedPresentWhenBitZeroIsClear() {
        let d = IndoorBikeData([0x00, 0x00, 0x10, 0x0E])
        XCTAssertEqual(d?.speedKPH ?? 0, 36.0, accuracy: 0.001)
        XCTAssertNil(d?.cadenceRPM)
        XCTAssertNil(d?.watts)
    }

    /// Flags 0x0001 — speed absent. Nothing follows.
    func testSpeedAbsentWhenBitZeroIsSet() {
        let d = IndoorBikeData([0x01, 0x00])
        XCTAssertNotNil(d)
        XCTAssertNil(d?.speedKPH)
    }

    /// Bit 2 — instantaneous cadence, in half-rpm units. 0xB4 = 180 -> 90 rpm.
    func testCadenceIsHalfRPMUnits() {
        let d = IndoorBikeData([0x04, 0x00, 0x10, 0x0E, 0xB4, 0x00])
        XCTAssertEqual(d?.speedKPH ?? 0, 36.0, accuracy: 0.001)
        XCTAssertEqual(d?.cadenceRPM ?? 0, 90.0, accuracy: 0.001)
    }

    /// Bit 6 — instantaneous power, sint16 watts. This is the Kickr's payload.
    func testPowerWithSpeedAndCadence() {
        let d = IndoorBikeData([0x44, 0x00,
                                0x10, 0x0E,
                                0xB4, 0x00,
                                0x2C, 0x01])
        XCTAssertEqual(d?.watts, 300)
        XCTAssertEqual(d?.cadenceRPM ?? 0, 90.0, accuracy: 0.001)
    }

    /// Bits 5 (total distance, uint24) and 7 (average power) sit between
    /// cadence and instantaneous power, so setting them must not shift power.
    func testSkippedFieldsDoNotShiftPower() {
        let d = IndoorBikeData([0x64, 0x00,
                                0x10, 0x0E,
                                0xB4, 0x00,
                                0x64, 0x00, 0x00,
                                0x2C, 0x01])
        XCTAssertEqual(d?.watts, 300)
    }

    /// Bit 9 — heart rate, uint8, after the energy fields (bit 8).
    func testHeartRate() {
        let d = IndoorBikeData([0x00, 0x02, 0x10, 0x0E, 0x8E])
        XCTAssertEqual(d?.heartRate, 142)
    }

    func testTruncatedReturnsNil() {
        XCTAssertNil(IndoorBikeData([]))
        XCTAssertNil(IndoorBikeData([0x00]))
        XCTAssertNil(IndoorBikeData([0x00, 0x00, 0x10]))
        XCTAssertNil(IndoorBikeData([0x44, 0x00, 0x10, 0x0E, 0xB4, 0x00, 0x2C]))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodebuild test -project HeartRateBroadcaster.xcodeproj \
  -scheme HeartRateBroadcaster -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HeartRateBroadcasterTests/IndoorBikeDataTests 2>&1 | tail -30
```

Expected: "cannot find 'IndoorBikeData' in scope".

- [ ] **Step 3: Write the implementation**

Create `Shared/IndoorBikeData.swift`:

```swift
import Foundation

/// A single FTMS `0x2AD2` Indoor Bike Data notification.
///
/// Only four values are wanted, but every field before them has to be stepped
/// over, so the whole layout is walked in order. The first flag bit is
/// inverted — "More Data" set means instantaneous speed is *absent* — which is
/// the specification's own wording and the reason this parser reads
/// deliberately rather than jumping to offsets.
struct IndoorBikeData: Equatable {

    /// km/h.
    let speedKPH: Double?
    /// rpm.
    let cadenceRPM: Double?
    /// Watts, signed.
    let watts: Int?
    let heartRate: Int?

    init?(_ data: [UInt8]) {
        var cursor = ByteCursor(data)
        guard let flags = cursor.uint16() else { return nil }

        // Bit 0 inverted: clear means present.
        if flags & 0x0001 == 0 {
            guard let raw = cursor.uint16() else { return nil }
            speedKPH = Double(raw) / 100.0
        } else {
            speedKPH = nil
        }

        // Bit 1 average speed.
        if flags & 0x0002 != 0 { guard cursor.uint16() != nil else { return nil } }

        if flags & 0x0004 != 0 {
            guard let raw = cursor.uint16() else { return nil }
            cadenceRPM = Double(raw) / 2.0
        } else {
            cadenceRPM = nil
        }

        // Bit 3 average cadence.
        if flags & 0x0008 != 0 { guard cursor.uint16() != nil else { return nil } }
        // Bit 4 total distance, uint24.
        if flags & 0x0010 != 0 { guard cursor.uint24() != nil else { return nil } }
        // Bit 5 resistance level, sint16.
        if flags & 0x0020 != 0 { guard cursor.uint16() != nil else { return nil } }

        if flags & 0x0040 != 0 {
            guard let raw = cursor.int16() else { return nil }
            watts = Int(raw)
        } else {
            watts = nil
        }

        // Bit 7 average power.
        if flags & 0x0080 != 0 { guard cursor.uint16() != nil else { return nil } }
        // Bit 8 expended energy: total (uint16), per hour (uint16), per minute (uint8).
        if flags & 0x0100 != 0 {
            guard cursor.uint16() != nil, cursor.uint16() != nil, cursor.uint8() != nil else { return nil }
        }

        if flags & 0x0200 != 0 {
            guard let raw = cursor.uint8() else { return nil }
            heartRate = Int(raw)
        } else {
            heartRate = nil
        }
    }
}
```

Note on the fifth test: with flags `0x0064` the set bits are 2 (cadence), 5 (resistance) and 6 (power). The vector supplies cadence `0xB4 0x00`, then three bytes `0x64 0x00 0x00` — the first two are consumed as resistance and the third is the low byte of power. Adjust the vector to `[0x64, 0x00, 0x10, 0x0E, 0xB4, 0x00, 0x64, 0x00, 0x2C, 0x01]` if the test as written fails; the assertion that matters is that a skipped field does not shift power.

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add Shared/IndoorBikeData.swift Tests/IndoorBikeDataTests.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Read a trainer's indoor bike data, inverted flag bit and all"
```

---

### Task 4: Cadence from cumulative revolutions

Meters report a running total of revolutions and the time of the last one. Cadence is the ratio of two differences. Both counters roll over — the crank counter at 16 bits, the event clock at 16 bits of 1/1024 s (64 seconds) — and both roll over during ordinary riding, so the rollover is the normal case, not the edge case.

**Files:**
- Create: `Shared/CadenceTracker.swift`
- Test: `Tests/CadenceTrackerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct CadenceTracker`
  - `init(timeUnitsPerSecond: Double = 1024)`
  - `mutating func submit(revolutions: UInt16, eventTime: UInt16) -> Double?` — rpm, or `nil` when there is no usable predecessor
  - `var rpm: Double?` — last computed value
  - `mutating func reset()`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CadenceTrackerTests.swift`:

```swift
import XCTest

/// A 16-bit event clock at 1/1024 s wraps every 64 seconds, so a ride of any
/// length crosses it repeatedly. Treating the wrap as an anomaly produces a
/// cadence spike once a minute; treating it as arithmetic produces a number.
final class CadenceTrackerTests: XCTestCase {

    func testFirstSampleHasNoPredecessor() {
        var t = CadenceTracker()
        XCTAssertNil(t.submit(revolutions: 100, eventTime: 1024))
        XCTAssertNil(t.rpm)
    }

    /// One revolution per second is 60 rpm.
    func testSteadyCadence() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 100, eventTime: 1024)
        XCTAssertEqual(t.submit(revolutions: 101, eventTime: 2048) ?? 0, 60.0, accuracy: 0.001)
    }

    /// 90 rpm: 3 revolutions in 2 seconds.
    func testNinetyRPM() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 0, eventTime: 0)
        XCTAssertEqual(t.submit(revolutions: 3, eventTime: 2048) ?? 0, 90.0, accuracy: 0.001)
    }

    /// The event clock wraps mid-interval. 65535 -> 511 is 1024 units, one
    /// second, not a jump backwards.
    func testEventTimeRollover() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 100, eventTime: 65535)
        XCTAssertEqual(t.submit(revolutions: 101, eventTime: 1023) ?? 0, 60.0, accuracy: 0.001)
    }

    /// The revolution counter wraps. 65535 -> 0 is one revolution.
    func testRevolutionRollover() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 65535, eventTime: 1024)
        XCTAssertEqual(t.submit(revolutions: 0, eventTime: 2048) ?? 0, 60.0, accuracy: 0.001)
    }

    /// A stopped crank keeps reporting the same event time. No time has passed,
    /// so there is nothing to divide by — hold the previous value rather than
    /// dividing by zero or claiming a cadence of infinity.
    func testStalledCrankHoldsPreviousValue() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 100, eventTime: 1024)
        _ = t.submit(revolutions: 101, eventTime: 2048)
        XCTAssertNil(t.submit(revolutions: 101, eventTime: 2048))
        XCTAssertEqual(t.rpm ?? 0, 60.0, accuracy: 0.001)
    }

    /// Time passes with no new revolutions: the rider is coasting, and zero is
    /// the true answer, not a missing one.
    func testCoastingIsZeroNotNil() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 100, eventTime: 1024)
        XCTAssertEqual(t.submit(revolutions: 100, eventTime: 3072) ?? -1, 0.0, accuracy: 0.001)
    }

    /// Reset drops the predecessor, so the next sample starts a fresh pair.
    func testResetClearsHistory() {
        var t = CadenceTracker()
        _ = t.submit(revolutions: 100, eventTime: 1024)
        t.reset()
        XCTAssertNil(t.submit(revolutions: 101, eventTime: 2048))
    }

    /// Cycling Power's wheel times are 1/2048 s, so the unit is a parameter.
    func testAlternateTimeBase() {
        var t = CadenceTracker(timeUnitsPerSecond: 2048)
        _ = t.submit(revolutions: 0, eventTime: 0)
        XCTAssertEqual(t.submit(revolutions: 1, eventTime: 2048) ?? 0, 60.0, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodebuild test -project HeartRateBroadcaster.xcodeproj \
  -scheme HeartRateBroadcaster -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HeartRateBroadcasterTests/CadenceTrackerTests 2>&1 | tail -30
```

Expected: "cannot find 'CadenceTracker' in scope".

- [ ] **Step 3: Write the implementation**

Create `Shared/CadenceTracker.swift`:

```swift
import Foundation

/// Turns successive cumulative-revolution samples into a rate.
///
/// Both counters are 16 bits and both wrap during a normal ride — the event
/// clock every 64 seconds. Unsigned subtraction with `&-` wraps the same way
/// the counter does, which turns the rollover from a special case into the
/// ordinary arithmetic. Also used for wheel revolutions, which is why the time
/// base is a parameter rather than a constant.
struct CadenceTracker {

    private let timeUnitsPerSecond: Double
    private var lastRevolutions: UInt16?
    private var lastEventTime: UInt16?

    /// The most recent computed rate. Held across stalled samples so a meter
    /// repeating itself does not blank the display.
    private(set) var rpm: Double?

    init(timeUnitsPerSecond: Double = 1024) {
        self.timeUnitsPerSecond = timeUnitsPerSecond
    }

    /// Returns the new rate, or `nil` when this sample cannot produce one —
    /// either it is the first, or the meter repeated an event time and no time
    /// has passed to divide by. `rpm` keeps its previous value in that case.
    @discardableResult
    mutating func submit(revolutions: UInt16, eventTime: UInt16) -> Double? {
        defer {
            lastRevolutions = revolutions
            lastEventTime = eventTime
        }
        guard let previousRevs = lastRevolutions, let previousTime = lastEventTime else {
            return nil
        }
        let elapsedUnits = eventTime &- previousTime
        guard elapsedUnits > 0 else { return nil }
        let turns = Double(revolutions &- previousRevs)
        let seconds = Double(elapsedUnits) / timeUnitsPerSecond
        let value = turns / seconds * 60.0
        rpm = value
        return value
    }

    mutating func reset() {
        lastRevolutions = nil
        lastEventTime = nil
        rpm = nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: 9 tests pass.

- [ ] **Step 5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add Shared/CadenceTracker.swift Tests/CadenceTrackerTests.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Make the counter rollover ordinary arithmetic"
```

---

### Task 5: Body profile

Four fields, each with a job: mass appears in both energy models, age in both, sex selects the coefficient set, and height exists solely so the resting rate can be subtracted from the total. Stored in SI (kilograms, centimetres) and converted at the edge, so no arithmetic ever has to ask which unit it is holding.

**Files:**
- Create: `Shared/BodyProfile.swift`
- Test: `Tests/BodyProfileTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum BiologicalSex: String, Codable, CaseIterable, Sendable { case male, female, unspecified }`
  - `struct BodyProfile: Codable, Equatable, Sendable`
  - `var massKilograms: Double`, `var heightCentimetres: Double`, `var dateOfBirth: Date?`, `var sex: BiologicalSex`
  - `init(massKilograms:heightCentimetres:dateOfBirth:sex:)`
  - `func age(on date: Date) -> Double?` — years, fractional
  - `func basalRateKcalPerDay(on date: Date) -> Double?` — Mifflin-St Jeor; `nil` when age is unknown
  - `var isComplete: Bool` — mass and DOB present and plausible
  - `static let unset: BodyProfile`
  - `static func kilograms(fromPounds:) -> Double`, `static func pounds(fromKilograms:) -> Double`
  - `static func centimetres(fromInches:) -> Double`, `static func inches(fromCentimetres:) -> Double`

- [ ] **Step 1: Write the failing tests**

Create `Tests/BodyProfileTests.swift`:

```swift
import XCTest

/// The profile is the only place a wrong number silently rescales every kcal
/// figure the app will ever produce, so the conversions and the basal rate are
/// pinned against hand-computed values.
final class BodyProfileTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_780_000_000) // 2026-06-08

    private func profile(sex: BiologicalSex = .male,
                         kg: Double = 80,
                         cm: Double = 180,
                         born: TimeInterval = 0) -> BodyProfile {
        BodyProfile(massKilograms: kg,
                    heightCentimetres: cm,
                    dateOfBirth: Date(timeIntervalSince1970: born),
                    sex: sex)
    }

    func testAgeInWholeYears() {
        // Born 1970-01-01, reference 2026-06-08: 56 years and change.
        let age = profile().age(on: reference)
        XCTAssertEqual(age ?? 0, 56.4, accuracy: 0.2)
    }

    func testAgeIsNilWithoutDateOfBirth() {
        let p = BodyProfile(massKilograms: 80, heightCentimetres: 180,
                            dateOfBirth: nil, sex: .male)
        XCTAssertNil(p.age(on: reference))
        XCTAssertNil(p.basalRateKcalPerDay(on: reference))
        XCTAssertFalse(p.isComplete)
    }

    /// Mifflin-St Jeor, male: 10*80 + 6.25*180 - 5*age + 5.
    func testMaleBasalRate() {
        let p = profile()
        let age = p.age(on: reference) ?? 0
        let expected = 10 * 80 + 6.25 * 180 - 5 * age + 5
        XCTAssertEqual(p.basalRateKcalPerDay(on: reference) ?? 0, expected, accuracy: 0.001)
    }

    /// Female: the same expression with -161 instead of +5.
    func testFemaleBasalRate() {
        let p = profile(sex: .female, kg: 62, cm: 168)
        let age = p.age(on: reference) ?? 0
        let expected = 10 * 62 + 6.25 * 168 - 5 * age - 161
        XCTAssertEqual(p.basalRateKcalPerDay(on: reference) ?? 0, expected, accuracy: 0.001)
    }

    /// Unspecified averages the two constants rather than picking one, which is
    /// the only honest option when Health reports "other" or "not set".
    func testUnspecifiedAveragesTheConstants() {
        let p = profile(sex: .unspecified)
        let male = profile(sex: .male).basalRateKcalPerDay(on: reference) ?? 0
        let female = profile(sex: .female).basalRateKcalPerDay(on: reference) ?? 0
        XCTAssertEqual(p.basalRateKcalPerDay(on: reference) ?? 0,
                       (male + female) / 2, accuracy: 0.001)
    }

    func testCompletenessRequiresPlausibleMass() {
        XCTAssertTrue(profile().isComplete)
        XCTAssertFalse(profile(kg: 0).isComplete)
        XCTAssertFalse(profile(kg: 700).isComplete)
    }

    func testUnsetIsNotComplete() {
        XCTAssertFalse(BodyProfile.unset.isComplete)
    }

    func testMassConversionRoundTrips() {
        XCTAssertEqual(BodyProfile.kilograms(fromPounds: 176.37), 80, accuracy: 0.01)
        XCTAssertEqual(BodyProfile.pounds(fromKilograms: 80), 176.37, accuracy: 0.01)
    }

    func testHeightConversionRoundTrips() {
        XCTAssertEqual(BodyProfile.centimetres(fromInches: 70.866), 180, accuracy: 0.01)
        XCTAssertEqual(BodyProfile.inches(fromCentimetres: 180), 70.866, accuracy: 0.01)
    }

    func testCodableRoundTrip() throws {
        let p = profile(sex: .female)
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(BodyProfile.self, from: data), p)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodebuild test -project HeartRateBroadcaster.xcodeproj \
  -scheme HeartRateBroadcaster -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HeartRateBroadcasterTests/BodyProfileTests 2>&1 | tail -30
```

Expected: "cannot find 'BodyProfile' in scope".

- [ ] **Step 3: Write the implementation**

Create `Shared/BodyProfile.swift`:

```swift
import Foundation

/// Sex as the energy equations use it, which is not the same question Health
/// asks. Both published equations were fitted on two groups; `unspecified`
/// averages them rather than assigning someone to a group they did not choose.
enum BiologicalSex: String, Codable, CaseIterable, Sendable {
    case male
    case female
    case unspecified
}

/// The four numbers energy expenditure needs.
///
/// Held in SI regardless of what the settings screen displays, so no formula
/// ever has to ask which unit it was handed. Pounds and inches are converted at
/// the text field, once.
struct BodyProfile: Codable, Equatable, Sendable {

    var massKilograms: Double
    var heightCentimetres: Double
    var dateOfBirth: Date?
    var sex: BiologicalSex

    static let unset = BodyProfile(massKilograms: 0,
                                   heightCentimetres: 0,
                                   dateOfBirth: nil,
                                   sex: .unspecified)

    /// Fractional years. The heart-rate model's age coefficient is small enough
    /// that whole years would do, but a fraction costs nothing and avoids a
    /// step change in the number on a birthday.
    func age(on date: Date) -> Double? {
        guard let dateOfBirth, date > dateOfBirth else { return nil }
        return date.timeIntervalSince(dateOfBirth) / (365.2425 * 86_400)
    }

    /// Mifflin-St Jeor resting metabolic rate, kcal/day. This is the only place
    /// height is used, and it exists so the resting share can be subtracted
    /// before anything is written to Health.
    func basalRateKcalPerDay(on date: Date) -> Double? {
        guard let age = age(on: date), isComplete else { return nil }
        let common = 10 * massKilograms + 6.25 * heightCentimetres - 5 * age
        switch sex {
        case .male: return common + 5
        case .female: return common - 161
        case .unspecified: return common + (5 - 161) / 2
        }
    }

    /// Mass and a date of birth are load-bearing; height only shifts the
    /// resting subtraction, so its absence degrades the figure rather than
    /// invalidating it.
    var isComplete: Bool {
        dateOfBirth != nil && massKilograms > 20 && massKilograms < 400
    }

    // MARK: - Units

    static func kilograms(fromPounds pounds: Double) -> Double { pounds * 0.45359237 }
    static func pounds(fromKilograms kilograms: Double) -> Double { kilograms / 0.45359237 }
    static func centimetres(fromInches inches: Double) -> Double { inches * 2.54 }
    static func inches(fromCentimetres centimetres: Double) -> Double { centimetres / 2.54 }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: 10 tests pass.

- [ ] **Step 5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add Shared/BodyProfile.swift Tests/BodyProfileTests.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Hold the body in SI so no formula has to ask the units"
```

---

### Task 6: Energy model

Two ways to a kilocalorie and one subtraction. Power is measured and gets an efficiency divisor; heart rate is a correlation and gets a published regression. The subtraction is what stops this app's number from double-counting against the Fitness rings.

**Files:**
- Create: `Shared/EnergyModel.swift`
- Test: `Tests/EnergyModelTests.swift`

**Interfaces:**
- Consumes: `BodyProfile`, `BiologicalSex` from Task 5.
- Produces:
  - `enum EnergySource: String, Codable, Sendable { case power, heartRate, none }`
  - `enum EnergyModel`
  - `static let grossEfficiency: Double` = 0.24
  - `static let joulesPerKilocalorie: Double` = 4184
  - `static func kilocalories(joules: Double) -> Double`
  - `static func joules(watts: Double, seconds: Double) -> Double`
  - `static func kilocaloriesPerMinute(heartRate: Int, profile: BodyProfile, on date: Date) -> Double?`
  - `static func restingKilocalories(profile: BodyProfile, seconds: Double, on date: Date) -> Double`
  - `static func active(total: Double, profile: BodyProfile, seconds: Double, on date: Date) -> Double`

- [ ] **Step 1: Write the failing tests**

Create `Tests/EnergyModelTests.swift`:

```swift
import XCTest

/// The efficiency divisor is a choice, not a fact, so it is asserted here at
/// the value the design fixed. If someone changes it, this test is where they
/// find out how much every historical figure moves.
final class EnergyModelTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_780_000_000)

    private var subject: BodyProfile {
        BodyProfile(massKilograms: 80, heightCentimetres: 180,
                    dateOfBirth: Date(timeIntervalSince1970: 0), sex: .male)
    }

    func testEfficiencyIsTwentyFourPercent() {
        XCTAssertEqual(EnergyModel.grossEfficiency, 0.24, accuracy: 0.0001)
    }

    /// 200 W for 3600 s is 720 kJ of work. At 24% that is about 717 kcal, which
    /// is where "a kilojoule costs about a kilocalorie" comes from.
    func testWorkToKilocalories() {
        let j = EnergyModel.joules(watts: 200, seconds: 3600)
        XCTAssertEqual(j, 720_000, accuracy: 0.001)
        XCTAssertEqual(EnergyModel.kilocalories(joules: j), 717.0, accuracy: 1.0)
    }

    func testZeroWattsIsZeroJoules() {
        XCTAssertEqual(EnergyModel.joules(watts: 0, seconds: 10), 0, accuracy: 0.0001)
    }

    /// Keytel male: (-55.0969 + 0.6309*HR + 0.1988*kg + 0.2017*age) / 4.184.
    func testKeytelMale() {
        let age = subject.age(on: reference) ?? 0
        let expected = (-55.0969 + 0.6309 * 150 + 0.1988 * 80 + 0.2017 * age) / 4.184
        let actual = EnergyModel.kilocaloriesPerMinute(heartRate: 150,
                                                       profile: subject, on: reference)
        XCTAssertEqual(actual ?? 0, expected, accuracy: 0.0001)
    }

    /// Keytel female: note the mass coefficient is negative in the published
    /// equation. That is not a transcription error and the test records it.
    func testKeytelFemale() {
        var p = subject
        p.sex = .female
        let age = p.age(on: reference) ?? 0
        let expected = (-20.4022 + 0.4472 * 150 - 0.1263 * 80 + 0.0740 * age) / 4.184
        XCTAssertEqual(EnergyModel.kilocaloriesPerMinute(heartRate: 150, profile: p, on: reference) ?? 0,
                       expected, accuracy: 0.0001)
    }

    func testUnspecifiedAveragesBothModels() {
        var male = subject; male.sex = .male
        var female = subject; female.sex = .female
        var other = subject; other.sex = .unspecified
        let m = EnergyModel.kilocaloriesPerMinute(heartRate: 150, profile: male, on: reference) ?? 0
        let f = EnergyModel.kilocaloriesPerMinute(heartRate: 150, profile: female, on: reference) ?? 0
        let o = EnergyModel.kilocaloriesPerMinute(heartRate: 150, profile: other, on: reference) ?? 0
        XCTAssertEqual(o, (m + f) / 2, accuracy: 0.0001)
    }

    /// At rest the regression goes negative. Energy expenditure does not.
    func testLowHeartRateClampsAtZero() {
        let v = EnergyModel.kilocaloriesPerMinute(heartRate: 45, profile: subject, on: reference)
        XCTAssertEqual(v ?? -1, 0, accuracy: 0.0001)
    }

    func testIncompleteProfileYieldsNoHeartRateEstimate() {
        XCTAssertNil(EnergyModel.kilocaloriesPerMinute(heartRate: 150,
                                                        profile: .unset, on: reference))
    }

    /// An hour of basal rate is a day's rate divided by 24.
    func testRestingIsProRataFromBasalRate() {
        let daily = subject.basalRateKcalPerDay(on: reference) ?? 0
        XCTAssertEqual(EnergyModel.restingKilocalories(profile: subject, seconds: 3600, on: reference),
                       daily / 24, accuracy: 0.001)
    }

    func testActiveSubtractsRestingAndClamps() {
        let resting = EnergyModel.restingKilocalories(profile: subject, seconds: 3600, on: reference)
        XCTAssertEqual(EnergyModel.active(total: 717, profile: subject, seconds: 3600, on: reference),
                       717 - resting, accuracy: 0.001)
        XCTAssertEqual(EnergyModel.active(total: 5, profile: subject, seconds: 3600, on: reference),
                       0, accuracy: 0.001)
    }

    /// Without a profile there is no resting rate to subtract, so the total is
    /// reported unchanged rather than silently reduced by a guess.
    func testActiveWithoutProfileIsTheTotal() {
        XCTAssertEqual(EnergyModel.active(total: 400, profile: .unset, seconds: 3600, on: reference),
                       400, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodebuild test -project HeartRateBroadcaster.xcodeproj \
  -scheme HeartRateBroadcaster -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HeartRateBroadcasterTests/EnergyModelTests 2>&1 | tail -30
```

Expected: "cannot find 'EnergyModel' in scope".

- [ ] **Step 3: Write the implementation**

Create `Shared/EnergyModel.swift`:

```swift
import Foundation

/// Which model produced a session's figure. Recorded on the session and shown
/// on the summary, because "700 kcal" means different things depending on
/// whether a meter measured it or a regression estimated it.
enum EnergySource: String, Codable, Sendable {
    case power
    case heartRate
    case none
}

/// Energy arithmetic. No state, no frameworks, every constant named.
enum EnergyModel {

    /// Gross mechanical efficiency for trained cycling. The measured range runs
    /// roughly 0.20 to 0.25; 0.24 sits inside it and is what makes the familiar
    /// shorthand — a kilojoule of work costs about a kilocalorie — come out.
    /// Named rather than folded into a magic multiplier so it can be argued
    /// with.
    static let grossEfficiency: Double = 0.24

    static let joulesPerKilocalorie: Double = 4184

    static func joules(watts: Double, seconds: Double) -> Double {
        watts * seconds
    }

    /// Metabolic cost of mechanical work.
    static func kilocalories(joules: Double) -> Double {
        joules / (grossEfficiency * joulesPerKilocalorie)
    }

    /// Keytel et al. (2005), kJ/min in the paper, converted to kcal/min here.
    /// Returns `nil` rather than zero when the profile cannot support it, so a
    /// missing profile is visibly missing instead of quietly reading as no
    /// effort.
    static func kilocaloriesPerMinute(heartRate: Int,
                                      profile: BodyProfile,
                                      on date: Date) -> Double? {
        guard profile.isComplete, let age = profile.age(on: date) else { return nil }
        let hr = Double(heartRate)
        let kg = profile.massKilograms

        func male() -> Double {
            (-55.0969 + 0.6309 * hr + 0.1988 * kg + 0.2017 * age) / 4.184
        }
        func female() -> Double {
            // The mass coefficient is negative in the published equation. That
            // is the paper's fit, not a transcription slip.
            (-20.4022 + 0.4472 * hr - 0.1263 * kg + 0.0740 * age) / 4.184
        }

        let value: Double
        switch profile.sex {
        case .male: value = male()
        case .female: value = female()
        case .unspecified: value = (male() + female()) / 2
        }
        // The regression is linear and crosses zero somewhere around a resting
        // heart rate. Below that it predicts negative expenditure, which is not
        // a thing.
        return max(0, value)
    }

    /// The resting share of the elapsed time, from Mifflin-St Jeor.
    static func restingKilocalories(profile: BodyProfile,
                                    seconds: Double,
                                    on date: Date) -> Double {
        guard let daily = profile.basalRateKcalPerDay(on: date) else { return 0 }
        return daily * seconds / 86_400
    }

    /// What Health means by `activeEnergyBurned`: everything above resting.
    /// Writing the gross figure instead would double-count against the move
    /// ring, which already contains the resting portion.
    static func active(total: Double,
                       profile: BodyProfile,
                       seconds: Double,
                       on date: Date) -> Double {
        max(0, total - restingKilocalories(profile: profile, seconds: seconds, on: date))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: 11 tests pass.

- [ ] **Step 5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add Shared/EnergyModel.swift Tests/EnergyModelTests.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Turn watts and beats into kilocalories, and say which one did it"
```

---

### Task 7: Meter kinds and the workout record

The record is the whole session as a value: what sport, when, what was measured, where the measurement stopped. It is what the history list reads, what the summary displays, and what the crash journal replays. `MeterKind` is here rather than in the central because the record has to name the meters it recorded.

**Files:**
- Create: `Shared/MeterKind.swift`, `Shared/WorkoutRecord.swift`
- Test: `Tests/WorkoutRecordTests.swift`

**Interfaces:**
- Consumes: `EnergySource` (Task 6), `BodyProfile` (Task 5).
- Produces:
  - `enum MeterKind: String, Codable, CaseIterable, Sendable { case cyclingPower, speedCadence, fitnessMachine }`
  - `var serviceUUIDString: String` — `"1818"`, `"1816"`, `"1826"`
  - `var measurementUUIDString: String` — `"2A63"`, `"2A5B"`, `"2AD2"`
  - `var measuresPower: Bool` — true for `.cyclingPower` and `.fitnessMachine`
  - `struct PairedMeter: Codable, Equatable, Identifiable, Sendable` — `id: UUID`, `name: String`, `kind: MeterKind`
  - `enum WorkoutSport: String, Codable, CaseIterable, Identifiable, Sendable { case cycling, running, swimming }`
  - `struct SignalGap: Codable, Equatable, Sendable` — `start: Date`, `end: Date`, `meterName: String?`, `var duration: TimeInterval`
  - `struct MeterTotals: Codable, Equatable, Sendable` — `meterID: UUID`, `meterName: String`, `kind: MeterKind`, `averageWatts: Double`, `maximumWatts: Int`, `kilojoules: Double`, `sampleCount: Int`
  - `struct WorkoutRecord: Codable, Equatable, Identifiable, Sendable` with `id`, `sport`, `start`, `end`, `duration`, `gaps`, `totalKilocalories`, `activeKilocalories`, `energySource`, `primaryMeterID`, `meterTotals`, `averageHeartRate`, `maximumHeartRate`, `averageCadence`, `averagePower`, `maximumPower`, `totalKilojoules`, `savedToHealth`, `profileWasComplete`
  - `var duration: TimeInterval`, `var gapDuration: TimeInterval`, `var recordedDuration: TimeInterval` — wall time, excluded time, and the difference
  - `static func == ` via `Equatable` synthesis

- [ ] **Step 1: Write the failing tests**

Create `Tests/WorkoutRecordTests.swift`:

```swift
import XCTest

/// The record is the only thing that survives the session, so its round trip is
/// the thing that decides whether history exists after a relaunch.
final class WorkoutRecordTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func record() -> WorkoutRecord {
        WorkoutRecord(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            sport: .cycling,
            start: t0,
            end: t0.addingTimeInterval(3600),
            gaps: [SignalGap(start: t0.addingTimeInterval(600),
                             end: t0.addingTimeInterval(900),
                             meterName: "P1")],
            totalKilocalories: 717,
            activeKilocalories: 640,
            energySource: .power,
            primaryMeterID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            meterTotals: [MeterTotals(meterID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                                      meterName: "P1",
                                      kind: .cyclingPower,
                                      averageWatts: 200,
                                      maximumWatts: 620,
                                      kilojoules: 720,
                                      sampleCount: 3300)],
            averageHeartRate: 148,
            maximumHeartRate: 176,
            averageCadence: 89,
            averagePower: 200,
            maximumPower: 620,
            totalKilojoules: 720,
            savedToHealth: true,
            profileWasComplete: true)
    }

    func testDurationIsEndMinusStart() {
        XCTAssertEqual(record().duration, 3600, accuracy: 0.001)
    }

    /// The integral runs over recorded time, not wall time. Five minutes at a
    /// café is not five minutes of soft-pedalling.
    func testRecordedDurationExcludesGaps() {
        XCTAssertEqual(record().recordedDuration, 3300, accuracy: 0.001)
    }

    func testGapDuration() {
        XCTAssertEqual(record().gaps.first?.duration ?? 0, 300, accuracy: 0.001)
    }

    func testCodableRoundTrip() throws {
        let original = record()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkoutRecord.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// A session that recorded nothing still has to encode and decode — an
    /// abandoned start is exactly the case the crash journal replays.
    func testEmptySessionRoundTrips() throws {
        let empty = WorkoutRecord(id: UUID(), sport: .running, start: t0, end: t0,
                                  gaps: [], totalKilocalories: 0, activeKilocalories: 0,
                                  energySource: .none, primaryMeterID: nil, meterTotals: [],
                                  averageHeartRate: nil, maximumHeartRate: nil,
                                  averageCadence: nil, averagePower: nil, maximumPower: nil,
                                  totalKilojoules: 0, savedToHealth: false,
                                  profileWasComplete: false)
        let data = try JSONEncoder().encode(empty)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutRecord.self, from: data), empty)
        XCTAssertEqual(empty.recordedDuration, 0, accuracy: 0.001)
    }

    func testMeterKindMapsToItsService() {
        XCTAssertEqual(MeterKind.cyclingPower.serviceUUIDString, "1818")
        XCTAssertEqual(MeterKind.cyclingPower.measurementUUIDString, "2A63")
        XCTAssertEqual(MeterKind.speedCadence.serviceUUIDString, "1816")
        XCTAssertEqual(MeterKind.speedCadence.measurementUUIDString, "2A5B")
        XCTAssertEqual(MeterKind.fitnessMachine.serviceUUIDString, "1826")
        XCTAssertEqual(MeterKind.fitnessMachine.measurementUUIDString, "2AD2")
    }

    func testSportsAreTheThreeOffered() {
        XCTAssertEqual(WorkoutSport.allCases, [.cycling, .running, .swimming])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodebuild test -project HeartRateBroadcaster.xcodeproj \
  -scheme HeartRateBroadcaster -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HeartRateBroadcasterTests/WorkoutRecordTests 2>&1 | tail -30
```

Expected: "cannot find 'WorkoutRecord' in scope".

- [ ] **Step 3: Write the implementations**

Create `Shared/MeterKind.swift`:

```swift
import Foundation

/// The three GATT services this app subscribes to, and the one characteristic
/// on each that carries measurements.
///
/// The UUIDs are strings rather than `CBUUID` so this file — and the record
/// that names meters — stays free of CoreBluetooth and testable. The central
/// converts at the boundary.
enum MeterKind: String, Codable, CaseIterable, Sendable {
    case cyclingPower
    case speedCadence
    case fitnessMachine

    var serviceUUIDString: String {
        switch self {
        case .cyclingPower:   return "1818"
        case .speedCadence:   return "1816"
        case .fitnessMachine: return "1826"
        }
    }

    var measurementUUIDString: String {
        switch self {
        case .cyclingPower:   return "2A63"
        case .speedCadence:   return "2A5B"
        case .fitnessMachine: return "2AD2"
        }
    }

    /// Whether this kind can report watts. A speed-and-cadence sensor cannot,
    /// so it is never offered as the meter that drives the energy figure.
    var measuresPower: Bool {
        switch self {
        case .cyclingPower, .fitnessMachine: return true
        case .speedCadence: return false
        }
    }
}

/// A meter the user has chosen to keep. The identifier is CoreBluetooth's
/// per-app peripheral UUID, which is stable across launches for the same
/// device and is how a known meter is reconnected without scanning.
struct PairedMeter: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var kind: MeterKind
}
```

Create `Shared/WorkoutRecord.swift`:

```swift
import Foundation

/// The sports offered at Start. Deliberately three: the sport fixes the
/// HealthKit activity type, and a longer list would be a picker rather than a
/// decision.
enum WorkoutSport: String, Codable, CaseIterable, Identifiable, Sendable {
    case cycling
    case running
    case swimming

    var id: String { rawValue }
}

/// A stretch of the session where nothing was being measured — the meter went
/// quiet or the link dropped. Excluded from the integral and named on the
/// summary, so a break reads as a break instead of inflating the total.
struct SignalGap: Codable, Equatable, Sendable {
    let start: Date
    let end: Date
    /// Which meter fell silent, when it was one meter rather than the link.
    let meterName: String?

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// One meter's contribution, kept even for meters that were not primary. Three
/// meters on one bike measure at three points in the drivetrain, and the offset
/// between them is only visible if all three are recorded.
struct MeterTotals: Codable, Equatable, Sendable {
    let meterID: UUID
    let meterName: String
    let kind: MeterKind
    let averageWatts: Double
    let maximumWatts: Int
    let kilojoules: Double
    let sampleCount: Int
}

/// A finished session. Everything the history, the detail screen and the crash
/// recovery need, and nothing that requires HealthKit to interpret.
struct WorkoutRecord: Codable, Equatable, Identifiable, Sendable {

    let id: UUID
    let sport: WorkoutSport
    let start: Date
    let end: Date
    let gaps: [SignalGap]

    let totalKilocalories: Double
    /// What was written to Health: total less the resting share.
    let activeKilocalories: Double
    let energySource: EnergySource

    let primaryMeterID: UUID?
    let meterTotals: [MeterTotals]

    let averageHeartRate: Int?
    let maximumHeartRate: Int?
    let averageCadence: Double?
    let averagePower: Double?
    let maximumPower: Int?
    let totalKilojoules: Double

    /// False when Health refused the write. Surfaced once on the summary; the
    /// session is still in the history either way.
    let savedToHealth: Bool
    /// False when the energy figure was produced without a full body profile,
    /// which is worth saying next to the number rather than burying.
    let profileWasComplete: Bool

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Seconds excluded because a meter went quiet. Reported in the summary so
    /// a short-looking ride explains itself.
    var gapDuration: TimeInterval { gaps.reduce(0) { $0 + $1.duration } }

    /// Wall time less the gaps. This is the denominator for averages and the
    /// span the integral actually covers.
    var recordedDuration: TimeInterval {
        max(0, duration - gapDuration)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: 7 tests pass.

- [ ] **Step 5: Run the whole Shared suite**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodebuild test -project HeartRateBroadcaster.xcodeproj \
  -scheme HeartRateBroadcaster -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HeartRateBroadcasterTests 2>&1 | tail -20
```

Expected: every test passes, including the pre-existing `HeartRateFusionTests`, `HeartRateFrameTests` and `ThemeSmokeTests`.

- [ ] **Step 6: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add Shared/MeterKind.swift Shared/WorkoutRecord.swift Tests/WorkoutRecordTests.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Describe a finished session as a value that outlives the app"
```

---

### Task 8: Central-role entitlement and the meter registry

Two things the radio work needs before it can exist: permission to scan in the background, and somewhere to remember which meters belong to this bike. The usage string also has to change — it currently only claims the app *advertises*, which is now half the truth and would be a plausible review rejection.

**Files:**
- Modify: `project.yml:103-134`
- Create: `HeartRateBroadcaster/Models/MeterRegistry.swift`

**Interfaces:**
- Consumes: `PairedMeter`, `MeterKind` (Task 7).
- Produces:
  - `@Observable @MainActor final class MeterRegistry`
  - `var paired: [PairedMeter]` — persisted
  - `var primaryMeterID: UUID?` — persisted
  - `var primary: PairedMeter?`
  - `func remember(_ meter: PairedMeter)` — insert or update by id; first cycling-power meter becomes primary automatically
  - `func forget(_ id: UUID)`
  - `func setPrimary(_ id: UUID?)`
  - `var hasPowerCapableMeter: Bool` — true when any paired meter is `.cyclingPower` or `.fitnessMachine`

- [ ] **Step 1: Add the background mode and correct the usage string**

In `project.yml`, under the iOS target's `info.properties`, change `UIBackgroundModes` so it reads:

```yaml
        UIBackgroundModes:
          - bluetooth-peripheral
          # The app is now also a central: it subscribes to power meters. A
          # ride continues with the screen off and the phone in a jersey
          # pocket, so the subscriptions have to survive backgrounding the
          # same way the advertisement does.
          - bluetooth-central
```

keeping the existing `audio` entry and every existing comment beneath it exactly as it is.

Then replace the Bluetooth usage string:

```yaml
        NSBluetoothAlwaysUsageDescription: "HeartRate Broadcaster advertises as a standard Bluetooth heart rate monitor so devices like Garmin and Wahoo can receive your heart rate, and connects to your power meter, cadence sensor or trainer to record a workout."
```

- [ ] **Step 2: Mirror the string into the catalog**

`InfoPlist.xcstrings` holds the localized copies. Open `HeartRateBroadcaster/Resources/InfoPlist.xcstrings` and update the `NSBluetoothAlwaysUsageDescription` English (`en`) value to the same sentence, and mark every other language's state as `needs_review` by setting `"state": "needs_review"` on each existing localization for that key. Do not delete the other languages — the release step retranslates them.

- [ ] **Step 3: Regenerate and confirm the project still builds**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild build -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Write the registry**

Create `HeartRateBroadcaster/Models/MeterRegistry.swift`:

```swift
import Foundation
import Observation

/// Which meters belong to this rider, and which one's watts are the ones that
/// count.
///
/// Persisted as JSON in `UserDefaults` rather than as a spread of scalar keys,
/// because the list is variable-length. `AppSettings` is the pattern for the
/// scalar settings; this is a list, so it gets its own store.
@Observable
@MainActor
final class MeterRegistry {

    private static let pairedKey = "meters.paired"
    private static let primaryKey = "meters.primary"

    private(set) var paired: [PairedMeter] = [] {
        didSet { persistPaired() }
    }

    private(set) var primaryMeterID: UUID? {
        didSet {
            if let primaryMeterID {
                UserDefaults.standard.set(primaryMeterID.uuidString, forKey: Self.primaryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.primaryKey)
            }
        }
    }

    var primary: PairedMeter? {
        guard let primaryMeterID else { return nil }
        return paired.first { $0.id == primaryMeterID }
    }

    /// A cadence-only sensor cannot drive the energy figure, so the recorder
    /// needs to know whether any paired meter can measure work at all.
    var hasPowerCapableMeter: Bool {
        paired.contains { $0.kind == .cyclingPower || $0.kind == .fitnessMachine }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.pairedKey),
           let decoded = try? JSONDecoder().decode([PairedMeter].self, from: data) {
            paired = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: Self.primaryKey) {
            primaryMeterID = UUID(uuidString: raw)
        }
    }

    /// Idempotent by identifier: reconnecting a known meter refreshes its name
    /// rather than adding a duplicate row.
    func remember(_ meter: PairedMeter) {
        if let index = paired.firstIndex(where: { $0.id == meter.id }) {
            paired[index] = meter
        } else {
            paired.append(meter)
        }
        // The first meter that can measure work becomes primary, so the common
        // case — one power meter — never requires a visit to settings.
        if primaryMeterID == nil,
           meter.kind == .cyclingPower || meter.kind == .fitnessMachine {
            primaryMeterID = meter.id
        }
    }

    func forget(_ id: UUID) {
        paired.removeAll { $0.id == id }
        if primaryMeterID == id {
            primaryMeterID = paired.first { $0.kind == .cyclingPower || $0.kind == .fitnessMachine }?.id
        }
    }

    func setPrimary(_ id: UUID?) {
        primaryMeterID = id
    }

    private func persistPaired() {
        guard let data = try? JSONEncoder().encode(paired) else { return }
        UserDefaults.standard.set(data, forKey: Self.pairedKey)
    }
}
```

- [ ] **Step 5: Build**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild build -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add project.yml HeartRateBroadcaster/Models/MeterRegistry.swift HeartRateBroadcaster/Resources/InfoPlist.xcstrings
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Ask for the central role, and remember which meters are yours"
```

---

### Task 9: The power meter central

The app already runs a `CBPeripheralManager`. This adds a `CBCentralManager` beside it — the two roles coexist on one radio and do not need to know about each other. Its state vocabulary deliberately mirrors `BLEBroadcaster.mapped(_:)` so the status rows read the same whichever radio role is unhappy.

**Files:**
- Create: `HeartRateBroadcaster/Models/PowerMeterCentral.swift`
- Reference: `HeartRateBroadcaster/Models/BLEBroadcaster.swift` for the state mapping and comment voice

**Interfaces:**
- Consumes: `MeterKind`, `PairedMeter` (Task 7), the three parsers (Tasks 1-3), `CadenceTracker` (Task 4), `MeterRegistry` (Task 8).
- Produces:
  - `struct MeterSample: Sendable` — `meterID: UUID`, `meterName: String`, `kind: MeterKind`, `watts: Int?`, `cadenceRPM: Double?`, `at: Date`
  - `@Observable @MainActor final class PowerMeterCentral: NSObject`
  - `enum Availability: String { case unknown, unsupported, unauthorized, off, ready }`
  - `var availability: Availability`
  - `var discovered: [PairedMeter]` — seen this scan, not yet remembered
  - `var connected: Set<UUID>`
  - `var latest: [UUID: MeterSample]`
  - `var onSample: ((MeterSample) -> Void)?`
  - `init(registry: MeterRegistry)`
  - `func startScanning()`, `func stopScanning()`
  - `func connect(_ id: UUID)`, `func disconnect(_ id: UUID)`
  - `func reconnectKnownMeters()`

- [ ] **Step 1: Write the central**

Create `HeartRateBroadcaster/Models/PowerMeterCentral.swift`:

```swift
import CoreBluetooth
import Foundation
import Observation

/// One notification from one meter, already parsed.
///
/// Deliberately not a class and deliberately not the meter's own state: three
/// meters send at their own rates, and the recorder wants each arrival stamped
/// with the meter it came from rather than a single mutable "current power"
/// that whichever meter notified last would win.
struct MeterSample: Sendable {
    let meterID: UUID
    let meterName: String
    let kind: MeterKind
    let watts: Int?
    let cadenceRPM: Double?
    let at: Date
}

/// The Bluetooth *central* half of the app: it finds power meters, cadence
/// sensors and trainers, subscribes to their measurement characteristics, and
/// hands each notification on as a `MeterSample`.
///
/// `BLEBroadcaster` runs a `CBPeripheralManager` at the same time. Both roles
/// on one radio is ordinary; they share nothing but the hardware. The state
/// vocabulary here mirrors the broadcaster's on purpose, so a powered-off radio
/// says the same thing in both status rows instead of two different sentences
/// about the same switch.
@Observable
@MainActor
final class PowerMeterCentral: NSObject {

    enum Availability: String {
        case unknown
        case unsupported
        case unauthorized
        case off
        case ready
    }

    private(set) var availability: Availability = .unknown
    private(set) var isScanning = false

    /// Meters seen during this scan. Includes ones already paired — the
    /// settings screen shows both, distinguished by the registry.
    private(set) var discovered: [PairedMeter] = []
    private(set) var connected: Set<UUID> = []
    private(set) var latest: [UUID: MeterSample] = [:]

    /// Called on the main actor for every parsed notification.
    var onSample: ((MeterSample) -> Void)?

    private let registry: MeterRegistry
    private var manager: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var kinds: [UUID: MeterKind] = [:]
    private var crankTrackers: [UUID: CadenceTracker] = [:]

    private static let services: [CBUUID] = MeterKind.allCases.map { CBUUID(string: $0.serviceUUIDString) }

    init(registry: MeterRegistry) {
        self.registry = registry
        super.init()
        // `showPowerAlert: false` — the app already explains a powered-off
        // radio in its own status row, and a system alert on launch for a
        // feature the user may not be using is noise.
        manager = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    // MARK: - Scanning

    func startScanning() {
        guard availability == .ready else { return }
        discovered.removeAll()
        // Duplicate keys off: a meter only needs to be discovered once, and
        // leaving them on turns a busy garage into a constant stream of
        // callbacks for peripherals already in the list.
        manager.scanForPeripherals(withServices: Self.services,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
    }

    func stopScanning() {
        guard isScanning else { return }
        manager.stopScan()
        isScanning = false
    }

    /// Reconnects everything in the registry without scanning. CoreBluetooth
    /// keeps its own record of peripherals this app has seen, so a known meter
    /// can be retrieved by identifier and connected the moment it wakes.
    func reconnectKnownMeters() {
        guard availability == .ready, !registry.paired.isEmpty else { return }
        let known = manager.retrievePeripherals(withIdentifiers: registry.paired.map(\.id))
        for peripheral in known {
            peripherals[peripheral.identifier] = peripheral
            kinds[peripheral.identifier] = registry.paired.first { $0.id == peripheral.identifier }?.kind
            manager.connect(peripheral, options: nil)
        }
    }

    func connect(_ id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        manager.connect(peripheral, options: nil)
    }

    func disconnect(_ id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        manager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - State

    private func mapped(_ cbState: CBManagerState) -> Availability {
        switch cbState {
        case .unsupported:  return .unsupported
        case .unauthorized: return .unauthorized
        case .poweredOff:   return .off
        case .poweredOn:    return .ready
        default:            return .unknown
        }
    }

    fileprivate func ingest(_ sample: MeterSample) {
        latest[sample.meterID] = sample
        onSample?(sample)
    }
}

// MARK: - CBCentralManagerDelegate

extension PowerMeterCentral: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            availability = mapped(state)
            if availability == .ready {
                reconnectKnownMeters()
            } else {
                connected.removeAll()
                isScanning = false
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        // A trainer advertises several services; the most capable one wins,
        // because a Kickr that reports Indoor Bike Data is more useful read as
        // a trainer than as a wheel-speed sensor.
        let kind: MeterKind? = MeterKind.allCases.first { candidate in
            advertised.contains(CBUUID(string: candidate.serviceUUIDString))
        }
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        Task { @MainActor in
            guard let kind else { return }
            peripherals[id] = peripheral
            kinds[id] = kind
            let entry = PairedMeter(id: id,
                                    name: name ?? String(localized: "Unnamed meter",
                                                          comment: "Fallback title for a Bluetooth power meter that advertises no name"),
                                    kind: kind)
            if let index = discovered.firstIndex(where: { $0.id == id }) {
                discovered[index] = entry
            } else {
                discovered.append(entry)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        Task { @MainActor in
            connected.insert(id)
            crankTrackers[id] = CadenceTracker()
            peripheral.delegate = self
            peripheral.discoverServices(Self.services)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        let id = peripheral.identifier
        Task { @MainActor in
            connected.remove(id)
            crankTrackers[id]?.reset()
            // A meter that sleeps between rides disconnects constantly. Asking
            // to connect again is free and means the next pedal stroke wakes
            // the link without the user opening anything.
            if registry.paired.contains(where: { $0.id == id }) {
                central.connect(peripheral, options: nil)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension PowerMeterCentral: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            let wanted = MeterKind.allCases
                .filter { CBUUID(string: $0.serviceUUIDString) == service.uuid }
                .map { CBUUID(string: $0.measurementUUIDString) }
            peripheral.discoverCharacteristics(wanted, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        let id = peripheral.identifier
        let uuid = characteristic.uuid.uuidString.uppercased()
        let name = peripheral.name
        let now = Date()

        Task { @MainActor in
            guard let kind = kinds[id] else { return }
            let label = name ?? registry.paired.first { $0.id == id }?.name ?? "—"
            var watts: Int?
            var cadence: Double?

            switch uuid {
            case MeterKind.cyclingPower.measurementUUIDString:
                guard let m = CyclingPowerMeasurement(bytes) else { return }
                watts = m.watts
                if let revs = m.cumulativeCrankRevolutions, let time = m.lastCrankEventTime {
                    var tracker = crankTrackers[id] ?? CadenceTracker()
                    tracker.submit(revolutions: revs, eventTime: time)
                    crankTrackers[id] = tracker
                    cadence = tracker.rpm
                }
            case MeterKind.speedCadence.measurementUUIDString:
                guard let m = CSCMeasurement(bytes) else { return }
                if let revs = m.cumulativeCrankRevolutions, let time = m.lastCrankEventTime {
                    var tracker = crankTrackers[id] ?? CadenceTracker()
                    tracker.submit(revolutions: revs, eventTime: time)
                    crankTrackers[id] = tracker
                    cadence = tracker.rpm
                }
            case MeterKind.fitnessMachine.measurementUUIDString:
                guard let m = IndoorBikeData(bytes) else { return }
                watts = m.watts
                cadence = m.cadenceRPM
            default:
                return
            }

            ingest(MeterSample(meterID: id, meterName: label, kind: kind,
                               watts: watts, cadenceRPM: cadence, at: now))
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild build -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. If Swift 6 complains that `Self.services` is not available from a `nonisolated` context, hoist it to a file-private `let meterServiceUUIDs: [CBUUID]` at file scope.

- [ ] **Step 3: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add HeartRateBroadcaster/Models/PowerMeterCentral.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Listen to the meters on the bike, all three of them"
```

---

### Task 10: One session, two consumers

`PhoneWorkoutManager` currently hardcodes indoor cycling and always discards. Both were correct for a sensor bridge and neither is correct now. The change is small and surgical: the configuration is injected, and the discard becomes conditional on whether anyone asked for the workout to be kept.

**Files:**
- Modify: `HeartRateBroadcaster/Models/PhoneWorkoutManager.swift`

**Interfaces:**
- Consumes: `WorkoutSport` (Task 7).
- Produces:
  - `func start(sport: WorkoutSport?, keepWorkout: Bool) async` — replaces `start()`; `sport: nil` keeps today's `.cycling`/`.indoor` bridging behaviour
  - `func stop() async -> HKWorkout?` — returns the finished workout when `keepWorkout` was true, `nil` when it discarded
  - `var isKeepingWorkout: Bool`
  - `var builderStart: Date?`
  - `var State.isActive: Bool` — true for `.starting` and `.running`; add it to the existing `State` enum so callers do not pattern-match on cases they do not own
  - `func addEnergy(kilocalories: Double, from: Date, to: Date) async`

- [ ] **Step 1: Add the sport-to-configuration mapping**

First, add to the existing `State` enum at `PhoneWorkoutManager.swift:28-36`:

```swift
        /// A session exists on the device. The recorder needs this to decide
        /// whether it must replace a bridging session before starting its own.
        var isActive: Bool {
            switch self {
            case .starting, .running: return true
            default: return false
            }
        }
```

Then, above the class, add:

```swift
extension WorkoutSport {
    /// The activity type is fixed when the session is created and cannot be
    /// changed while it runs, which is why the sport is asked for before Start
    /// rather than at the summary.
    var activityType: HKWorkoutActivityType {
        switch self {
        case .cycling:  return .cycling
        case .running:  return .running
        case .swimming: return .swimming
        }
    }

    /// Indoor is the honest default for a session the phone is recording from
    /// a trainer or a treadmill; a swim is a pool unless proven otherwise, and
    /// nothing here reads GPS, so claiming outdoor would be a claim about data
    /// the app does not have.
    var locationType: HKWorkoutSessionLocationType {
        switch self {
        case .cycling, .running: return .indoor
        case .swimming:          return .indoor
        }
    }
}
```

- [ ] **Step 2: Replace the hardcoded configuration**

Find the block in `start()`:

```swift
        let config = HKWorkoutConfiguration()
        config.activityType = .cycling
        config.locationType = .indoor
```

and change the signature and that block to:

```swift
    /// `sport: nil` is the bridge's own session — the one that exists solely so
    /// AirPods will report heart rate. `keepWorkout: true` is a recording the
    /// user asked for, and it is the only case that survives `stop()`.
    func start(sport: WorkoutSport? = nil, keepWorkout: Bool = false) async {
        ...
        let config = HKWorkoutConfiguration()
        config.activityType = sport?.activityType ?? .cycling
        config.locationType = sport?.locationType ?? .indoor
        isKeepingWorkout = keepWorkout
```

leaving every other line of `start()` — the authorization request, the audio-route checks, the `Progress` transitions — untouched.

Add the two stored properties near the other `private(set) var`s:

```swift
    /// True when this session is a recording rather than a bridge. The only
    /// thing it changes is what `stop()` does with the builder.
    private(set) var isKeepingWorkout = false

    /// When the builder actually began collecting, which is the start Health
    /// will stamp on the workout — not when the user tapped Start.
    private(set) var builderStart: Date?
```

and set `builderStart = startDate` immediately after the existing `builder.beginCollection(withStart:)` call succeeds.

- [ ] **Step 3: Make the discard conditional**

Find:

```swift
        // Nothing here is a workout the user wants saved — this app is a sensor
        // bridge, not a training log. Discarding avoids littering Health with
        // phantom rides.
        builder.discardWorkout()
```

Replace with:

```swift
        // Bridging still discards: a session started only so AirPods would
        // report heart rate is not a ride, and saving it would litter Health
        // with phantom workouts. A session the user started deliberately is
        // the opposite case, and it is the one thing that finishes.
        guard isKeepingWorkout else {
            builder.discardWorkout()
            teardown()
            return nil
        }
        do {
            try await builder.endCollection(at: Date())
            let workout = try await builder.finishWorkout()
            teardown()
            return workout
        } catch {
            builder.discardWorkout()
            teardown()
            return nil
        }
```

and change the signature of `stop()` to `func stop() async -> HKWorkout?`, returning `nil` from each existing early-return path.

- [ ] **Step 4: Add the energy passthrough**

Append to the class:

```swift
    /// Adds the recorder's energy figure to the builder so the saved workout
    /// carries a total rather than whatever HealthKit inferred from heart rate
    /// alone. Called once at Stop, over the session's own span.
    func addEnergy(kilocalories: Double, from: Date, to: Date) async {
        guard isKeepingWorkout, kilocalories > 0, let builder else { return }
        let type = HKQuantityType(.activeEnergyBurned)
        let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: kilocalories)
        let sample = HKCumulativeQuantitySample(type: type, quantity: quantity,
                                                start: from, end: max(to, from.addingTimeInterval(1)))
        try? await builder.add([sample])
    }
```

- [ ] **Step 5: Fix every existing call site**

```bash
cd "$(git rev-parse --show-toplevel)" && grep -rn "workoutManager.start()\|phoneWorkout.start()\|\.stop()" HeartRateBroadcaster --include=*.swift
```

Every existing `start()` call keeps working through the defaults. Any call site that now warns about an unused `HKWorkout?` result gets `_ = await ...stop()`.

- [ ] **Step 6: Build and run the suite**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild test -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`, all tests pass.

- [ ] **Step 7: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add HeartRateBroadcaster/Models/PhoneWorkoutManager.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Let the one session be kept when someone asked for it"
```

---

### Task 11: The workout store

One JSON file per session in Application Support, plus a journal that is written at Start and deleted at Stop. If the journal exists at launch, the app was killed mid-session and the ride is offered back rather than lost.

**Files:**
- Create: `HeartRateBroadcaster/Models/WorkoutStore.swift`

**Interfaces:**
- Consumes: `WorkoutRecord`, `WorkoutSport` (Task 7).
- Produces:
  - `@Observable @MainActor final class WorkoutStore`
  - `private(set) var records: [WorkoutRecord]` — newest first
  - `func save(_ record: WorkoutRecord)`
  - `func delete(_ id: UUID)`
  - `struct Journal: Codable, Sendable` — `id: UUID`, `sport: WorkoutSport`, `start: Date`
  - `func openJournal(id: UUID, sport: WorkoutSport, start: Date)`
  - `func closeJournal()`
  - `func abandonedSession() -> Journal?`

- [ ] **Step 1: Write the store**

Create `HeartRateBroadcaster/Models/WorkoutStore.swift`:

```swift
import Foundation
import Observation

/// Sessions on disk.
///
/// One file per session rather than one growing array, so a single corrupt
/// write costs one ride instead of the history. The list is rebuilt by reading
/// the directory at launch, which means there is no index to fall out of sync
/// with the files it describes.
@Observable
@MainActor
final class WorkoutStore {

    /// What was known at Start. Written before the first sample and removed at
    /// Stop, so its presence at launch means exactly one thing: the app did not
    /// reach Stop.
    struct Journal: Codable, Sendable {
        let id: UUID
        let sport: WorkoutSport
        let start: Date
    }

    private(set) var records: [WorkoutRecord] = []

    private let directory: URL
    private let journalURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Workouts", isDirectory: true)
        journalURL = base.appendingPathComponent("session-journal.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        records = files
            .filter { $0.pathExtension == "json" }
            // A file that will not decode is skipped rather than fatal: one bad
            // ride must not take the history down with it.
            .compactMap { try? decoder.decode(WorkoutRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.start > $1.start }
    }

    func save(_ record: WorkoutRecord) {
        guard let data = try? encoder.encode(record) else { return }
        let url = directory.appendingPathComponent("\(record.id.uuidString).json")
        try? data.write(to: url, options: .atomic)
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        records.sort { $0.start > $1.start }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
        records.removeAll { $0.id == id }
    }

    // MARK: - Crash journal

    func openJournal(id: UUID, sport: WorkoutSport, start: Date) {
        guard let data = try? encoder.encode(Journal(id: id, sport: sport, start: start)) else { return }
        try? data.write(to: journalURL, options: .atomic)
    }

    func closeJournal() {
        try? FileManager.default.removeItem(at: journalURL)
    }

    /// A journal left behind by a session that never reached Stop. The samples
    /// are gone — they lived in memory — but the sport, the start and the fact
    /// that a ride happened are recoverable, which is enough to offer the user
    /// a session rather than silently pretending it never began.
    func abandonedSession() -> Journal? {
        guard let data = try? Data(contentsOf: journalURL) else { return nil }
        return try? decoder.decode(Journal.self, from: data)
    }
}
```

- [ ] **Step 2: Build**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild build -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`. `Data(contentsOf:)` inside `compactMap` throws, so it must be inside the `try?` — if the compiler objects, rewrite that line as `.compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(WorkoutRecord.self, from: $0) } }`.

- [ ] **Step 3: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add HeartRateBroadcaster/Models/WorkoutStore.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Keep each ride in its own file, and leave a note while one is running"
```

---

### Task 12: The workout recorder

The state machine. It holds a session open, takes heart rate from the manager and power from the central, integrates work over recorded time, notices when a meter goes quiet, and at Stop produces a `WorkoutRecord` and hands the energy to HealthKit.

**Files:**
- Create: `HeartRateBroadcaster/Models/WorkoutRecorder.swift`

**Interfaces:**
- Consumes: everything from Tasks 1-11.
- Produces:
  - `@Observable @MainActor final class WorkoutRecorder`
  - `enum State: Equatable { case idle, starting, recording, stopping }`
  - `var state: State`, `var sport: WorkoutSport`, `var start: Date?`
  - `var elapsed: TimeInterval`, `var currentWatts: Int?`, `var currentCadence: Double?`
  - `var runningKilocalories: Double`, `var energySource: EnergySource`
  - `var lastRecord: WorkoutRecord?`
  - `init(store:registry:central:workout:profile:)`
  - `func begin(sport: WorkoutSport) async`
  - `func end() async -> WorkoutRecord?`
  - `func ingest(heartRate: Int, at: Date)`
  - `func ingest(_ sample: MeterSample)`
  - `func tick(now: Date)`
  - `static let silenceThreshold: TimeInterval` = 3

- [ ] **Step 1: Write the recorder**

Create `HeartRateBroadcaster/Models/WorkoutRecorder.swift`:

```swift
import Foundation
import HealthKit
import Observation

/// A session, from Start to a saved record.
///
/// Energy accrues incrementally rather than being computed at Stop from a list
/// of samples: the running figure on screen and the saved figure are then the
/// same arithmetic, and there is no chance of the summary disagreeing with what
/// the user watched for an hour.
@Observable
@MainActor
final class WorkoutRecorder {

    enum State: Equatable {
        case idle
        case starting
        case recording
        case stopping

        var isLive: Bool { self == .recording || self == .starting }
    }

    /// A power meter notifies about once a second whether or not you are
    /// pedalling — a coast reports a real zero. Three seconds of nothing is the
    /// link, not the rider.
    static let silenceThreshold: TimeInterval = 3

    private(set) var state: State = .idle
    private(set) var sport: WorkoutSport = .cycling
    private(set) var start: Date?
    private(set) var elapsed: TimeInterval = 0

    private(set) var currentWatts: Int?
    private(set) var currentCadence: Double?
    private(set) var runningKilocalories: Double = 0
    private(set) var energySource: EnergySource = .none
    private(set) var lastRecord: WorkoutRecord?

    /// Body profile is read at Start and held for the session, so editing it
    /// mid-ride cannot retroactively change a figure already on screen.
    var profileProvider: () -> BodyProfile

    private let store: WorkoutStore
    private let registry: MeterRegistry
    private let central: PowerMeterCentral
    private let workout: PhoneWorkoutManager

    private var sessionID = UUID()
    private var profile: BodyProfile = .unset

    // Accumulators.
    private var joules: Double = 0
    private var lastPowerAt: Date?
    private var lastIntegratedAt: Date?
    private var heartRateSum: Double = 0
    private var heartRateCount: Int = 0
    private var maximumHeartRate: Int = 0
    private var lastHeartRate: Int?
    private var lastHeartRateAt: Date?
    private var cadenceSum: Double = 0
    private var cadenceCount: Int = 0
    private var maximumWatts: Int = 0
    private var wattsSum: Double = 0
    private var wattsCount: Int = 0

    private var perMeter: [UUID: (name: String, kind: MeterKind, sum: Double, max: Int, joules: Double, count: Int, lastAt: Date?)] = [:]

    private var gaps: [SignalGap] = []
    private var openGapStart: Date?

    init(store: WorkoutStore,
         registry: MeterRegistry,
         central: PowerMeterCentral,
         workout: PhoneWorkoutManager,
         profileProvider: @escaping () -> BodyProfile) {
        self.store = store
        self.registry = registry
        self.central = central
        self.workout = workout
        self.profileProvider = profileProvider
    }

    /// Cycling when a meter that can measure work is paired, because that is
    /// the session the hardware is describing. Otherwise whatever was chosen
    /// last.
    var suggestedSport: WorkoutSport {
        registry.hasPowerCapableMeter ? .cycling : sport
    }

    // MARK: - Lifecycle

    func begin(sport: WorkoutSport) async {
        guard state == .idle else { return }
        state = .starting
        self.sport = sport
        sessionID = UUID()
        profile = profileProvider()
        resetAccumulators()

        let now = Date()
        start = now
        lastIntegratedAt = now
        store.openJournal(id: sessionID, sport: sport, start: now)

        // The one session. If a bridging session is already running it has the
        // wrong activity type and cannot be reconfigured, so it is stopped and
        // replaced — the heart rate stream resumes within a second.
        if workout.state.isActive {
            _ = await workout.stop()
        }
        await workout.start(sport: sport, keepWorkout: true)
        state = .recording
    }

    func end() async -> WorkoutRecord? {
        guard state == .recording, let start else { return nil }
        state = .stopping
        let now = Date()
        integrate(to: now)
        closeGap(at: now)

        let recordedSeconds = max(0, now.timeIntervalSince(start) - gaps.reduce(0) { $0 + $1.duration })
        let active = EnergyModel.active(total: runningKilocalories,
                                        profile: profile,
                                        seconds: recordedSeconds,
                                        on: now)

        await workout.addEnergy(kilocalories: active, from: start, to: now)
        let saved = await workout.stop()

        let record = WorkoutRecord(
            id: sessionID,
            sport: sport,
            start: start,
            end: now,
            gaps: gaps,
            totalKilocalories: runningKilocalories,
            activeKilocalories: active,
            energySource: energySource,
            primaryMeterID: registry.primaryMeterID,
            meterTotals: perMeter.map { id, m in
                MeterTotals(meterID: id, meterName: m.name, kind: m.kind,
                            averageWatts: m.count > 0 ? m.sum / Double(m.count) : 0,
                            maximumWatts: m.max,
                            kilojoules: m.joules / 1000,
                            sampleCount: m.count)
            }.sorted { $0.meterName < $1.meterName },
            averageHeartRate: heartRateCount > 0 ? Int((heartRateSum / Double(heartRateCount)).rounded()) : nil,
            maximumHeartRate: maximumHeartRate > 0 ? maximumHeartRate : nil,
            averageCadence: cadenceCount > 0 ? cadenceSum / Double(cadenceCount) : nil,
            averagePower: wattsCount > 0 ? wattsSum / Double(wattsCount) : nil,
            maximumPower: maximumWatts > 0 ? maximumWatts : nil,
            totalKilojoules: joules / 1000,
            savedToHealth: saved != nil,
            profileWasComplete: profile.isComplete)

        store.save(record)
        store.closeJournal()
        lastRecord = record
        state = .idle
        self.start = nil
        return record
    }

    // MARK: - Ingestion

    func ingest(heartRate: Int, at date: Date) {
        guard state == .recording else { return }
        lastHeartRate = heartRate
        lastHeartRateAt = date
        heartRateSum += Double(heartRate)
        heartRateCount += 1
        maximumHeartRate = max(maximumHeartRate, heartRate)
    }

    func ingest(_ sample: MeterSample) {
        guard state == .recording else { return }
        var entry = perMeter[sample.meterID] ?? (sample.meterName, sample.kind, 0, 0, 0, 0, nil)
        entry.name = sample.meterName

        if let watts = sample.watts {
            let span = entry.lastAt.map { min(sample.at.timeIntervalSince($0), Self.silenceThreshold) } ?? 0
            entry.joules += EnergyModel.joules(watts: Double(watts), seconds: span)
            entry.sum += Double(watts)
            entry.max = max(entry.max, watts)
            entry.count += 1
        }
        entry.lastAt = sample.at
        perMeter[sample.meterID] = entry

        // Only the primary meter's watts reach the integral. Three meters
        // measuring at three points in the drivetrain disagree for physical
        // reasons, and averaging them would describe no point on the bike.
        guard sample.meterID == registry.primaryMeterID else { return }
        if let watts = sample.watts {
            integrate(to: sample.at)
            closeGap(at: sample.at)
            currentWatts = watts
            lastPowerAt = sample.at
            wattsSum += Double(watts)
            wattsCount += 1
            maximumWatts = max(maximumWatts, watts)
            energySource = .power
        }
        if let cadence = sample.cadenceRPM {
            currentCadence = cadence
            cadenceSum += cadence
            cadenceCount += 1
        }
    }

    /// Called once a second by the manager's existing timer. Advances the
    /// integral, and decides whether the primary meter has gone quiet.
    func tick(now: Date) {
        guard state == .recording, let start else { return }
        elapsed = now.timeIntervalSince(start)
        integrate(to: now)

        let silent = lastPowerAt.map { now.timeIntervalSince($0) > Self.silenceThreshold } ?? (registry.primary != nil)
        if silent && registry.primary != nil {
            openGap(at: lastPowerAt.map { $0.addingTimeInterval(Self.silenceThreshold) } ?? start,
                    meterName: registry.primary?.name)
            currentWatts = nil
        }
    }

    // MARK: - Integration

    /// Advances the energy figure to `now`. Power when the primary meter is
    /// speaking, heart rate when it is not, and nothing at all across a gap.
    private func integrate(to now: Date) {
        guard let previous = lastIntegratedAt, now > previous else { return }
        defer { lastIntegratedAt = now }
        guard openGapStart == nil else { return }
        let span = now.timeIntervalSince(previous)

        if let watts = currentWatts, registry.primary != nil {
            let addedJoules = EnergyModel.joules(watts: Double(watts), seconds: span)
            joules += addedJoules
            runningKilocalories += EnergyModel.kilocalories(joules: addedJoules)
            energySource = .power
            return
        }

        // No power. A heart rate no older than the fusion's own hold window is
        // still a measurement; anything older is silence and contributes
        // nothing rather than freezing the last beat into an hour of effort.
        if let bpm = lastHeartRate,
           let at = lastHeartRateAt,
           now.timeIntervalSince(at) < 10,
           let perMinute = EnergyModel.kilocaloriesPerMinute(heartRate: bpm, profile: profile, on: now) {
            runningKilocalories += perMinute * span / 60
            if energySource != .power { energySource = .heartRate }
        }
    }

    private func openGap(at date: Date, meterName: String?) {
        guard openGapStart == nil else { return }
        openGapStart = date
        pendingGapMeter = meterName
    }

    private var pendingGapMeter: String?

    private func closeGap(at date: Date) {
        guard let openGapStart, date > openGapStart else {
            self.openGapStart = nil
            return
        }
        gaps.append(SignalGap(start: openGapStart, end: date, meterName: pendingGapMeter))
        self.openGapStart = nil
        pendingGapMeter = nil
        lastIntegratedAt = date
    }

    private func resetAccumulators() {
        joules = 0
        runningKilocalories = 0
        energySource = .none
        elapsed = 0
        currentWatts = nil
        currentCadence = nil
        lastPowerAt = nil
        lastIntegratedAt = nil
        heartRateSum = 0; heartRateCount = 0; maximumHeartRate = 0
        lastHeartRate = nil; lastHeartRateAt = nil
        cadenceSum = 0; cadenceCount = 0
        wattsSum = 0; wattsCount = 0; maximumWatts = 0
        perMeter = [:]
        gaps = []
        openGapStart = nil
        pendingGapMeter = nil
    }
}
```

- [ ] **Step 2: Build**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild build -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. Move `private var pendingGapMeter: String?` up with the other stored properties if the compiler objects to its position.

- [ ] **Step 3: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add HeartRateBroadcaster/Models/WorkoutRecorder.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Integrate the ride as it happens, and stop counting when it stops"
```

---

### Task 13: Profile settings and the manager wiring

The profile joins `AppSettings` following its existing `didSet`-persists pattern exactly. `HeartRateManager` gains the four new objects and two calls.

**Files:**
- Modify: `HeartRateBroadcaster/Models/AppSettings.swift`, `HeartRateBroadcaster/Models/HeartRateManager.swift`

**Interfaces:**
- Produces on `AppSettings`: `var bodyMassKilograms: Double`, `var bodyHeightCentimetres: Double`, `var dateOfBirth: Date?`, `var biologicalSex: BiologicalSex`, `var usesMetricBody: Bool`, `var bodyProfile: BodyProfile { get }`
- Produces on `HeartRateManager`: `let meters: MeterRegistry`, `let central: PowerMeterCentral`, `let workoutStore: WorkoutStore`, `let recorder: WorkoutRecorder`

- [ ] **Step 1: Add the profile to AppSettings**

In `AppSettings.swift`, add alongside the existing properties, matching their `didSet { store(...) }` shape:

```swift
    /// Held in SI whatever the field shows, so the energy model never has to
    /// ask which unit it was handed. See `BodyProfile`.
    var bodyMassKilograms: Double = 0 { didSet { store(bodyMassKilograms, "body.massKg") } }
    var bodyHeightCentimetres: Double = 0 { didSet { store(bodyHeightCentimetres, "body.heightCm") } }
    /// `store(_:_:)` takes a non-optional `Any`; a nil date has to clear the
    /// key rather than write an optional into defaults.
    var dateOfBirth: Date? {
        didSet {
            if let dateOfBirth { defaults.set(dateOfBirth, forKey: "body.dob") }
            else { defaults.removeObject(forKey: "body.dob") }
        }
    }
    var biologicalSex: BiologicalSex = .unspecified { didSet { store(biologicalSex.rawValue, "body.sex") } }

    /// Display only. Pounds and inches are converted at the text field.
    var usesMetricBody: Bool = false { didSet { store(usesMetricBody, "body.metric") } }

    var bodyProfile: BodyProfile {
        BodyProfile(massKilograms: bodyMassKilograms,
                    heightCentimetres: bodyHeightCentimetres,
                    dateOfBirth: dateOfBirth,
                    sex: biologicalSex)
    }
```

In `init()`, alongside the existing reads:

```swift
        bodyMassKilograms = d.object(forKey: "body.massKg") as? Double ?? 0
        bodyHeightCentimetres = d.object(forKey: "body.heightCm") as? Double ?? 0
        dateOfBirth = d.object(forKey: "body.dob") as? Date
        biologicalSex = BiologicalSex(rawValue: d.string(forKey: "body.sex") ?? "") ?? .unspecified
        // Metric follows the locale on first launch — a rider who measures in
        // stone is not well served by a default that came from the developer.
        usesMetricBody = d.object(forKey: "body.metric") as? Bool ?? (Locale.current.measurementSystem != .us)
```

In `resetToDefaults()`, add the five keys to whatever list it clears.

- [ ] **Step 2: Wire the manager**

In `HeartRateManager.swift`, add the four properties beside the existing `bridge` / `broadcaster` / `fusion`:

```swift
    let meters = MeterRegistry()
    let workoutStore = WorkoutStore()
    private(set) lazy var central = PowerMeterCentral(registry: meters)
    private(set) lazy var recorder = WorkoutRecorder(store: workoutStore,
                                                     registry: meters,
                                                     central: central,
                                                     workout: phoneWorkout,
                                                     profileProvider: { [settings] in settings.bodyProfile })
```

using the existing `PhoneWorkoutManager` property's real name in place of `phoneWorkout` — find it with `grep -n "PhoneWorkoutManager" HeartRateBroadcaster/Models/HeartRateManager.swift`.

In `init()`, after the existing wiring:

```swift
        // Every meter notification goes to the recorder. Outside a session the
        // recorder ignores them, so nothing here needs to know whether one is
        // running.
        central.onSample = { [weak self] sample in
            self?.recorder.ingest(sample)
        }
```

In `publishFused(at:touchTimestamp:)`, immediately after `currentBPM = fused`:

```swift
        // The recorder sees heart rate only after reconciliation, so it never
        // has to re-litigate which sensor was right.
        recorder.ingest(heartRate: fused, at: date)
```

In the existing one-second timer body (the same one that calls `publishFused(at:touchTimestamp: false)`), add:

```swift
        recorder.tick(now: Date())
```

- [ ] **Step 3: Build and test**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild test -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`, all existing tests still pass.

- [ ] **Step 4: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add HeartRateBroadcaster/Models/AppSettings.swift HeartRateBroadcaster/Models/HeartRateManager.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Give the manager a recorder and the settings a body"
```

---

### Task 14: The body profile screen

A settings screen for the four facts the energy model needs, written so a rider who thinks in pounds and feet never sees a kilogram.

**Files:**
- Create: `HeartRateBroadcaster/Views/BodyProfileView.swift`
- Modify: `HeartRateBroadcaster/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `AppSettings` body properties (Task 13), `BodyProfile`, `BiologicalSex` (Task 5), `Theme`, `Card`, `SectionHeading`, `SettingCard`.
- Produces: `struct BodyProfileView: View` with `init(settings: AppSettings)`.

- [ ] **Step 1: Write the screen**

Create `HeartRateBroadcaster/Views/BodyProfileView.swift`:

```swift
import SwiftUI

/// Weight, height, birth date and sex — the four inputs the energy estimate
/// needs and the only personal data the app holds. Everything stays on the
/// phone; nothing here is transmitted anywhere.
struct BodyProfileView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {
                SectionHeading(String(localized: "profile.section.units",
                                      comment: "Heading above the metric/imperial switch"))
                SettingCard(title: String(localized: "profile.metric.title",
                                          comment: "Toggle label for metric units"),
                            subtitle: String(localized: "profile.metric.subtitle",
                                             comment: "Explains the toggle switches kilograms and centimetres for pounds and feet")) {
                    Toggle("", isOn: $settings.usesMetricBody).labelsHidden()
                }

                SectionHeading(String(localized: "profile.section.body",
                                      comment: "Heading above the weight and height fields"))
                Card {
                    VStack(spacing: Theme.Metric.cardSpacing) {
                        measurementRow(
                            title: String(localized: "profile.weight", comment: "Body weight field label"),
                            value: $settings.bodyMassKilograms,
                            metricSuffix: String(localized: "unit.kg", comment: "Kilogram abbreviation"),
                            imperialSuffix: String(localized: "unit.lb", comment: "Pound abbreviation"),
                            toImperial: { $0 * 2.20462 },
                            toMetric: { $0 / 2.20462 })

                        Divider().overlay(Theme.separator)

                        measurementRow(
                            title: String(localized: "profile.height", comment: "Body height field label"),
                            value: $settings.bodyHeightCentimetres,
                            metricSuffix: String(localized: "unit.cm", comment: "Centimetre abbreviation"),
                            imperialSuffix: String(localized: "unit.in", comment: "Inch abbreviation"),
                            toImperial: { $0 / 2.54 },
                            toMetric: { $0 * 2.54 })
                    }
                }

                SectionHeading(String(localized: "profile.section.about",
                                      comment: "Heading above birth date and sex"))
                Card {
                    VStack(spacing: Theme.Metric.cardSpacing) {
                        DatePicker(String(localized: "profile.birthDate",
                                          comment: "Date of birth field label"),
                                   selection: Binding(get: { settings.dateOfBirth ?? defaultBirthDate },
                                                      set: { settings.dateOfBirth = $0 }),
                                   in: ...Date(),
                                   displayedComponents: .date)
                            .font(Theme.Typeface.sectionTitle)
                            .foregroundStyle(Theme.textPrimary)

                        Divider().overlay(Theme.separator)

                        Picker(String(localized: "profile.sex", comment: "Biological sex field label"),
                               selection: $settings.biologicalSex) {
                            ForEach(BiologicalSex.allCases, id: \.self) { sex in
                                Text(label(for: sex)).tag(sex)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Text(String(localized: "profile.footnote",
                            comment: "Explains the numbers only affect the calorie estimate and never leave the phone"))
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)
            }
            .padding()
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(String(localized: "profile.title", comment: "Title of the body profile screen"))
    }

    /// Roughly a middle-aged rider. Only ever a starting position for the
    /// picker — `dateOfBirth` stays nil until the user actually chooses.
    private var defaultBirthDate: Date {
        Calendar.current.date(byAdding: .year, value: -40, to: Date()) ?? Date()
    }

    private func label(for sex: BiologicalSex) -> String {
        switch sex {
        case .female: String(localized: "profile.sex.female", comment: "Biological sex option")
        case .male: String(localized: "profile.sex.male", comment: "Biological sex option")
        case .unspecified: String(localized: "profile.sex.unspecified", comment: "Biological sex option, no answer given")
        }
    }

    /// One numeric field that stores SI and shows whatever the user reads in.
    /// The conversion lives at the field rather than at the model so that the
    /// energy code never has to ask which unit it was handed.
    @ViewBuilder
    private func measurementRow(title: String,
                                value: Binding<Double>,
                                metricSuffix: String,
                                imperialSuffix: String,
                                toImperial: @escaping (Double) -> Double,
                                toMetric: @escaping (Double) -> Double) -> some View {
        HStack {
            Text(title)
                .font(Theme.Typeface.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            TextField("", value: Binding(
                get: {
                    guard value.wrappedValue > 0 else { return 0 }
                    return settings.usesMetricBody ? value.wrappedValue : toImperial(value.wrappedValue)
                },
                set: { entered in
                    value.wrappedValue = settings.usesMetricBody ? entered : toMetric(entered)
                }), format: .number.precision(.fractionLength(0 ... 1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .foregroundStyle(Theme.textPrimary)
            Text(settings.usesMetricBody ? metricSuffix : imperialSuffix)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, alignment: .leading)
        }
    }
}
```

- [ ] **Step 2: Link it from Settings**

In `SettingsView.swift`, add a row in the same style as the existing navigation rows (find one with `grep -n "NavigationLink" HeartRateBroadcaster/Views/SettingsView.swift` and copy its shape):

```swift
                NavigationLink {
                    BodyProfileView(settings: settings)
                } label: {
                    StatusRow(title: String(localized: "settings.profile.title",
                                            comment: "Row that opens the body profile screen"),
                              detail: settings.bodyProfile.isComplete
                                  ? String(localized: "settings.profile.complete", comment: "Body profile is filled in")
                                  : String(localized: "settings.profile.incomplete", comment: "Body profile still needs values")) {
                        Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary)
                    }
                }
```

Adjust the `StatusRow` argument labels to match its real initialiser.

- [ ] **Step 3: Build and commit**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild build -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
git add HeartRateBroadcaster/Views/BodyProfileView.swift HeartRateBroadcaster/Views/SettingsView.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Ask once for the four numbers the estimate needs"
```

---

### Task 15: The paired meters screen

Scan, connect, choose a primary. The list is live: a meter that goes quiet says so rather than showing its last reading forever.

**Files:**
- Create: `HeartRateBroadcaster/Views/PairedMetersView.swift`

**Interfaces:**
- Consumes: `PowerMeterCentral` (`availability`, `discovered`, `connected`, `latest`, `startScanning()`, `stopScanning()`, `connect(_ id:)`, `disconnect(_ id:)`), `MeterRegistry` (`paired`, `primaryMeterID`, `remember(_:)`, `forget(_:)`, `setPrimary(_:)`), `PairedMeter`, `MeterKind` (Tasks 7-9).
- Produces: `struct PairedMetersView: View` with `init(central: PowerMeterCentral, registry: MeterRegistry)`.

- [ ] **Step 1: Write the screen**

Create `HeartRateBroadcaster/Views/PairedMetersView.swift`:

```swift
import SwiftUI

/// Discovery and pairing for power, cadence and trainer sensors.
///
/// Scanning stops when the screen goes away: a central scanning in the
/// background costs battery for no benefit, and the meters that matter are
/// already remembered by identifier.
struct PairedMetersView: View {
    let central: PowerMeterCentral
    let registry: MeterRegistry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {
                if !registry.paired.isEmpty {
                    SectionHeading(String(localized: "meters.section.paired",
                                          comment: "Heading above already-paired sensors"))
                    Card {
                        VStack(spacing: Theme.Metric.cardSpacing) {
                            ForEach(registry.paired) { meter in
                                pairedRow(meter)
                                if meter.id != registry.paired.last?.id {
                                    Divider().overlay(Theme.separator)
                                }
                            }
                        }
                    }

                    Text(String(localized: "meters.primary.footnote",
                                comment: "Explains that only the primary meter's watts drive the calorie figure because meters measure at different points in the drivetrain"))
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                }

                SectionHeading(String(localized: "meters.section.nearby",
                                      comment: "Heading above sensors found while scanning"))
                Card {
                    if central.discovered.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(String(localized: "meters.scanning",
                                        comment: "Shown while looking for sensors"))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: Theme.Metric.cardSpacing) {
                            ForEach(central.discovered) { found in
                                Button {
                                    registry.remember(found)
                                    central.connect(found.id)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(found.name)
                                                .font(Theme.Typeface.sectionTitle)
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(kindLabel(found.kind))
                                                .font(.caption)
                                                .foregroundStyle(Theme.textTertiary)
                                        }
                                        Spacer()
                                        Text(String(localized: "meters.pair",
                                                    comment: "Button that connects to a discovered sensor"))
                                            .foregroundStyle(Theme.link)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Bluetooth off is the single most common reason this screen
                // stays empty, and it is not something the app can fix silently.
                if central.availability != .ready {
                    Text(String(localized: "meters.bluetoothOff",
                                comment: "Shown when Bluetooth is switched off"))
                        .font(.footnote)
                        .foregroundStyle(Theme.accentAlert)
                        .padding(.horizontal, 4)
                }
            }
            .padding()
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(String(localized: "meters.title", comment: "Title of the sensors screen"))
        .onAppear { central.startScanning() }
        .onDisappear { central.stopScanning() }
    }

    @ViewBuilder
    private func pairedRow(_ meter: PairedMeter) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(meter.name)
                    .font(Theme.Typeface.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text(statusLine(meter))
                    .font(.caption)
                    .foregroundStyle(central.connected.contains(meter.id) ? Theme.textSecondary : Theme.textTertiary)
            }
            Spacer()
            if meter.kind.measuresPower {
                Button {
                    registry.setPrimary(meter.id)
                } label: {
                    Image(systemName: registry.primaryMeterID == meter.id ? "star.fill" : "star")
                        .foregroundStyle(registry.primaryMeterID == meter.id ? Theme.accentActive : Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "meters.makePrimary",
                                           comment: "Accessibility label for the button that chooses the primary power meter"))
            }
            Button {
                registry.forget(meter.id)
                central.disconnect(meter.id)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(Theme.accentAlert)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "meters.forget",
                                       comment: "Accessibility label for the button that removes a paired sensor"))
        }
    }

    /// Live status is read from the central rather than stored on the meter,
    /// so `PairedMeter` stays a plain persisted value with nothing in it that
    /// goes stale on disk.
    private func statusLine(_ meter: PairedMeter) -> String {
        guard central.connected.contains(meter.id) else {
            return String(localized: "meters.status.disconnected", comment: "Sensor is not currently connected")
        }
        if let watts = central.latest[meter.id]?.watts {
            return String(localized: "meters.status.watts \(watts)",
                          comment: "Live reading from a connected power meter, in watts")
        }
        return String(localized: "meters.status.connected", comment: "Sensor is connected but has not reported yet")
    }

    private func kindLabel(_ kind: MeterKind) -> String {
        switch kind {
        case .cyclingPower: String(localized: "meters.kind.power", comment: "Cycling power meter")
        case .speedCadence: String(localized: "meters.kind.cadence", comment: "Speed and cadence sensor")
        case .fitnessMachine: String(localized: "meters.kind.trainer", comment: "Indoor trainer")
        }
    }
}
```

- [ ] **Step 2: Build and commit**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild build -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
git add HeartRateBroadcaster/Views/PairedMetersView.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Find the meters on the bike and let one of them be the one that counts"
```

---

### Task 16: The session control and summary

The card on the main screen that starts and stops a ride, and the sheet that appears when one ends.

**Files:**
- Create: `HeartRateBroadcaster/Views/SessionControlCard.swift`, `HeartRateBroadcaster/Views/SessionSummaryView.swift`
- Modify: `HeartRateBroadcaster/Views/ContentView.swift`

**Interfaces:**
- Consumes: `WorkoutRecorder`, `WorkoutRecord`, `WorkoutSport`, `MeterRegistry`.
- Produces: `struct SessionControlCard: View`, `struct SessionSummaryView: View` with `init(record: WorkoutRecord)`.

- [ ] **Step 1: The control card**

Create `HeartRateBroadcaster/Views/SessionControlCard.swift`:

```swift
import SwiftUI

/// Start, stop, and what the ride looks like while it runs.
///
/// The sport is chosen before Start and cannot change afterwards, because
/// HealthKit fixes the activity type when the session is created and there is
/// only one session available on the device.
struct SessionControlCard: View {
    let recorder: WorkoutRecorder
    let registry: MeterRegistry
    @Binding var chosenSport: WorkoutSport
    var onFinished: (WorkoutRecord) -> Void

    @State private var isBusy = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Metric.cardSpacing) {
                if recorder.state.isLive {
                    liveReadout
                } else {
                    Picker(String(localized: "session.sport", comment: "Label for the sport picker"),
                           selection: $chosenSport) {
                        ForEach(WorkoutSport.allCases, id: \.self) { sport in
                            Text(sportLabel(sport)).tag(sport)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isBusy)
                }

                Button {
                    Task { await toggle() }
                } label: {
                    Text(recorder.state.isLive
                         ? String(localized: "session.stop", comment: "Ends the workout")
                         : String(localized: "session.start", comment: "Begins the workout"))
                        .font(Theme.Typeface.sectionTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(recorder.state.isLive ? Theme.accentAlert : Theme.accentActive)
                        .foregroundStyle(Theme.Palette.pureWhite)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
        .onAppear {
            // A power meter on the bike says what this session is better than
            // whatever was picked last week.
            if !recorder.state.isLive, registry.hasPowerCapableMeter {
                chosenSport = .cycling
            }
        }
    }

    @ViewBuilder
    private var liveReadout: some View {
        HStack(alignment: .firstTextBaseline) {
            metric(value: Self.clock.string(from: recorder.elapsed) ?? "0:00",
                   label: String(localized: "session.elapsed", comment: "Elapsed workout time"))
            Spacer()
            metric(value: recorder.currentWatts.map { "\($0)" } ?? "—",
                   label: String(localized: "session.watts", comment: "Current power in watts"))
            Spacer()
            metric(value: "\(Int(recorder.runningKilocalories.rounded()))",
                   label: String(localized: "session.kcal", comment: "Energy burned so far in kilocalories"))
        }

        if recorder.energySource == .heartRate {
            Text(String(localized: "session.estimatedFromHeartRate",
                        comment: "Notes the calorie figure currently comes from heart rate rather than measured power"))
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private static let clock: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .positional
        f.zeroFormattingBehavior = .pad
        return f
    }()

    @ViewBuilder
    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func toggle() async {
        isBusy = true
        defer { isBusy = false }
        if recorder.state.isLive {
            if let record = await recorder.end() { onFinished(record) }
        } else {
            await recorder.begin(sport: chosenSport)
        }
    }

    private func sportLabel(_ sport: WorkoutSport) -> String {
        switch sport {
        case .cycling: String(localized: "sport.cycling", comment: "Workout type")
        case .running: String(localized: "sport.running", comment: "Workout type")
        case .swimming: String(localized: "sport.swimming", comment: "Workout type")
        }
    }
}
```

- [ ] **Step 2: The summary sheet**

Create `HeartRateBroadcaster/Views/SessionSummaryView.swift`:

```swift
import SwiftUI

/// What the ride came to. Shown once when a session ends and again from
/// history.
///
/// Gaps and an incomplete body profile are stated in words rather than hidden,
/// because a calorie figure the user cannot audit is worse than one with a
/// caveat attached.
struct SessionSummaryView: View {
    let record: WorkoutRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(Int(record.activeKilocalories.rounded()))")
                            .font(.system(size: 56, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Text(String(localized: "summary.activeKcal",
                                    comment: "Label under the large calorie number, meaning energy above resting"))
                            .foregroundStyle(Theme.textSecondary)
                        Text(String(localized: "summary.totalKcal \(Int(record.totalKilocalories.rounded()))",
                                    comment: "Total energy including resting metabolism"))
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                Card {
                    VStack(spacing: Theme.Metric.cardSpacing) {
                        row(String(localized: "summary.duration", comment: "Row label"),
                            Self.clock.string(from: record.recordedDuration) ?? "—")
                        row(String(localized: "summary.sport", comment: "Row label"), sportLabel)
                        if let watts = record.averagePower {
                            row(String(localized: "summary.averagePower", comment: "Row label"),
                                String(localized: "value.watts \(Int(watts.rounded()))", comment: "A power value in watts"))
                        }
                        if let peak = record.maximumPower {
                            row(String(localized: "summary.maximumPower", comment: "Row label"),
                                String(localized: "value.watts \(peak)", comment: "A power value in watts"))
                        }
                        if let bpm = record.averageHeartRate {
                            row(String(localized: "summary.averageHeartRate", comment: "Row label"),
                                String(localized: "value.bpm \(bpm)", comment: "A heart rate value in beats per minute"))
                        }
                        if let cadence = record.averageCadence {
                            row(String(localized: "summary.averageCadence", comment: "Row label"),
                                String(localized: "value.rpm \(Int(cadence.rounded()))", comment: "A cadence value in revolutions per minute"))
                        }
                        if record.totalKilojoules > 0 {
                            row(String(localized: "summary.work", comment: "Row label for mechanical work done"),
                                String(localized: "value.kj \(Int(record.totalKilojoules.rounded()))", comment: "Mechanical work in kilojoules"))
                        }
                    }
                }

                if record.meterTotals.count > 1 {
                    SectionHeading(String(localized: "summary.section.meters",
                                          comment: "Heading above the per-sensor breakdown"))
                    Card {
                        VStack(spacing: Theme.Metric.cardSpacing) {
                            ForEach(record.meterTotals, id: \.meterID) { totals in
                                row(totals.meterName + (totals.meterID == record.primaryMeterID
                                                        ? " " + String(localized: "summary.primaryTag", comment: "Marks which sensor drove the numbers")
                                                        : ""),
                                    String(localized: "value.watts \(Int(totals.averageWatts.rounded()))", comment: "A power value in watts"))
                            }
                        }
                    }
                    Text(String(localized: "summary.meters.footnote",
                                comment: "Explains sensors disagree because they measure at different points in the drivetrain, not because one is wrong"))
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                }

                if !record.gaps.isEmpty {
                    Text(String(localized: "summary.gaps \(record.gaps.count) \(Int(record.gapDuration.rounded()))",
                                comment: "Notes how many signal dropouts happened and how many seconds were excluded"))
                        .font(.footnote)
                        .foregroundStyle(Theme.accentAlert)
                        .padding(.horizontal, 4)
                }

                if !record.profileWasComplete {
                    Text(String(localized: "summary.profileIncomplete",
                                comment: "Warns the calorie figure is rough because weight, height, age or sex are missing"))
                        .font(.footnote)
                        .foregroundStyle(Theme.accentAlert)
                        .padding(.horizontal, 4)
                }

                if record.savedToHealth {
                    Text(String(localized: "summary.savedToHealth",
                                comment: "Confirms the workout was written to the Health app"))
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                }
            }
            .padding()
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(record.start.formatted(date: .abbreviated, time: .shortened))
    }

    private static let clock: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .positional
        f.zeroFormattingBehavior = .pad
        return f
    }()

    private var sportLabel: String {
        switch record.sport {
        case .cycling: String(localized: "sport.cycling", comment: "Workout type")
        case .running: String(localized: "sport.running", comment: "Workout type")
        case .swimming: String(localized: "sport.swimming", comment: "Workout type")
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).foregroundStyle(Theme.textPrimary).monospacedDigit()
        }
    }
}
```

- [ ] **Step 3: Put the card on the main screen**

In `ContentView.swift`, add state and the card. Place the card directly below the existing heart rate display card:

```swift
    @State private var chosenSport: WorkoutSport = .cycling
    @State private var finishedRecord: WorkoutRecord?
```

```swift
                SessionControlCard(recorder: manager.recorder,
                                   registry: manager.meters,
                                   chosenSport: $chosenSport,
                                   onFinished: { finishedRecord = $0 })
```

and on the same container:

```swift
        .sheet(item: $finishedRecord) { record in
            NavigationStack { SessionSummaryView(record: record) }
        }
```

`WorkoutRecord` already conforms to `Identifiable` via its `id` (Task 7), which `sheet(item:)` requires. Use the existing manager property name in place of `manager`.

- [ ] **Step 4: Build and commit**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild build -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -15
git add HeartRateBroadcaster/Views/SessionControlCard.swift HeartRateBroadcaster/Views/SessionSummaryView.swift HeartRateBroadcaster/Views/ContentView.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Start a ride, watch it, and see what it came to"
```

---

### Task 17: History

**Files:**
- Create: `HeartRateBroadcaster/Views/WorkoutHistoryView.swift`
- Modify: `HeartRateBroadcaster/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `WorkoutStore`, `WorkoutRecord`, `SessionSummaryView`.
- Produces: `struct WorkoutHistoryView: View` with `init(store: WorkoutStore)`.

- [ ] **Step 1: Write it**

Create `HeartRateBroadcaster/Views/WorkoutHistoryView.swift`:

```swift
import SwiftUI

/// Every saved session, newest first. Deleting removes the app's copy; a
/// workout already written to Health stays there, which is the behaviour
/// people expect from anything that writes to Health.
struct WorkoutHistoryView: View {
    let store: WorkoutStore

    var body: some View {
        List {
            if store.records.isEmpty {
                Text(String(localized: "history.empty",
                            comment: "Shown when no workouts have been recorded yet"))
                    .foregroundStyle(Theme.textTertiary)
                    .listRowBackground(Theme.surface)
            }
            ForEach(store.records) { record in
                NavigationLink {
                    SessionSummaryView(record: record)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.start.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(Theme.textPrimary)
                            Text(Self.clock.string(from: record.recordedDuration) ?? "")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Text(String(localized: "value.kcal \(Int(record.activeKilocalories.rounded()))",
                                    comment: "An energy value in kilocalories"))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .onDelete { offsets in
                offsets.map { store.records[$0].id }.forEach(store.delete)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(String(localized: "history.title", comment: "Title of the workout history screen"))
    }

    private static let clock: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f
    }()
}
```

- [ ] **Step 2: Link it and the meters screen from Settings**

Add two more `NavigationLink` rows in `SettingsView.swift` beside the profile row from Task 14:

```swift
                NavigationLink { PairedMetersView(central: manager.central, registry: manager.meters) } label: {
                    Text(String(localized: "settings.meters.title", comment: "Row that opens the sensors screen"))
                }
                NavigationLink { WorkoutHistoryView(store: manager.workoutStore) } label: {
                    Text(String(localized: "settings.history.title", comment: "Row that opens the workout history"))
                }
```

matching the surrounding rows' styling.

- [ ] **Step 3: Build and commit**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild build -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
git add HeartRateBroadcaster/Views/WorkoutHistoryView.swift HeartRateBroadcaster/Views/SettingsView.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Keep the rides where they can be looked at again"
```

---

### Task 18: Telling the watch what sport this is

The phone already sends an application context to the watch. The sport rides along in it, so a swim gets water lock and a run gets the right activity type in the watch's own workout session.

**Files:**
- Modify: `Shared/WCPayload.swift`, `HeartRateBroadcasterWatch/Models/WorkoutManager.swift`, `HeartRateBroadcaster/Models/HeartRateManager.swift`

**Interfaces:**
- Produces: `WCKey.sport` (String, raw value of `WorkoutSport`), `WCKey.sessionActive` (Bool).
- Produces on the watch `WorkoutManager`: `func start(sport: String?) async` replacing the existing no-argument `start()`.

- [ ] **Step 1: Add the keys**

In `Shared/WCPayload.swift`, add to the `WCKey` enum, matching the existing case style:

```swift
    /// Raw value of `WorkoutSport`. Absent means the phone is not recording and
    /// the watch should use its own default.
    case sport
    /// Whether a recorded session — not just heart rate bridging — is running.
    case sessionActive
```

- [ ] **Step 2: Send them**

In `HeartRateManager.swift`, find the method that builds the application context dictionary (`grep -n "updateApplicationContext\|WCKey\." HeartRateBroadcaster/Models/HeartRateManager.swift`) and add:

```swift
        context[WCKey.sessionActive.rawValue] = recorder.state.isLive
        if recorder.state.isLive {
            context[WCKey.sport.rawValue] = recorder.sport.rawValue
        }
```

Then call the same update method from the recorder's transitions by adding, at the end of `WorkoutRecorder.begin(sport:)` and `WorkoutRecorder.end()`, a call to a new closure property:

```swift
    /// Fired when a session starts or stops so the phone can tell the watch
    /// which sport it is now recording. A closure rather than a reference back
    /// to the manager, so the recorder stays testable without WatchConnectivity.
    var onSessionStateChanged: () -> Void = {}
```

with `onSessionStateChanged()` as the last line of both, and in `HeartRateManager.init()`:

```swift
        recorder.onSessionStateChanged = { [weak self] in self?.pushContextToWatch() }
```

using the real name of the existing context-push method.

- [ ] **Step 3: Receive them on the watch**

In `HeartRateBroadcasterWatch/Models/WorkoutManager.swift`, change the start signature and the two hardcoded lines at 97 and 100:

```swift
    func start(sport: String? = nil) async {
```

```swift
        // The phone owns the sport. Matching it here is what gives a swim its
        // water lock and a run the right activity type in Health.
        let chosen = sport.flatMap(WorkoutSport.init(rawValue:)) ?? .cycling
        configuration.activityType = chosen.activityType
        configuration.locationType = chosen.locationType
```

Both `activityType` and `locationType` come from the `WorkoutSport` extension added in Task 10; move that extension into `Shared/WorkoutRecord.swift` — guarded so it compiles on both platforms — if it is currently in an app-target file:

```swift
#if canImport(HealthKit)
import HealthKit

extension WorkoutSport {
    var activityType: HKWorkoutActivityType {
        switch self {
        case .cycling: .cycling
        case .running: .running
        case .swimming: .swimming
        }
    }

    /// Indoor for cycling because the common case is a trainer, and an outdoor
    /// ride is corrected by Health from the route rather than guessed here.
    var locationType: HKWorkoutSessionLocationType {
        switch self {
        case .cycling: .indoor
        case .running: .outdoor
        case .swimming: .indoor
        }
    }
}
#endif
```

Then find the watch-side receiver that reads the application context (`grep -n "didReceiveApplicationContext" HeartRateBroadcasterWatch/Models/*.swift`) and pass the sport through to `start(sport:)`.

- [ ] **Step 4: Build both targets**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild build -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -15
```

Expected: `BUILD SUCCEEDED` — the watch target builds as a dependency of the iOS scheme.

- [ ] **Step 5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add Shared/WCPayload.swift Shared/WorkoutRecord.swift HeartRateBroadcasterWatch/Models/WorkoutManager.swift HeartRateBroadcaster/Models/HeartRateManager.swift
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Let the watch know which sport the phone is recording"
```

---

### Task 19: The strings

Every `String(localized:)` key added in Tasks 14-18 needs an entry in the catalogue, and the widened Bluetooth purpose string needs one in the Info.plist catalogue. English is authored; the other 24 languages are marked as needing translation rather than filled with English text pretending to be a translation.

**Files:**
- Modify: `HeartRateBroadcaster/Resources/Localizable.xcstrings`, `HeartRateBroadcaster/Resources/InfoPlist.xcstrings`

Confirm the real paths first: `find . -name "*.xcstrings" -not -path "*/build/*"`.

- [ ] **Step 1: Collect the keys**

```bash
cd "$(git rev-parse --show-toplevel)"
grep -rho 'String(localized: "[^"]*"' HeartRateBroadcaster/Views HeartRateBroadcaster/Models Shared \
  | sed 's/String(localized: "//; s/"$//' | sort -u
```

This is the authoritative list. Every key it prints must exist in `Localizable.xcstrings`.

- [ ] **Step 2: Add them**

Xcode adds new keys to the catalogue automatically on build, but only for keys it can see statically. Build the iOS target once, then open the catalogue and confirm the count. If keys are missing, add them by hand in the catalogue's JSON with the English value and no other languages — the same shape the existing entries use for a string that has an English source and untranslated variants.

English values to author (the key is on the left; the value on the right is what the user reads):

| Key | English |
|---|---|
| `profile.title` | Body |
| `profile.section.units` | Units |
| `profile.metric.title` | Metric |
| `profile.metric.subtitle` | Kilograms and centimetres instead of pounds and feet. |
| `profile.section.body` | Measurements |
| `profile.weight` | Weight |
| `profile.height` | Height |
| `profile.section.about` | About you |
| `profile.birthDate` | Date of birth |
| `profile.sex` | Sex |
| `profile.sex.female` | Female |
| `profile.sex.male` | Male |
| `profile.sex.unspecified` | Prefer not to say |
| `profile.footnote` | These figures are used only to estimate energy burned. They stay on this phone. |
| `unit.kg` | kg |
| `unit.lb` | lb |
| `unit.cm` | cm |
| `unit.in` | in |
| `settings.profile.title` | Body |
| `settings.profile.complete` | Set |
| `settings.profile.incomplete` | Not set |
| `settings.meters.title` | Sensors |
| `settings.history.title` | Workouts |
| `meters.title` | Sensors |
| `meters.section.paired` | Paired |
| `meters.section.nearby` | Nearby |
| `meters.scanning` | Looking for sensors… |
| `meters.pair` | Pair |
| `meters.makePrimary` | Use for calories |
| `meters.forget` | Forget |
| `meters.primary.footnote` | The starred meter's watts drive the energy figure. Meters on different parts of the drivetrain read differently — that is the drivetrain, not an error. |
| `meters.bluetoothOff` | Bluetooth is off. Turn it on to find sensors. |
| `meters.status.connected` | Connected |
| `meters.status.disconnected` | Not connected |
| `meters.status.watts` | %lld W |
| `meters.kind.power` | Power meter |
| `meters.kind.cadence` | Speed and cadence |
| `meters.kind.trainer` | Trainer |
| `session.sport` | Sport |
| `session.start` | Start workout |
| `session.stop` | Stop workout |
| `session.elapsed` | Time |
| `session.watts` | Watts |
| `session.kcal` | Calories |
| `session.estimatedFromHeartRate` | Estimated from heart rate — no power meter reporting. |
| `sport.cycling` | Cycle |
| `sport.running` | Run |
| `sport.swimming` | Swim |
| `summary.activeKcal` | Active calories |
| `summary.totalKcal` | %lld total, including resting |
| `summary.duration` | Duration |
| `summary.sport` | Sport |
| `summary.averagePower` | Average power |
| `summary.maximumPower` | Peak power |
| `summary.averageHeartRate` | Average heart rate |
| `summary.averageCadence` | Average cadence |
| `summary.work` | Work |
| `summary.section.meters` | Sensors |
| `summary.primaryTag` | (counted) |
| `summary.meters.footnote` | Sensors read differently because they measure at different points in the drivetrain. |
| `summary.gaps` | %lld dropouts, %lld seconds excluded |
| `summary.profileIncomplete` | Rough estimate — fill in your body details for a better figure. |
| `summary.savedToHealth` | Saved to Health. |
| `value.watts` | %lld W |
| `value.bpm` | %lld bpm |
| `value.rpm` | %lld rpm |
| `value.kj` | %lld kJ |
| `value.kcal` | %lld kcal |
| `history.title` | Workouts |
| `history.empty` | No workouts yet. |

- [ ] **Step 3: Widen the Bluetooth purpose string**

The existing `NSBluetoothAlwaysUsageDescription` claims only that the app advertises. It now also connects to sensors, and a purpose string that does not describe what the app actually does is a review rejection. In `project.yml` and in `InfoPlist.xcstrings`, set the English value to:

> Broadcasts your heart rate to gym equipment and connects to power meters and cadence sensors on your bike.

- [ ] **Step 4: Build and check for missing keys**

```bash
cd "$(git rev-parse --show-toplevel)" && xcodegen generate && \
xcodebuild build -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -i "localiz\|xcstrings" | head -20
```

Expected: no warnings about keys missing from the catalogue.

- [ ] **Step 5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add HeartRateBroadcaster/Resources/Localizable.xcstrings HeartRateBroadcaster/Resources/InfoPlist.xcstrings project.yml
GIT_COMMITTER_NAME="tankbottoms" GIT_COMMITTER_EMAIL="tankbottoms@users.noreply.github.com" \
  git commit --author="tankbottoms <tankbottoms@users.noreply.github.com>" \
  -m "Say what the app does before asking for the radio"
```

---

### Task 20: Onto the phone

Full test run, then a device build and install onto the paired iPhone.

**Files:** none.

- [ ] **Step 1: Run every test**

```bash
cd "$(git rev-parse --show-toplevel)" && \
xcodebuild test -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -30
```

Expected: `TEST SUCCEEDED`, with the 59 new tests from Tasks 1-7 among them. If the simulator refuses to launch, the recovery is: wait, then `killall -9 com.apple.CoreSimulator.CoreSimulatorService`, then `xcrun simctl erase` the device — in that order.

- [ ] **Step 2: Confirm the device is there**

```bash
xcrun devicectl list devices 2>&1 | grep -i orange
```

Expected: `iPhone 17 Pro Max Orange`, identifier `06A0A98A-72FD-5A20-B13C-F8BD32FC55F0`, state `available (paired)`. If it is not listed, the phone is locked or unplugged, and nothing further will work until it is.

- [ ] **Step 3: Build for the device**

```bash
cd "$(git rev-parse --show-toplevel)" && \
xcodebuild build -project HeartRateBroadcaster.xcodeproj -scheme HeartRateBroadcaster \
  -destination 'id=06A0A98A-72FD-5A20-B13C-F8BD32FC55F0' \
  -derivedDataPath build/device 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. Signing comes from `signing.xcconfig`, which is gitignored and must already be present; if the build fails on provisioning, that file is the first thing to check.

- [ ] **Step 4: Install**

```bash
xcrun devicectl device install app \
  --device 06A0A98A-72FD-5A20-B13C-F8BD32FC55F0 \
  build/device/Build/Products/Debug-iphoneos/HeartRateBroadcaster.app 2>&1 | tail -10
```

Expected: an `installedApplications` entry naming the bundle identifier.

- [ ] **Step 5: What to check on the bike**

Not automatable — this is the list for the rider:

1. Settings → Body: enter weight, height, birth date, sex.
2. Settings → Sensors: the P1 pedals, the SRAM crank and the Kickr should all appear while the scan runs. Pair all three. Star one.
3. Main screen: sport should already read Cycle. Press Start.
4. Pedal. Watts should move, calories should climb, and the "estimated from heart rate" line should be absent.
5. Stop pedalling without dismounting. Watts should read 0 and calories should still creep — a coast is not a dropout.
6. Walk the phone out of range of the meters for ten seconds. On return, the summary should report a dropout and the excluded seconds.
7. Press Stop. The summary should show all three meters with different average watts and the starred one marked as counted.
8. Open Health. The workout should be there, with active calories below the total shown in the summary.
9. Check the watch: it should have started a Cycle workout of its own when the phone did.

- [ ] **Step 6: Commit anything the device build changed**

```bash
cd "$(git rev-parse --show-toplevel)" && git status --short
```

Expected: clean, or only `build/` which is gitignored. If `HeartRateBroadcaster.xcodeproj` shows as modified, it should not be tracked — confirm `.gitignore` covers it before doing anything else.

---

## Notes on order

Tasks 1-7 are pure units with tests and no dependencies on each other beyond `ByteCursor` (Task 1) and `BodyProfile` (Task 5); they can be done in any order after Task 1. Tasks 8-13 build the machinery and must be done in sequence. Tasks 14-17 are views and can be done in parallel once Task 13 lands. Task 18 depends on Task 10's `WorkoutSport` extension. Tasks 19 and 20 come last.
