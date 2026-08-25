import Foundation
import Observation
import WatchConnectivity

/// User-facing settings, persisted to `UserDefaults` on every write.
@Observable
@MainActor
final class AppSettings {

    enum PushFrequency: String, CaseIterable, Identifiable {
        case auto, fixed
        var id: String { rawValue }
        var label: String {
            self == .auto
                ? String(localized: "Auto", comment: "Push rate that follows the sensor")
                : String(localized: "Fixed", comment: "Push rate held at a constant interval")
        }
    }

    enum Source: String, CaseIterable, Identifiable {
        case watch, airPods, fused, testSignal
        var id: String { rawValue }

        var label: String {
            switch self {
            case .watch:      return "Apple Watch"
            case .airPods:    return "AirPods Pro"
            case .fused:      return String(localized: "Watch + AirPods", comment: "Heart rate source that reconciles both sensors")
            case .testSignal: return String(localized: "Test Signal", comment: "Heart rate source that generates a synthetic reading on the phone")
            }
        }

        /// The picker segments. "Watch" and "AirPods" are the product names and
        /// stay put; the other two are ordinary words and have to travel.
        var shortLabel: String {
            switch self {
            case .watch:      return "Watch"
            case .airPods:    return "AirPods"
            case .fused:      return String(localized: "Both", comment: "Picker segment: use the watch and AirPods together")
            case .testSignal: return String(localized: "Test", comment: "Picker segment: synthetic heart rate generated on the phone")
            }
        }

        var usesWatch: Bool { self == .watch || self == .fused }
        var usesAirPods: Bool { self == .airPods || self == .fused }

        /// An iPad cannot pair an Apple Watch, so the two watch-bearing options
        /// are not merely unlikely there — they are unreachable, and offering
        /// them produces a screen that reports "not available on this device"
        /// and never shows a heart rate.
        static var available: [Source] {
            WCSession.isSupported() ? allCases : allCases.filter { !$0.usesWatch }
        }
    }

    static let defaultName = "HRB"

    var bridgeEnabled: Bool  { didSet { store(bridgeEnabled, "bridgeEnabled") } }
    var advertisedName: String { didSet { store(advertisedName, "advertisedName") } }
    var pushFrequency: PushFrequency { didSet { store(pushFrequency.rawValue, "pushFrequency") } }
    var fixedInterval: Double { didSet { store(fixedInterval, "fixedInterval") } }
    var source: Source { didSet { store(source.rawValue, "source") } }
    var screenAlwaysOn: Bool { didSet { store(screenAlwaysOn, "screenAlwaysOn") } }
    var autoStartWatchApp: Bool { didSet { store(autoStartWatchApp, "autoStartWatchApp") } }
    var dynamicIsland: Bool { didSet { store(dynamicIsland, "dynamicIsland") } }
    var pictureInPicture: Bool { didSet { store(pictureInPicture, "pictureInPicture") } }
    var watchAntiMistouch: Bool { didSet { store(watchAntiMistouch, "watchAntiMistouch") } }

    /// Offer this phone to cycling apps on the same network as a virtual
    /// shifter. Off by default: it opens a local network listener, and nothing
    /// that touches the network should switch itself on.
    var bikeControlEnabled: Bool { didSet { store(bikeControlEnabled, "bikeControl.enabled") } }
    /// How many virtual gears the game is set up for. Only bounds the counter
    /// on this screen — the game does the real clamping.
    var bikeControlGearCount: Int { didSet { store(bikeControlGearCount, "bikeControl.gearCount") } }
    /// Where the counter was when the app last closed, so a ride resumed after
    /// a phone call does not silently restart in the middle of the cassette.
    ///
    /// The first-run value is ``defaultGear`` rather than the middle of the
    /// range, because a game that opens in 15 and a phone that opens in 12 are
    /// three shifts apart with no way to notice.
    var bikeControlGear: Int { didSet { store(bikeControlGear, "bikeControl.gear") } }

    /// The gear a session starts in. MyWhoosh opens every session here, and
    /// since nothing in the protocol reports the game's gear back, starting in
    /// the same place is the whole of how the two sides agree.
    static let defaultGear = 15

    /// Whether a finished ride is written into Apple Health at all.
    ///
    /// On by default, because a workout the rider pressed Start on is a workout
    /// they expect to find. Off is for the rider whose ride is already coming
    /// back the long way round — this app to MyWhoosh, MyWhoosh to Strava as a
    /// FIT with the route on it, Strava into Health — where saving it here as
    /// well puts the same hour in twice.
    var savesWorkoutsToHealth: Bool { didSet { store(savesWorkoutsToHealth, "health.savesWorkouts") } }
    /// Whether the calorie figure goes onto that workout. Separate because it is
    /// the one number this app computes rather than measures, and a rider who
    /// trusts their trainer's figure over ours should be able to leave it out
    /// without giving up the workout.
    var savesEnergyToHealth: Bool { didSet { store(savesEnergyToHealth, "health.savesEnergy") } }

    /// `nil` follows the device. Stored as an absent key rather than as an empty
    /// string so that "never chosen" and "chose the device language" are the
    /// same state — there is no reason to distinguish them and one fewer way for
    /// them to disagree.
    var preferredLanguage: String? {
        didSet {
            if let preferredLanguage { store(preferredLanguage, "preferredLanguage") }
            else { defaults.removeObject(forKey: "preferredLanguage") }
        }
    }

    /// Held in SI whatever the field shows, so the energy model never has to ask
    /// which unit it was handed. Zero means "not answered" — a rider with a mass
    /// of zero is not a case worth distinguishing from an empty field.
    var bodyMassKilograms: Double { didSet { store(bodyMassKilograms, "body.massKg") } }
    var bodyHeightCentimetres: Double { didSet { store(bodyHeightCentimetres, "body.heightCm") } }
    var biologicalSex: BiologicalSex { didSet { store(biologicalSex.rawValue, "body.sex") } }

    /// Display only. Pounds and inches are converted at the text field.
    var usesMetricBody: Bool { didSet { store(usesMetricBody, "body.metric") } }

    /// `store(_:_:)` takes a non-optional `Any`; a nil date has to clear the key
    /// rather than write an optional into defaults.
    var dateOfBirth: Date? {
        didSet {
            if let dateOfBirth { defaults.set(dateOfBirth, forKey: "body.dob") }
            else { defaults.removeObject(forKey: "body.dob") }
        }
    }

    var bodyProfile: BodyProfile {
        BodyProfile(massKilograms: bodyMassKilograms,
                    heightCentimetres: bodyHeightCentimetres,
                    dateOfBirth: dateOfBirth,
                    sex: biologicalSex)
    }

    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        bridgeEnabled    = d.object(forKey: "bridgeEnabled") as? Bool ?? true
        // The old default was "HR Bcast". Migrate anyone still carrying it so
        // the sensor list shows the new name without a manual reset.
        let storedName   = d.string(forKey: "advertisedName")
        advertisedName   = (storedName == nil || storedName == "HR Bcast") ? Self.defaultName : storedName!
        pushFrequency    = PushFrequency(rawValue: d.string(forKey: "pushFrequency") ?? "") ?? .auto
        fixedInterval    = d.object(forKey: "fixedInterval") as? Double ?? 1.0
        // Default to the watch on iPhone, AirPods everywhere else — an iPad
        // has no watch to read, and defaulting it to one is what made the app
        // open to a dead screen there. A stored watch source is coerced too,
        // in case settings arrive from iCloud or a restore.
        let storedSource = Source(rawValue: d.string(forKey: "source") ?? "")
        if WCSession.isSupported() {
            source = storedSource ?? .watch
        } else if let stored = storedSource, !stored.usesWatch {
            source = stored
        } else {
            source = .airPods
        }
        screenAlwaysOn   = d.object(forKey: "screenAlwaysOn") as? Bool ?? true
        autoStartWatchApp = d.object(forKey: "autoStartWatchApp") as? Bool ?? false
        dynamicIsland    = d.object(forKey: "dynamicIsland") as? Bool ?? true
        pictureInPicture = d.object(forKey: "pictureInPicture") as? Bool ?? false
        watchAntiMistouch = d.object(forKey: "watchAntiMistouch") as? Bool ?? false
        bikeControlEnabled = d.object(forKey: "bikeControl.enabled") as? Bool ?? false
        // 24 is the usual virtual range and it is only a ceiling; a rider whose
        // game offers fewer will simply never reach the top of this one.
        bikeControlGearCount = d.object(forKey: "bikeControl.gearCount") as? Int ?? 24
        bikeControlGear = d.object(forKey: "bikeControl.gear") as? Int ?? Self.defaultGear
        savesWorkoutsToHealth = d.object(forKey: "health.savesWorkouts") as? Bool ?? true
        savesEnergyToHealth = d.object(forKey: "health.savesEnergy") as? Bool ?? true
        preferredLanguage = d.string(forKey: "preferredLanguage")
        // Zero reads as "not answered yet", which is what an absent key means.
        bodyMassKilograms = d.object(forKey: "body.massKg") as? Double ?? 0
        bodyHeightCentimetres = d.object(forKey: "body.heightCm") as? Double ?? 0
        biologicalSex = BiologicalSex(rawValue: d.string(forKey: "body.sex") ?? "") ?? .unspecified
        usesMetricBody = d.object(forKey: "body.metric") as? Bool ?? !Self.usesImperialLocale
        dateOfBirth = d.object(forKey: "body.dob") as? Date
        d.set(advertisedName, forKey: "advertisedName")
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    func resetToDefaults() {
        bridgeEnabled = true
        advertisedName = Self.defaultName
        pushFrequency = .auto
        fixedInterval = 1.0
        source = WCSession.isSupported() ? .watch : .airPods
        screenAlwaysOn = true
        autoStartWatchApp = false
        dynamicIsland = true
        pictureInPicture = false
        watchAntiMistouch = false
        bikeControlEnabled = false
        bikeControlGearCount = 24
        bikeControlGear = Self.defaultGear
        savesWorkoutsToHealth = true
        savesEnergyToHealth = true
        preferredLanguage = nil
        bodyMassKilograms = 0
        bodyHeightCentimetres = 0
        biologicalSex = .unspecified
        usesMetricBody = !Self.usesImperialLocale
        dateOfBirth = nil
    }

    /// Only three countries measure a person in pounds; everyone else should not
    /// have to change a switch before typing their weight.
    private static var usesImperialLocale: Bool {
        Locale.current.measurementSystem == .us
    }
}
