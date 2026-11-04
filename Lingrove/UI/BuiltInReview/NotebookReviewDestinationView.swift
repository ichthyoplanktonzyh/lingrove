import Combine
import SwiftUI

/// The corpus window retains the selected review tool independently of the outer destination.
/// A target change only suspends presentation work; it never moves participation or history.
@MainActor
final class NotebookReviewDestinationModel: ObservableObject {
    enum Target: String, CaseIterable { case lingrove, anki }
    @Published var target: Target = .lingrove {
        didSet { if oldValue != target { onChange?(target) } }
    }
    var onChange: ((Target) -> Void)?
}

/// Equal-level tool choices borrow the app's existing sessions. Neither mounting a tool nor
/// switching between them connects to Anki, enrolls a sense or begins a Lingrove round.
struct NotebookReviewDestinationView: View {
    @ObservedObject var navigation: NotebookReviewDestinationModel
    @ObservedObject var session: BuiltInReviewSession
    var anki: AnkiReviewController?

    var body: some View {
        VStack(spacing: 0) {
            if navigation.target == .lingrove {
                BuiltInReviewWindowView(session: session, targetNavigation: navigation)
            } else {
                ankiHeader
                Divider().opacity(0.6)
                if let anki {
                    AnkiReviewDestinationView(controller: anki)
                } else {
                    ContentUnavailableView(BuiltInReviewCopy.text("anki.unavailable"), systemImage: "rectangle.stack")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var ankiHeader: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LingroveBrand.accent.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LingroveBrand.accent)
                }
                Text(String(localized: "Review", table: "ReviewCards"))
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            NotebookReviewTargetSwitch(navigation: navigation, session: session)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

/// Shared segmented control for switching between built-in Lingrove review and external Anki sync.
struct NotebookReviewTargetSwitch: View {
    @ObservedObject var navigation: NotebookReviewDestinationModel
    @ObservedObject var session: BuiltInReviewSession

    private var isDisabled: Bool {
        session.draft != nil || session.batchDraft != nil || session.noteTypeDraft != nil
            || session.noteDraft != nil || session.isMutating
    }

    var body: some View {
        Picker(String(localized: "Review", table: "ReviewCards"), selection: $navigation.target) {
            Text("Lingrove").tag(NotebookReviewDestinationModel.Target.lingrove)
            Text("Anki").tag(NotebookReviewDestinationModel.Target.anki)
        }
        .pickerStyle(.segmented)
        .frame(width: 170)
        .labelsHidden()
        .disabled(isDisabled)
        .accessibilityIdentifier("review.destination")
    }
}

/// Anki owns its catalog, profile and external scheduling. This page exposes only verified
/// catalog facts and actual controller actions, so Lingrove never invents Anki due counts.
struct AnkiReviewDestinationView: View {
    @ObservedObject var controller: AnkiReviewController
    @ObservedObject private var settings: AnkiReviewSettings
    @State private var opening = false
    @State private var failure: String?

    init(controller: AnkiReviewController) {
        self.controller = controller
        settings = controller.settings
    }

    var body: some View {
        ScrollView {
            LingroveReadableContentLayout(maxWidth: lingroveReadableFormMaxWidth, horizontalPadding: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(controller.catalog != nil ? Color.green.opacity(0.14) : Color.primary.opacity(0.06))
                                    .frame(width: 44, height: 44)
                                Image(systemName: controller.catalog != nil ? "checkmark.seal.fill" : "arrow.up.forward.app")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(controller.catalog != nil ? .green : .secondary)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Anki")
                                    .font(.title3.weight(.bold))
                                Text(controller.catalog != nil
                                    ? String(localized: "Anki profile", table: "Vocabulary") + ": " + (controller.catalog?.profile ?? "")
                                    : BuiltInReviewCopy.text("anki.notConnected"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if controller.testing || opening {
                                ProgressView().controlSize(.small)
                            }
                        }

                        Divider().opacity(0.5)

                        if let catalog = controller.catalog {
                            VStack(alignment: .leading, spacing: 14) {
                                LabeledContent(String(localized: "Anki profile", table: "Vocabulary"), value: catalog.profile)
                                    .font(.subheadline)
                                Picker(String(localized: "Deck", table: "Vocabulary"), selection: $settings.deck) {
                                    ForEach(Array(Set(catalog.decks + [settings.deck])).sorted(), id: \.self) { Text($0).tag($0) }
                                }
                                .accessibilityIdentifier("review.anki.deck")
                            }
                        }

                        HStack(spacing: 10) {
                            if controller.catalog != nil {
                                Button {
                                    guard !opening else { return }
                                    opening = true
                                    Task { defer { opening = false }; failure = await controller.reviewDeck() }
                                } label: {
                                    Label(String(localized: "Review in Anki", table: "Vocabulary"), systemImage: "play.fill")
                                        .padding(.horizontal, 4)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .accessibilityIdentifier("review.anki.open")
                            }

                            Button(String(localized: "Test connection", table: "Vocabulary")) {
                                Task { await controller.testConnection(model: ReviewLayoutPolicy.model) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityIdentifier("review.anki.connect")

                            Button(String(localized: "Review settings", table: "Vocabulary")) { controller.configure?() }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .accessibilityIdentifier("review.anki.configure")
                        }

                        if let message = failure ?? controller.connectionMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                                Text(message)
                                    .font(.callout)
                                    .foregroundStyle(controller.catalog == nil ? .secondary : .primary)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("review.anki.status")
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(24)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45))
                    )
                }
                .padding(.vertical, 28)
            }
        }
        .disabled(controller.testing || opening || controller.sendingSenseID != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: settings.address) { _, _ in controller.invalidateConnection() }
        .accessibilityIdentifier("review.anki")
    }
}
