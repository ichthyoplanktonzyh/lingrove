import SwiftUI

/// A compact choice before the existing advanced forms. It observes the coordinator-owned setup
/// operation, so progress and retry survive navigation; rendering this card never applies a plan.
struct RecommendedSetupView: View {
    @ObservedObject var setup: RecommendedSetupController
    let configureManually: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(String(localized: "Recommended setup", table: "Learning"), systemImage: "sparkles")
                    .font(.title2.bold())
                Text(String(localized: """
                Set up autocomplete, translation and expression assistance together. \
                Existing models, languages and shortcuts are kept.
                """, table: "Learning"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 14) {
                    modelRow(.completion, model: setup.completionModel,
                        fallback: setup.completionEngine.displayLabel)
                    modelRow(.translation, model: setup.learningModel(.translation), fallback: existingModel(.translation))
                    modelRow(.explanation, model: setup.learningModel(.explanation), fallback: existingModel(.explanation))
                    modelRow(.speech, model: nil, fallback: setup.speech.selectedProvider.label)
                }
                Text(String(localized: """
                Missing models download to this Mac. Explanation and expression assistance share one model. \
                New setups use system speech.
                """, table: "Learning"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if setup.usesEndpoint {
                    Label(String(localized: "Your existing endpoints will receive requests for enabled features.", table: "Learning"),
                        systemImage: "network")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if setup.hasMissingDownloads {
                    Text(String(localized: "Download size: \(setup.downloadSize)", table: "Learning"))
                        .font(.callout.monospacedDigit())
                }
                HStack {
                    if setup.isDownloading {
                        Button(String(localized: "Pause download"), action: setup.pauseDownloads)
                    } else if setup.needsApplication {
                        Button(String(localized: "Use recommended setup", table: "Learning"), action: setup.apply)
                            .buttonStyle(.borderedProminent).disabled(setup.plan == nil)
                            .accessibilityIdentifier("recommendedSetup.apply")
                    } else if setup.hasMissingDownloads {
                        Button(String(localized: "Retry downloads", table: "Learning"), action: setup.retryDownloads)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Label(String(localized: "Settings applied", table: "Learning"), systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(String(localized: "Configure manually", table: "Learning"), action: configureManually)
                }
                Text(String(localized: "System permissions are completed separately in the permission step.", table: "Learning"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).onboardingCard().padding(.horizontal, OnboardingLayout.horizontalPadding).padding(.vertical, 16)
        }.accessibilityIdentifier("recommendedSetup")
    }

    private func existingModel(_ role: LearningModelRole) -> String {
        let profile = role == .translation ? setup.settings.languageLearning.translation : setup.settings.languageLearning.explanation
        return profile.snapshot.backend == .endpoint ? profile.snapshot.endpointModel
            : LocalModelCatalog.displayName(for: profile.snapshot.localModel)
    }

    private func modelRow(_ task: SettingsEngineTask, model: DownloadableRuntimeModel?, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(task == .speech ? String(localized: "Read Aloud", table: "Learning") : task.label).font(.headline)
                Spacer()
                if let model {
                    Text(setup.downloads.state(for: model).statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(model?.displayName ?? fallback).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let model, setup.downloads.state(for: model).isDownloading {
                ProgressView(value: setup.downloads.state(for: model).progressFraction)
                    .accessibilityLabel(task.label)
            }
        }
    }
}
