import SwiftUI

/// One task provides its profile binding and real recommendation; this section owns no services
/// or persisted state. Endpoint controls expose only the two fields our compatible client sends.
/// Local speech labels the two talker-only controls explicitly, without implying codec support.
struct ModelSamplingSection: View {
    @Binding var overrides: ModelSamplingOverrides
    let recommended: ModelSamplingValues
    let local: Bool
    var speech = false
    let item: SettingsItem

    var body: some View {
        Section(String(localized: "Generation parameters", table: "Learning")) {
            Toggle(String(localized: "Use recommended parameters", table: "Learning"), isOn: Binding(
                get: { overrides.isRecommended },
                set: { overrides = $0 ? .init() : recommended.customized(local: local) }))
                .settingsItem(item)
            if !overrides.isRecommended {
                decimal(speech ? String(localized: "Talker temperature", table: "Learning") : "Temperature",
                    binding: field(\.temperature, fallback: recommended.temperature), range: 0...2, step: 0.05)
                decimal("Top-p", binding: field(\.topP, fallback: recommended.topP), range: 0.01...1, step: 0.05)
                if local {
                    LabeledContent("Top-k") {
                        HStack(spacing: 8) {
                            TextField("", value: topK, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).frame(width: 72).accessibilityLabel("Top-k")
                            Stepper("", value: topK, in: 1...256).labelsHidden().accessibilityLabel("Top-k")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    decimal(speech ? String(localized: "Talker repetition penalty", table: "Learning")
                            : String(localized: "Repetition penalty", table: "Learning"),
                        binding: field(\.repetitionPenalty, fallback: recommended.repetitionPenalty), range: 1...2, step: 0.05)
                    Picker(String(localized: "Random seed", table: "Learning"), selection: Binding(
                        get: { overrides.seedMode },
                        set: {
                            guard !overrides.isRecommended else { return }
                            var next = overrides
                            next.seedMode = $0
                            overrides = next
                        })) {
                        ForEach(ModelSamplingOverrides.SeedMode.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.menu)
                    if overrides.seedMode == .fixed {
                        LabeledContent(String(localized: "Seed value", table: "Learning")) {
                            TextField("", value: Binding(get: { Int(overrides.fixedSeed) }, set: {
                                guard !overrides.isRecommended, overrides.seedMode == .fixed else { return }
                                var next = overrides; next.fixedSeed = UInt32(clamping: min(max($0, 0),
                                    Int(UInt32.max - 1))); overrides = next
                            }), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 160)
                            .accessibilityLabel(String(localized: "Seed value", table: "Learning"))
                        }
                    }
                }
                Button(String(localized: "Restore recommended values", table: "Learning")) { overrides = .init() }
            }
        }
    }

    private var topK: Binding<Int> {
        Binding(get: { overrides.topK ?? recommended.topK }, set: {
            guard !overrides.isRecommended else { return }
            var next = overrides; next.topK = $0; overrides = next.normalized
        })
    }

    private func field(_ key: WritableKeyPath<ModelSamplingOverrides, Double?>, fallback: Double) -> Binding<Double> {
        Binding(get: { overrides[keyPath: key] ?? fallback }, set: {
            // A formatted field may commit again as Reset removes it from the Form. Once the
            // profile is recommended, that late edit belongs to a retired control and must not
            // resurrect an explicit override. The visible toggle remains the customization gate.
            guard !overrides.isRecommended else { return }
            var next = overrides; next[keyPath: key] = $0; overrides = next.normalized
        })
    }

    private func decimal(_ title: String, binding: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField("", value: binding, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).frame(width: 72).accessibilityLabel(title)
                Stepper("", value: binding, in: range, step: step).labelsHidden().accessibilityLabel(title)
            }
        } label: { Text(title) }
        .accessibilityElement(children: .contain)
    }
}
