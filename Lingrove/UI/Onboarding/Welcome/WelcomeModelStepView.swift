import SwiftUI

/// One wizard-local navigation model selects a task, while the app supplies its existing model
/// forms. This boundary owns layout only; selecting a tab never applies a completion preset.
struct WelcomeModelStepView<Completion: View>: View {
    @ObservedObject var navigation: SettingsNavigationModel
    @Binding var configuresCompletion: Bool
    let configuration: (SettingsNavigationModel) -> AnyView
    @ViewBuilder let completion: () -> Completion

    var body: some View {
        VStack(spacing: 12) {
            OnboardingStepHeader(systemImage: "cpu",
                title: String(localized: "Engine & Model"),
                subtitle: String(localized: "Configure each task now, or continue and set it up later.", table: "Learning"))
                .padding(.horizontal, OnboardingLayout.horizontalPadding).padding(.top, 18)
            Picker(String(localized: "Model task", table: "Learning"), selection: Binding(
                get: { navigation.engineTask }, set: navigation.openEngineTask)) {
                ForEach(SettingsEngineTask.allCases.filter { $0 != .vocabularySearch }) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, OnboardingLayout.horizontalPadding)
                .accessibilityIdentifier("welcomeModelTask")
            if navigation.engineTask == .completion && !configuresCompletion {
                ScrollView {
                    VStack(spacing: 16) {
                        completion()
                        Button(String(localized: "Configure current model", table: "Learning")) { configuresCompletion = true }
                    }.padding(.horizontal, OnboardingLayout.horizontalPadding).padding(.vertical, 12)
                }
            } else {
                if navigation.engineTask == .completion {
                    Button(String(localized: "Choose a starting point")) { configuresCompletion = false }
                }
                configuration(navigation)
            }
        }.accessibilityIdentifier("welcomeModels")
    }
}
