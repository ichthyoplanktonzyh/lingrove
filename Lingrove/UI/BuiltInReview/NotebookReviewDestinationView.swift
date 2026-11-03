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
            HStack {
                Text(String(localized: "Review", table: "ReviewCards")).font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Picker(String(localized: "Review", table: "ReviewCards"), selection: $navigation.target) {
                    Text("Lingrove").tag(NotebookReviewDestinationModel.Target.lingrove)
                    Text("Anki").tag(NotebookReviewDestinationModel.Target.anki)
                }.pickerStyle(.segmented).frame(width: 260).labelsHidden()
                    .disabled(session.draft != nil || session.batchDraft != nil || session.isMutating)
                    .accessibilityIdentifier("review.destination")
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            if navigation.target == .lingrove {
                BuiltInReviewWindowView(session: session)
            } else if let anki {
                AnkiReviewDestinationView(controller: anki)
            } else {
                ContentUnavailableView(BuiltInReviewCopy.text("anki.unavailable"), systemImage: "rectangle.stack")
            }
        }.background(Color(nsColor: .windowBackgroundColor))
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
                VStack(alignment: .leading, spacing: 24) {
                    Label("Anki", systemImage: "arrow.up.forward.app").font(.title2.weight(.semibold))
                    VStack(alignment: .leading, spacing: 14) {
                        if let catalog = controller.catalog {
                            LabeledContent(String(localized: "Anki profile", table: "Vocabulary"), value: catalog.profile)
                            Picker(String(localized: "Deck", table: "Vocabulary"), selection: $settings.deck) {
                                ForEach(Array(Set(catalog.decks + [settings.deck])).sorted(), id: \.self) { Text($0).tag($0) }
                            }.accessibilityIdentifier("review.anki.deck")
                            Button(String(localized: "Review in Anki", table: "Vocabulary")) {
                                guard !opening else { return }
                                opening = true
                                Task { defer { opening = false }; failure = await controller.reviewDeck() }
                            }.buttonStyle(.borderedProminent).accessibilityIdentifier("review.anki.open")
                        } else {
                            Text(BuiltInReviewCopy.text("anki.notConnected")).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(String(localized: "Test connection", table: "Vocabulary")) {
                                Task { await controller.testConnection(model: ReviewLayoutPolicy.model) }
                            }.accessibilityIdentifier("review.anki.connect")
                            Button(String(localized: "Review settings", table: "Vocabulary")) { controller.configure?() }
                                .accessibilityIdentifier("review.anki.configure")
                            if controller.testing || opening { ProgressView().controlSize(.small) }
                        }.buttonStyle(.bordered)
                        if let message = failure ?? controller.connectionMessage {
                            Text(message).font(.callout).foregroundStyle(controller.catalog == nil ? .secondary : .primary)
                                .textSelection(.enabled).accessibilityIdentifier("review.anki.status")
                        }
                    }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }.padding(.vertical, 32)
            }
        }.disabled(controller.testing || opening || controller.sendingSenseID != nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: settings.address) { _, _ in controller.invalidateConnection() }
            .accessibilityIdentifier("review.anki")
    }
}
