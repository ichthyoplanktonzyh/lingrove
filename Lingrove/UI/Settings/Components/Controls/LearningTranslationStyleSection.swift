import SwiftUI

/// Expression style is edited beside translation behavior but saved with the selected model's
/// profile. The app-owned profile publishes its committed request identity, so an old preview is
/// invalidated before new style results arrive. This view owns no draft or inference service.
struct LearningTranslationStyleSection: View {
    @ObservedObject var profile: LearningModelSettings

    var body: some View {
        let identity = profile.contextIdentity
        let style = profile.generationProfile.style
        Section(String(localized: "Translation style", table: "Learning")) {
            Picker(String(localized: "Style", table: "Learning"), selection: Binding(
                get: { profile.translationStyleAvailable == true ? profile.generationProfile.style.register : .natural }, set: {
                    var value = profile.generationProfile; value.style.register = $0
                    profile.setGenerationProfile(value, expectedIdentity: identity)
                })) {
                ForEach(LearningTranslationStyle.Register.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.menu).disabled(profile.translationStyleAvailable != true).settingsItem(.translationStyle)
            if profile.translationStyleAvailable == false {
                Text(String(localized: "This model does not support translation style instructions.", table: "Learning"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if profile.translationStyleAvailable == true, style.register == .custom {
                TextField(String(localized: "Style instructions", table: "Learning"), text: Binding(
                    get: { profile.generationProfile.style.customInstruction }, set: {
                        var value = profile.generationProfile; value.style.customInstruction = $0
                        profile.setGenerationProfile(value, expectedIdentity: identity)
                    }), axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
            }
        }
        .id(identity)
    }
}
