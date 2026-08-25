import SwiftUI

struct AboutView: View {

    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// The canonical hostname. `hrb.atsignhandle.xyz` answers the same site and
    /// is offered below as the short one worth typing on a phone; this is the
    /// one every page canonicalises to, so it is the one the links use.
    private let site = "https://heart-rate.atsignhandle.xyz"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {

                    VStack(alignment: .leading, spacing: 6) {
                        Text("HeartRate Broadcaster")
                            .font(Theme.Typeface.screenTitle)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Version \(shortVersion) · build \(kBuildTag)")
                            .font(Theme.Typeface.rowDetail)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    // First, not last. Someone whose device is in a language they
                    // are only half comfortable in should not have to read four
                    // screens of English to find the control that fixes it.
                    VStack(alignment: .leading, spacing: 6) {
                        LanguagePicker(settings: settings)
                            .font(Theme.Typeface.rowDetail)
                            .foregroundStyle(Theme.textPrimary)
                        Text("""
                        This app is translated into twenty-five languages and \
                        follows your device by default. Changing it here changes \
                        only this app, and takes effect immediately. The same \
                        control is in Settings.
                        """)
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    block("Why this exists", """
                    I wanted one simple thing, and it did not exist.

                    An Apple Watch measures heart rate well but cannot hand it to \
                    a training app, so the usual advice is to buy a chest strap. \
                    Separately, the watch will pair a power meter, and there are \
                    ways to get a KICKR talking to it. None of that lets MyWhoosh \
                    control the trainer, and controlling the trainer is the ride.

                    So this is one app for the whole setup: heart rate, the power \
                    meters, the KICKR CORE 2, the shifting, and the workout \
                    itself. All of it goes to MyWhoosh, which records the heart \
                    rate, the power, the shifts and the calorie figure against a \
                    virtual route.

                    At the end MyWhoosh has that route and the activity as a FIT \
                    file. An earlier ride can be exported from there and imported \
                    into Strava; once the two accounts are connected, later rides \
                    sync on their own.
                    """)

                    // Line art on paper, so it is boxed on a light card in both
                    // appearances rather than inverted for dark mode. Inverting a
                    // pencil drawing does not produce a dark-mode drawing, it
                    // produces a photographic negative.
                    Image("TrainerSetup")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel(Text("A time trial bike on a Wahoo KICKR trainer"))

                    Text("""
                    The setup this was written for: a Dimond time trial bike on a \
                    Wahoo KICKR CORE 2, an Apple Watch, an iPad mini on the bars, \
                    and no chest strap anywhere. Drawing by Google Gemini.
                    """)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    block("How it works", """
                    Your Apple Watch runs a workout session so it can read heart \
                    rate continuously. Each reading is sent to this iPhone, which \
                    re-broadcasts it over Bluetooth LE as a standard heart rate \
                    monitor — service 0x180D. Bike computers and training apps see \
                    the phone as an ordinary chest strap.
                    """)

                    block("Pairing", """
                    Keep this app in the foreground while your head unit searches \
                    for sensors. iOS hides an app's Bluetooth advertisement once \
                    the app goes to the background, so a Garmin or an iPad cannot \
                    discover the phone unless the screen is on. After the head \
                    unit has connected, the link survives locking the phone.
                    """)

                    block("Virtual shifter", """
                    Switch Virtual Shifter on and the phone also offers itself to \
                    cycling apps on the same Wi-Fi network as a shifter, over the \
                    open Bike Control protocol. Shift buttons appear under the \
                    heart rate; they do what a set of Zwift or KICKR Clicks would \
                    do. Nothing is paired over Bluetooth and nothing leaves your \
                    network — the phone and the app find each other directly.

                    No game reports which gear it is in, so the two sides agree by \
                    the app stating a gear rather than guessing one. It states the \
                    gear the moment a game identifies itself, and tapping the gear \
                    number states it again — useful if you have been shifting in \
                    the game as well.

                    Some games will not be told a gear at all. MyWhoosh is one, \
                    and it opens every session in 15, so on connecting to a game \
                    like that the counter moves to 15 to match. From there the \
                    two stay together as long as the shifting is done here.

                    Set Gears to the same range the game is using. Both devices \
                    must be on the same network, and this app has to be open.
                    """)

                    block("What it works with", """
                    Built and ridden against a Wahoo KICKR CORE 2, PowerTap P1 \
                    pedals and a SRAM Red crank power meter, with MyWhoosh as the \
                    cycling app and shifting over the open Bike Control protocol \
                    from the OpenBikeControl specification.

                    None of that is special. Any Bluetooth power meter, smart \
                    trainer or head unit speaking the standard cycling profiles \
                    will work, and any app that pairs a Bluetooth heart rate strap \
                    will see this phone as one.
                    """)

                    block("What is saved where", """
                    A finished ride is saved in this app, written to Apple Health, \
                    and — while you are riding — sent live to whatever you are \
                    riding into. Those are three separate things, and Settings › \
                    Apple Health turns off the middle one.

                    That is worth doing if the ride already reaches Health the \
                    long way round: this app to MyWhoosh, MyWhoosh to Strava as a \
                    FIT with the route on it, Strava back into Health. Saving it \
                    here as well puts the same hour in twice.
                    """)

                    block("If nothing is found", """
                    Switch Heart Rate Source to Test Signal. That generates a heart \
                    rate on the phone itself. If your head unit finds the broadcast \
                    then, Bluetooth is fine and the problem is the watch link. If it \
                    still finds nothing, check that Bluetooth is on and that this \
                    app has Bluetooth permission.
                    """)

                    block("Frames sent stays at zero", """
                    Frames are only ever sent to something that has subscribed. \
                    Until a head unit connects there is nobody to send to, so the \
                    count stays at zero however well the watch link is working — \
                    that is why the footer names the missing subscriber rather \
                    than only showing a zero.
                    """)

                    block("ANT+", """
                    This app does not support ANT+. It broadcasts over Bluetooth \
                    LE only.

                    ANT+ is a separate radio protocol. An iPhone has no ANT+ \
                    hardware, so no app can transmit it — this is a limitation of \
                    the device, not of this app, and it cannot be worked around \
                    in software.

                    Devices that pair heart rate over ANT+ only, including the \
                    Garmin Forerunner 935, will never see this broadcast. Anything \
                    that accepts a Bluetooth heart rate sensor will: MyWhoosh, \
                    Zwift, TrainerRoad, Wahoo, and recent Garmin Edge units.
                    """)

                    block("Heart rate sources", """
                    The watch and AirPods Pro 3 can both report heart rate. When \
                    both are selected the app reconciles them into a single value \
                    before broadcasting — head units are only ever sent one \
                    stream. Readings that agree are averaged; a reading that \
                    disagrees sharply with the other sensor is dropped rather \
                    than averaged in.

                    AirPods heart rate is only produced while a workout is \
                    running on the phone, which is why selecting an AirPods \
                    source starts one.
                    """)

                    block("Privacy", """
                    There is no account, no analytics and no server. Your heart \
                    rate is read on the device, held only for as long as it takes \
                    to send it, and transmitted over Bluetooth to whatever you \
                    paired with — exactly as a chest strap would. Nothing is \
                    uploaded anywhere, and nothing about you reaches the \
                    developer.
                    """)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("More")
                            .font(Theme.Typeface.sectionTitle)
                            .foregroundStyle(Theme.textPrimary)
                        link("Website — heart-rate.atsignhandle.xyz", site)
                        link("Short link — hrb.atsignhandle.xyz", "https://hrb.atsignhandle.xyz")
                        // Extensionless on purpose. Cloudflare's asset server
                        // serves these at `/faq` and redirects `/faq.html` to
                        // it, so the extension costs a round trip and reads
                        // worse in a share sheet.
                        link("Frequently asked questions", "\(site)/faq")
                        link("Privacy policy", "\(site)/privacy")
                        link("Source code on GitHub", "https://github.com/tankbottoms/HeartRateBroadcaster")
                        Text("The website is published in the same twenty-five languages and follows your browser.")
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Named products belong in a compatibility list; named
                    // products also belong to somebody. Ownership is deliberately
                    // not assigned name by name — several of these brands have
                    // changed hands, and a wrong owner is worse than none.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("© 2026 atsignhandle llc")
                        Text("""
                        Wahoo, KICKR, PowerTap, SRAM, Red, MyWhoosh, Strava, \
                        Apple, Apple Watch, AirPods and Zwift are trademarks of \
                        their respective owners. This app is not affiliated with, \
                        endorsed by, or sponsored by any of them. Bike Control is \
                        an open protocol, implemented here from the public \
                        OpenBikeControl specification.
                        """)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.textTertiary)
                }
                .padding(Theme.Metric.screenPadding)
            }
            .background(Theme.background)
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// The label travels, the URL does not.
    private func link(_ title: LocalizedStringKey, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .font(Theme.Typeface.rowDetail)
        }
    }

    /// Both parameters are keys, not strings. Every call site passes a literal —
    /// including the multi-line ones — so the whole of this screen becomes
    /// translatable without touching a single call.
    private func block(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.Typeface.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
            Text(body)
                .font(Theme.Typeface.rowDetail)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
