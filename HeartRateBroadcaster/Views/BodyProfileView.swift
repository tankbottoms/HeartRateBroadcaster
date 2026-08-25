import SwiftUI

/// Weight, height, birth date and sex — the four inputs the energy estimate
/// needs and the only personal data the app holds. Everything stays on the
/// phone; nothing here is transmitted anywhere.
struct BodyProfileView: View {
    @Bindable var settings: AppSettings

    /// Feet and inches are held apart from the stored centimetres while the
    /// user is typing. Deriving them back from the total on every keystroke
    /// would renormalise mid-entry — typing 14 into the inches field would
    /// snap the row to 1 ft 2 in under the cursor.
    @State private var feet = 0
    @State private var inches: Double = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {
                SectionHeading(title: "Units")
                SettingCard(title: "Metric",
                            subtitle: "Kilograms and centimetres instead of pounds and feet.") {
                    // An empty string literal here would be extracted as a
                    // translation unit with no text in it. The label is hidden
                    // anyway; the card's own title is what the user reads.
                    Toggle(isOn: $settings.usesMetricBody) { EmptyView() }
                        .labelsHidden()
                }

                SectionHeading(title: "Measurements")
                Card {
                    VStack(spacing: Theme.Metric.cardSpacing) {
                        measurementRow(title: "Weight",
                                       value: $settings.bodyMassKilograms,
                                       metricSuffix: "kg",
                                       imperialSuffix: "lb",
                                       toImperial: BodyProfile.pounds(fromKilograms:),
                                       toMetric: BodyProfile.kilograms(fromPounds:))

                        Divider().overlay(Theme.separator)

                        heightRow
                    }
                }

                SectionHeading(title: "About you")
                Card {
                    VStack(alignment: .leading, spacing: Theme.Metric.cardSpacing) {
                        DatePicker("Date of birth",
                                   selection: Binding(get: { settings.dateOfBirth ?? defaultBirthDate },
                                                      set: { settings.dateOfBirth = $0 }),
                                   in: ...Date(),
                                   displayedComponents: .date)
                            .font(Theme.Typeface.sectionTitle)
                            .foregroundStyle(Theme.textPrimary)

                        Divider().overlay(Theme.separator)

                        Picker("Sex", selection: $settings.biologicalSex) {
                            ForEach(BiologicalSex.allCases, id: \.self) { sex in
                                Text(label(for: sex)).tag(sex)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Text("These figures are used only to estimate energy burned. They stay on this phone.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)
            }
            .padding(Theme.Metric.screenPadding)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Body")
        .onAppear(perform: loadFeetAndInches)
        .onChange(of: settings.usesMetricBody) { _, _ in loadFeetAndInches() }
    }

    // MARK: - Height

    /// Metric is one field; imperial is two, because nobody knows their height
    /// in inches. The stored value stays centimetres either way.
    @ViewBuilder
    private var heightRow: some View {
        if settings.usesMetricBody {
            measurementRow(title: "Height",
                           value: $settings.bodyHeightCentimetres,
                           metricSuffix: "cm",
                           imperialSuffix: "cm",
                           toImperial: { $0 },
                           toMetric: { $0 })
        } else {
            HStack {
                Text("Height")
                    .font(Theme.Typeface.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                TextField(String(), value: $feet, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                    .foregroundStyle(Theme.textPrimary)
                Text("ft")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, alignment: .leading)
                TextField(String(), value: $inches, format: .number.precision(.fractionLength(0 ... 1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                    .foregroundStyle(Theme.textPrimary)
                Text("in")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, alignment: .leading)
            }
            .onChange(of: feet) { _, _ in storeFeetAndInches() }
            .onChange(of: inches) { _, _ in storeFeetAndInches() }
        }
    }

    private func loadFeetAndInches() {
        let total = BodyProfile.inches(fromCentimetres: settings.bodyHeightCentimetres)
        guard total > 0 else {
            feet = 0
            inches = 0
            return
        }
        // Rounded to the whole inch first, so 5 ft 11.96 in reads as 6 ft 0 in
        // rather than 5 ft 12 in.
        let whole = total.rounded()
        feet = Int(whole / 12)
        inches = whole.truncatingRemainder(dividingBy: 12)
    }

    private func storeFeetAndInches() {
        let total = Double(max(0, feet)) * 12 + max(0, inches)
        settings.bodyHeightCentimetres = total > 0 ? BodyProfile.centimetres(fromInches: total) : 0
    }

    /// Roughly a middle-aged rider. Only ever a starting position for the
    /// picker — `dateOfBirth` stays nil until the user actually chooses.
    private var defaultBirthDate: Date {
        Calendar.current.date(byAdding: .year, value: -40, to: Date()) ?? Date()
    }

    private func label(for sex: BiologicalSex) -> LocalizedStringKey {
        switch sex {
        case .female: "Female"
        case .male: "Male"
        case .unspecified: "Prefer not to say"
        }
    }

    /// One numeric field that stores SI and shows whatever the user reads in.
    /// The conversion lives at the field rather than at the model so that the
    /// energy code never has to ask which unit it was handed.
    @ViewBuilder
    private func measurementRow(title: LocalizedStringKey,
                                value: Binding<Double>,
                                metricSuffix: LocalizedStringKey,
                                imperialSuffix: LocalizedStringKey,
                                toImperial: @escaping (Double) -> Double,
                                toMetric: @escaping (Double) -> Double) -> some View {
        HStack {
            Text(title)
                .font(Theme.Typeface.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            // `String()` rather than a "" literal: the empty literal picks the
            // LocalizedStringKey overload and lands in the catalog as a
            // translation unit with nothing in it. There is no placeholder to
            // show — the row's own label says what the number is.
            TextField(String(), value: Binding(
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
