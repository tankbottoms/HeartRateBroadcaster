import SwiftUI

/// Shift down, the gear, shift up — the whole shifter, under the heart rate.
///
/// Two buttons the size of a thumb, because the rider pressing them is on a
/// trainer at threshold and is not going to aim. Deliberately not a stepper: a
/// stepper's two halves are eleven points tall and share an edge, which is a
/// mis-shift waiting to happen at 300 watts.
struct ShiftControlCard: View {

    let service: BikeControlService
    /// Called after every shift so the gear survives the app being closed.
    let onGearChanged: (Int) -> Void

    var body: some View {
        Card {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    button(systemImage: "minus", identifier: "shift-down") {
                        service.shiftDown()
                        onGearChanged(service.gear)
                    }
                    .disabled(!service.state.canShift || service.gear <= 1)

                    // The number is a menu as well as a readout. A game picks its
                    // own gear when it connects and never says which, so the only
                    // way to agree is to state one — and the rider needs somewhere
                    // to state it from.
                    Menu {
                        Picker("Gear", selection: gearBinding) {
                            ForEach(1 ... max(service.gearCount, 1), id: \.self) { Text("\($0)").tag($0) }
                        }
                    } label: {
                        VStack(spacing: 0) {
                            Text("\(service.gear)")
                                .font(Theme.Typeface.heartRate)
                                .foregroundStyle(Theme.textPrimary)
                                .contentTransition(.numericText())
                                .animation(.snappy, value: service.gear)
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                            Text(service.canSetGear ? "Gear · tap to set" : "Gear")
                                .font(Theme.Typeface.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!service.canSetGear)
                    .accessibilityIdentifier("gear-picker")

                    button(systemImage: "plus", identifier: "shift-up") {
                        service.shiftUp()
                        onGearChanged(service.gear)
                    }
                    .disabled(!service.state.canShift || service.gear >= service.gearCount)
                }

                // Two lines, always. "Shifting mywhoosh" is one and "Connected —
                // waiting for the app to identify itself" is three in half the
                // languages we ship, and the difference was moving the buttons
                // under the rider's thumb between one press and the next.
                ScrollingText(text: status,
                              rows: 2,
                              color: service.state.canShift ? Theme.textSecondary : Theme.textTertiary,
                              alignment: .center)
            }
        }
        .accessibilityIdentifier("shift-control-card")
    }

    /// Setting the gear sends it as well as showing it, which is the difference
    /// between the two sides agreeing and the app merely claiming they do.
    private var gearBinding: Binding<Int> {
        Binding(get: { service.gear },
                set: { service.setGear($0); onGearChanged(service.gear) })
    }

    private func button(systemImage: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 64, height: 56)
        }
        .buttonStyle(.bordered)
        .tint(Theme.textPrimary)
        .accessibilityIdentifier(identifier)
    }

    /// Says where the shift is going, and — when it is going nowhere — why.
    private var status: LocalizedStringKey {
        switch service.state {
        case .off:                    return "Bike Control is off"
        case .starting:               return "Starting…"
        case .advertising:            return "Waiting for a cycling app to connect"
        case .connecting:             return "Connected — waiting for the app to identify itself"
        case .ready(let app) where service.canSetGear:
                                      return "Shifting \(app)"
        case .ready(let app):         return "Shifting \(app) · gear counted on this phone"
        case .failed(let why):        return .init(stringLiteral: why)
        }
    }
}

// MARK: - Settings

/// The Bike Control block on the main screen, next to the other pairing
/// controls: this is another thing the phone connects to, and it belongs where
/// the rider already goes to connect things.
struct BikeControlSection: View {

    let service: BikeControlService
    @Binding var enabled: Bool
    @Binding var gearCount: Int

    var body: some View {
        VStack(spacing: Theme.Metric.cardSpacing) {
            SectionHeading(title: "Bike Control")

            SettingCard(title: "Virtual Shifter",
                        subtitle: subtitle,
                        help: "Offers this phone to cycling apps on the same Wi-Fi network as a shifter, using the open Bike Control protocol. The buttons in this app take the place of Zwift or KICKR Clicks — nothing has to be paired over Bluetooth, and the phone never leaves your network. Nothing reports which gear you are in, so the app states one when it connects rather than guessing: tap the gear number to put both sides on the same gear at any time.") {
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .tint(Theme.accentActive)
            }

            if enabled {
                SettingCard(title: "Gears",
                            subtitle: "Match the virtual range your cycling app is set to") {
                    Picker("", selection: $gearCount) {
                        // The ranges games actually offer. A free number field
                        // would be a way to type 3 by accident and then wonder
                        // why the top of the cassette has gone.
                        ForEach([12, 16, 20, 24, 30], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                StatusRow(icon: "point.3.connected.trianglepath.dotted",
                          title: "Cycling App",
                          detail: detail,
                          ok: ok,
                          hint: hint)
            }
        }
    }

    private var subtitle: LocalizedStringKey {
        enabled ? "Shift buttons appear under the heart rate" : "Shift your trainer from this app"
    }

    private var detail: LocalizedStringKey {
        switch service.state {
        case .off:                   return "Off"
        case .starting:              return "Starting…"
        case .advertising(let port): return "Advertising on port \(port)"
        case .connecting:            return "Connected — no app info yet"
        case .ready(let app):
            // Version too: "which app" is rarely the question when shifting has
            // stopped working, and "which build of it" often is.
            let version = service.appInfo?.appVersion ?? ""
            return version.isEmpty ? "\(app)" : "\(app) \(version)"
        case .failed(let why):       return .init(stringLiteral: why)
        }
    }

    private var ok: Bool? {
        switch service.state {
        case .off:                       return nil
        case .ready:                     return true
        case .failed:                    return false
        case .starting, .advertising, .connecting: return nil
        }
    }

    private var hint: LocalizedStringKey? {
        switch service.state {
        case .advertising:
            return "In your cycling app, look for a controller or shifter named after this phone. Both devices have to be on the same Wi-Fi network, and this app has to be open."
        case .ready where service.appInfo?.supportsShifting == false:
            return "The connected app is not asking for shift buttons, so pressing them will do nothing. Check that virtual shifting is switched on there."
        case .failed:
            return "Turn the switch off and on again to retry. If it keeps failing, another app on this phone may be holding the Bike Control port."
        default:
            return nil
        }
    }
}
