import SwiftUI

/// Home and explicit guide examples share one interactive scene player. Its model lives while mounted;
/// real cards are embedded at their normal size, with explanations outside their action rows.
struct HomeLearningShowcase: View {
    @StateObject private var model = HomeLearningDemoModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var readingSettings: LanguageLearningSettings?
    var startingScene: HomeLearningScene?
    var autoplayOnHover = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                scenePicker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                scenePicker.pickerStyle(.menu)
            }.accessibilityIdentifier("homeLearningScenePicker")
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "Interactive demo · sample content", table: "Learning"))
                        .font(.caption).foregroundStyle(.secondary)
                    playerControls
                    Text(model.action.explanation).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("homeLearningStepDescription")
                    Divider()
                    scene
                        .frame(maxWidth: .infinity, minHeight: 330, maxHeight: 330, alignment: .top)
                        .environment(\.learningInteraction, model.interact)
                        .environment(\.learningActionEmphasis, model.action.emphasis)
                        .environment(\.learningFavoriteMenu, Binding(get: { model.favoriteMenuPresented }, set: {
                            guard model.favoriteMenuPresented != $0 else { return }
                            model.interact(); model.favoriteMenuPresented = $0
                        }))
                        .environment(\.learningDictionaryMenu, Binding(get: { model.dictionaryMenuPresented }, set: {
                            guard model.dictionaryMenuPresented != $0 else { return }
                            model.interact(); model.dictionaryMenuPresented = $0
                        }))
                        .simultaneousGesture(TapGesture().onEnded { model.interact() })
                }.padding(8)
            }
            .onHover { if autoplayOnHover { model.hover($0, reduceMotion: reduceMotion) } }
        }
        .task(id: startingScene) {
            if let startingScene { model.select(startingScene) }
            await model.prepare()
        }
        .onDisappear { model.stop() }
        .onChange(of: reduceMotion) { _, reduced in if reduced { model.pause() } }
        .sheet(isPresented: $model.presentsNotebook) {
            VStack(spacing: 0) {
                HStack {
                    Text(String(localized: "Vocabulary", table: "Vocabulary")).font(.headline)
                    Spacer()
                    Button(String(localized: "Close", table: "Learning")) { model.presentsNotebook = false }
                        .keyboardShortcut(.cancelAction)
                }.padding()
                VocabularyNotebookView(store: model.store, speech: model.speech, learning: model.notebook,
                    review: model.review, preferences: model.preferences)
            }.frame(width: 920, height: 640)
        }
        .sheet(isPresented: Binding(get: { model.bookSelection != nil && model.scene == .vocabulary },
            set: { if !$0 { model.bookSelection = nil } })) {
            HomeLearningSenseDetail(model: model, store: model.store)
        }
        .accessibilityIdentifier("homeLearningWalkthrough")
    }

    private var scenePicker: some View {
        Picker(String(localized: "Language Learning", table: "Learning"), selection: Binding(
            get: { model.scene }, set: { model.select($0) })) {
            ForEach(HomeLearningScene.allCases) { Text($0.title).tag($0) }
        }.labelsHidden()
    }

    private var playerControls: some View {
        HStack(spacing: 10) {
            Text(model.action.title).font(.headline).lineLimit(1).help(model.action.title)
            Spacer(minLength: 4)
            Menu {
                ForEach(model.scene.steps.indices, id: \.self) { index in
                    Button(model.scene.steps[index].title) { model.go(to: index) }
                }
            } label: {
                Text(verbatim: "\(model.step + 1) / \(model.scene.steps.count)").monospacedDigit()
            }.menuStyle(.borderlessButton).fixedSize().help(String(localized: "Demo steps", table: "Learning"))
            control("chevron.left", title: String(localized: "Previous step", table: "Learning"), action: model.previous)
                .disabled(model.step == 0)
            control(model.isPlaying ? "pause.fill" : "play.fill",
                title: model.isPlaying ? String(localized: "Pause demo", table: "Learning")
                    : String(localized: "Play demo", table: "Learning")) {
                    if model.isPlaying { model.interact() } else { model.play() }
                }.disabled(reduceMotion)
            control("chevron.right", title: String(localized: "Next step", table: "Learning"), action: model.next)
                .disabled(model.step == model.scene.steps.count - 1)
            control("arrow.counterclockwise", title: String(localized: "Replay demo", table: "Learning")) {
                if reduceMotion { model.select(model.scene) } else { model.replay() }
            }
        }
    }

    private func control(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
            .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }

    @ViewBuilder private var scene: some View {
        switch model.scene {
        case .expression:
            ExpressionAssistDemoScene(action: model.action,
                settings: (readingSettings ?? model.readingSettings).expressionAssist) {
                model.go(to: 3)
            }
        case .vocabulary: HomeLearningNotebookScene(model: model, store: model.store)
        case .anki: HomeLearningAnkiScene(model: model)
        default:
            ScrollView { VStack(spacing: 14) {
                if model.scene == .reading {
                    HomeLearningReadingScene(model: model, settings: readingSettings ?? model.readingSettings)
                } else {
                    Text(model.editorText).font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading).padding(12)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                if model.lookupVisible {
                    LearningDictionaryCard(session: model.dictionary, close: model.dismissCard,
                        sizeChanged: { _ in }, lookup: { term, _ in model.interact(); model.dictionary.followReference(term) },
                        speech: model.speech, vocabulary: model.store,
                        lookupWord: { word, _ in model.interact(); model.dictionary.select(word) })
                } else if model.cardVisible {
                    LearningSentenceCard(presentation: model.presentation, explanation: model.explanation,
                        replace: model.scene == .reading ? nil : { model.replace() },
                        expand: { model.interact(); model.expanded.toggle() }, dismiss: model.dismissCard,
                        lookupUnit: { anchor, _ in model.openLookup(anchor.unit) }, speech: model.speech,
                        vocabulary: model.store, sizeChanged: { _ in })
                }
            }.frame(maxWidth: .infinity, alignment: .top).padding(4) }
        }
    }
}

/// Acquisition stays inside a small example reading surface. The same production selection
/// button is used; current user key labels are read from their existing shortcut settings.
private struct HomeLearningReadingScene: View {
    @ObservedObject var model: HomeLearningDemoModel
    @ObservedObject var settings: LanguageLearningSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(LearningReadingSource.allCases, id: \.rawValue) { source in
                    Button(source.title) { model.useReadingSource(source) }
                        .buttonStyle(.bordered).tint(model.readingSource == source ? Color.accentColor : Color.secondary)
                        .font(.caption)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Text(readingText).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if model.readingSource == .selection {
                    LearningSelectionButton { model.showReadingTranslation() }
                }
                let binding = settings.readingBinding(model.readingSource)
                if binding.key != .max {
                    Button(binding.label) { model.showReadingTranslation() }
                        .font(.caption.monospaced()).buttonStyle(.bordered).help(model.readingSource.title)
                } else if model.readingSource != .selection {
                    Button(model.readingSource.title) { model.showReadingTranslation() }.buttonStyle(.bordered)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if model.readingSource == .screenshot {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .allowsHitTesting(false)
                }
            }
        }
    }
    private var readingText: AttributedString {
        var text = AttributedString(model.readingSource == .screenshot
            ? HomeLearningDemoFixtures.ocrSource : HomeLearningDemoFixtures.context)
        let target = model.readingSource == .pointer ? "posted" : HomeLearningDemoFixtures.translation
        if let range = text.range(of: target) { text[range].backgroundColor = Color.accentColor.opacity(0.16) }
        return text
    }
}

/// The compact browser borrows real list labels and the actual native graph canvas. A sense
/// opens the real detail view; users can also open the complete notebook with its usual toolbar.
private struct HomeLearningNotebookScene: View {
    @ObservedObject var model: HomeLearningDemoModel
    @ObservedObject var store: VocabularyStore
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Picker(String(localized: "Browse vocabulary", table: "Vocabulary"), selection: Binding(get: { model.bookMode }, set: {
                    guard model.bookMode != $0 else { return }
                    model.interact(); model.bookMode = $0
                })) {
                    Text(String(localized: "List", table: "Vocabulary")).tag("list")
                    Text(String(localized: "Graph", table: "Vocabulary")).tag("graph")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                Spacer()
                Button(String(localized: "Open vocabulary", table: "Vocabulary")) {
                    model.interact(); model.bookSelection = nil; model.presentsNotebook = true
                }.buttonStyle(.borderless)
            }
            if model.bookMode == "graph" {
                VocabularyGraphView(entries: store.entries, query: "", selection: model.bookSelection,
                    presentation: model.graph, select: model.selectSense, interactionBegan: model.interact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.entries) { entry in
                        DisclosureGroup(isExpanded: Binding(get: { model.expandedHeadwords.contains(entry.id) }, set: { value in
                            model.interact()
                            if value { model.expandedHeadwords.insert(entry.id) } else { model.expandedHeadwords.remove(entry.id) }
                        })) {
                            ForEach(entry.senses) { sense in
                                Button { model.selectSense(.init(entryID: entry.id, senseID: sense.id)) } label: {
                                    VocabularySenseSummary(sense: sense).frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).padding(.vertical, 4)
                            }
                        } label: { Text(entry.expression).font(.headline) }
                    }
                }.listStyle(.inset)
            }
        }
        .onChange(of: model.bookMode) { _, _ in model.bookSelection = nil }
    }
}

/// The normal sense detail and editor are reused at a readable width, rather than scaling an
/// entire notebook window into a thumbnail. The parent owns dismissal and the selected sense.
private struct HomeLearningSenseDetail: View {
    @ObservedObject var model: HomeLearningDemoModel
    @ObservedObject var store: VocabularyStore
    @State private var editing = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Vocabulary", table: "Vocabulary")).font(.headline)
                Spacer()
                Button(String(localized: "Close", table: "Learning")) { model.bookSelection = nil }.keyboardShortcut(.cancelAction)
            }.padding()
            if let entry = model.selectedEntry, let sense = model.selectedSense {
                VocabularyEntryDetail(entry: entry, sense: sense, speech: model.speech, store: model.store,
                    learning: model.notebook, review: model.review, edit: { editing = true },
                    delete: { Task {
                        if await store.removeSense(entryID: entry.id, senseID: sense.id) { model.bookSelection = nil }
                    } },
                    newSense: { Task {
                        if let selection = await store.createSense(entryID: entry.id) {
                            model.selectSense(.init(entryID: entry.id, senseID: selection))
                        }
                    } },
                    merge: { target in Task {
                        if await store.mergeSenses(entryID: entry.id, source: sense.id, target: target) {
                            model.selectSense(.init(entryID: entry.id, senseID: target))
                        }
                    } })
                    .sheet(isPresented: $editing) { VocabularyEntryEditor(entry: entry, store: model.store, senseID: sense.id) }
            }
        }.frame(width: 580, height: 620)
    }
}

/// This is the application's real flexible card editor and HTML preview, not a mock front/back
/// picture. Its draft can be changed, saved and sent through the normal local sample transport.
private struct HomeLearningAnkiScene: View {
    @ObservedObject var model: HomeLearningDemoModel
    var body: some View {
        Group {
            if let session = model.ankiSession {
                HomeLearningAnkiEditor(model: model, session: session, store: model.store)
            } else { ProgressView() }
        }.task { await model.prepareReview() }
    }
}

/// Observe the draft here as well as in the shared editor: completing Add changes the footer to
/// Update and enables the review entry even though the surrounding Home model did not change.
private struct HomeLearningAnkiEditor: View {
    @ObservedObject var model: HomeLearningDemoModel
    @ObservedObject var session: AnkiReviewSession
    @ObservedObject var store: VocabularyStore
    @State private var operation: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 10) {
            Picker(String(localized: "Card side", table: "Vocabulary"), selection: Binding(get: { model.previewBack }, set: {
                model.interact(); model.previewBack = $0
            })) {
                Text(String(localized: "Front", table: "Vocabulary")).tag(false)
                Text(String(localized: "Back", table: "Vocabulary")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            Form { VocabularyReviewLayoutEditor(session: session, store: store, operation: $operation,
                hostedSide: $model.previewBack, previewFirst: true) }.formStyle(.grouped)
            HStack {
                Button(session.binding?.noteID == nil ? String(localized: "Add to Anki", table: "Vocabulary")
                    : String(localized: "Update Anki", table: "Vocabulary")) {
                    operation = Task { defer { operation = nil }; await model.sendCard() }
                }.disabled(operation != nil || session.busy || session.validationMessage != nil)
                Button(String(localized: "Review in Anki", table: "Vocabulary")) {
                    operation = Task { defer { operation = nil }; await model.reviewCard() }
                }.disabled(operation != nil || session.binding?.noteID == nil)
            }
            if let message = model.reviewFailure ?? session.message ?? session.validationMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            if model.ankiDestinationShown {
                Label(String(localized: "Review destination: Anki", table: "Learning"), systemImage: "arrow.up.forward.app")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.onDisappear { operation?.cancel() }
    }
}
