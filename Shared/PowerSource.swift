import Foundation

/// Which end of the axle a pedal meter is on.
enum PedalSide: String, Codable, Sendable {
    case left
    case right
}

/// One thing on the bike whose watts can be believed.
///
/// Usually a source is a meter, one for one. The exception is a pair of pedal
/// meters, which is a source made of two: a left PowerTap P1 reads the work
/// done by the left leg and the right one reads the right, so each shows
/// roughly half the load and neither is comparable with a trainer on its own.
/// Read as a pair and added together they are — the screenshots that prompted
/// this had 30 W and 20 W at the pedals against 52 W at the KICKR, which is one
/// rider putting out fifty-odd watts and not three meters disagreeing.
///
/// Grouping is by name, because nothing in the Bluetooth cycling power service
/// says which foot a meter is under. That is a heuristic, and it is deliberately
/// a narrow one: same base name, opposite side markers, both reporting power.
struct PowerSource: Identifiable, Equatable, Sendable {

    enum Shape: Equatable, Sendable {
        case single
        /// Held as an ordered pair rather than a set so the display name and the
        /// identity of the source do not shuffle between launches.
        case pedalPair(left: UUID, right: UUID)
    }

    /// A single meter's own identifier, or — for a pair — the left pedal's.
    /// Stable across launches either way, which is what lets the rider's manual
    /// choice of a primary survive quitting the app.
    let id: UUID
    var name: String
    var kind: MeterKind
    var shape: Shape
    /// Every meter this source is made of, in display order.
    var memberIDs: [UUID]

    var isPair: Bool {
        if case .pedalPair = shape { return true }
        return false
    }

    var measuresPower: Bool { kind.measuresPower }
}

extension PowerSource {

    /// The markers a pedal meter puts on the end of its name to say which side
    /// it is. Ordered longest first so `Left` is tried before `L`.
    private static let sideMarkers: [(text: String, side: PedalSide)] = [
        ("left", .left), ("right", .right),
        ("l", .left), ("r", .right),
    ]

    /// Splits `powertap P1.L` into `("powertap p1", .left)`.
    ///
    /// - Returns: nil when the name carries no side marker, which is the answer
    ///   for every trainer and every crank and most pedals too.
    static func pedalSide(of name: String) -> (base: String, side: PedalSide)? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // A trailing marker may be bracketed, and is always preceded by a
        // separator — otherwise `Assioma` ends in an `a` and every meter whose
        // name happens to finish in `l` becomes half of a pair.
        let stripped = trimmed.hasSuffix(")") ? String(trimmed.dropLast()) : trimmed
        for (text, side) in sideMarkers {
            guard stripped.lowercased().hasSuffix(text) else { continue }
            let base = String(stripped.dropLast(text.count))
            guard let separator = base.last, ".-_ (/".contains(separator) else { continue }
            let cleaned = base.dropLast()
                .trimmingCharacters(in: CharacterSet(charactersIn: " .-_(/"))
                .lowercased()
            guard !cleaned.isEmpty else { continue }
            return (cleaned, side)
        }
        return nil
    }

    /// Reads a list of paired meters as a list of sources, joining any left and
    /// right pedal meters that name the same bike part.
    ///
    /// Order follows the input, with a pair standing where its first side stood,
    /// so the list does not reshuffle when the second pedal wakes up.
    static func group(_ meters: [PairedMeter]) -> [PowerSource] {
        var sources: [PowerSource] = []
        /// Base name → where in `sources` the side that arrived first is sitting.
        /// Only power meters get in: a speed-and-cadence sensor named `Bike L` is
        /// not half of anything.
        var awaitingPartner: [String: (side: PedalSide, index: Int)] = [:]

        for meter in meters {
            let single = PowerSource(id: meter.id,
                                     name: meter.name,
                                     kind: meter.kind,
                                     shape: .single,
                                     memberIDs: [meter.id])
            guard meter.kind == .cyclingPower,
                  let (base, side) = pedalSide(of: meter.name) else {
                sources.append(single)
                continue
            }
            guard let waiting = awaitingPartner[base], waiting.side != side else {
                awaitingPartner[base] = (side, sources.count)
                sources.append(single)
                continue
            }
            awaitingPartner[base] = nil
            let first = sources[waiting.index]
            let left = side == .left ? meter.id : first.id
            let right = side == .left ? first.id : meter.id
            // The shared part of the two names, with the side marker gone:
            // `powertap P1.L` and `powertap P1.R` become `powertap P1`, and the
            // row can say `pair` for itself.
            let shared = commonPrefix(first.name, meter.name)
            sources[waiting.index] = PowerSource(id: left,
                                                 name: shared.isEmpty ? first.name : shared,
                                                 kind: .cyclingPower,
                                                 shape: .pedalPair(left: left, right: right),
                                                 memberIDs: [left, right])
        }
        return sources
    }

    /// The part both names start with, trimmed of the separator that was about
    /// to introduce the side marker.
    private static func commonPrefix(_ a: String, _ b: String) -> String {
        var shared = ""
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            shared.append(x)
        }
        return shared.trimmingCharacters(in: CharacterSet(charactersIn: " .-_(/"))
    }
}
