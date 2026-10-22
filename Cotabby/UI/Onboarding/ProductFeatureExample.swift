import SwiftUI

/// The example sheet mounts the existing player only after the user requests it. Its scenes,
/// reviewed material, controls and cancellation stay shared with Home; no second demo engine
/// or animation loop is introduced for Home, the guide, or setup.
struct ProductFeatureExample: View {
    let title: String
    let scene: HomeLearningScene?
    @ObservedObject var settings: LanguageLearningSettings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(String(localized: "Close", table: "Learning")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let scene {
                HomeLearningShowcase(readingSettings: settings, startingScene: scene, autoplayOnHover: false)
            } else {
                ScrollView { OnboardingFeatureShowcase(autoplay: false, showsMacroReference: true) }
            }
        }.padding(20).frame(width: 640, height: 600)
    }
}
