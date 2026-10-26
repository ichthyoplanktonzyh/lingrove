import SwiftUI

/// File overview:
/// The onboarding personalization step. Merges what used to be two wizard screens (the "about you"
/// name-and-languages step and the gated "writing style" custom-rules step) into one, so the flow
/// stays four counted steps whether or not custom rules are user-facing
/// (`CustomRulesCatalog.isUserFacingEnabled`).
///
/// The editors are the real settings components (`LanguageTagsEditor`, `CustomRulesEditor`)
/// writing through `SuggestionSettingsModel`; this view only supplies onboarding's card framing.
struct WelcomePersonalizeStepView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var learning: LanguageLearningSettings

    var body: some View {
        VStack(spacing: 24) {
            OnboardingStepHeader(
                systemImage: "person.crop.circle.fill",
                title: String(localized: "Languages"),
                subtitle: String(localized: "Choose the languages for writing, translation, and explanation.", table: "Learning")
            )
            .onboardingReveal(0)

            VStack(spacing: 12) {
                personalizeCard(icon: "globe", title: String(localized: "Autocomplete"), index: 1) {
                    LanguageTagsEditor(suggestionSettings: suggestionSettings, showsTitleHeader: false, collapsesSuggestions: true)
                }
                personalizeCard(icon: "character.bubble", title: String(localized: "Language Learning", table: "Learning"), index: 2) {
                    languagePicker(String(localized: "Translation & expression language", table: "Learning"),
                        selection: $learning.targetLanguage)
                    languagePicker(String(localized: "Reading target language", table: "Learning"),
                        selection: $learning.readingTargetLanguage)
                    Picker(String(localized: "Explanation language", table: "Learning"), selection: $learning.explanationLanguage) {
                        Text(String(localized: "Interface language", table: "Learning")).tag(nil as LearningLanguage?)
                        ForEach(LearningLanguage.allCases) { Text($0.label).tag(Optional($0)) }
                    }.pickerStyle(.menu)
                }
                personalizeCard(icon: "textformat", title: String(localized: "Your name"), index: 3) {
                    TextField(String(localized: "What should Lingrove call you? (Optional)", table: "Learning"), text: Binding(
                        get: { suggestionSettings.userName },
                        set: { suggestionSettings.setUserName($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                }

                if CustomRulesCatalog.isUserFacingEnabled {
                    personalizeCard(icon: "character.cursor.ibeam", title: String(localized: "Writing style"), index: 3) {
                        CustomRulesEditor(suggestionSettings: suggestionSettings, showsTitleHeader: false)
                    }
                }
            }
        }
    }

    private func languagePicker(_ title: String, selection: Binding<LearningLanguage>) -> some View {
        Picker(title, selection: selection) {
            ForEach(LearningLanguage.allCases) { Text($0.label).tag($0) }
        }.pickerStyle(.menu)
    }

    private func personalizeCard(
        icon: String,
        title: String,
        index: Int,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LingroveBrand.accent)

                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCard()
        .onboardingReveal(index)
    }
}
