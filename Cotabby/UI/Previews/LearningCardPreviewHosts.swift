#if DEBUG
import SwiftUI

/// A small design-workbench toolbar surrounds the real card. The toolbar belongs only to Canvas;
/// product controls and view layout remain in the existing InlineFeatures files being edited.
struct LearningCardPreview: View {
    enum Kind: Equatable { case sentence, dictionary, explanation }
    let kind: Kind
    let dictionaryPage: Bool
    @State private var state: LearningCardPreviewState
    @State private var expanded: Bool

    init(kind: Kind, state: LearningCardPreviewState = .ready, expanded: Bool = false, dictionaryPage: Bool = false) {
        self.kind = kind
        self.dictionaryPage = dictionaryPage
        _state = State(initialValue: state)
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 16) {
                Picker("状态", selection: $state) {
                    ForEach(LearningCardPreviewState.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 210)
                if kind == .sentence { Toggle("展开", isOn: $expanded).toggleStyle(.switch) }
                Spacer()
            }.controlSize(.small)
            LearningCardPreviewSurface(kind: kind, state: state, expanded: $expanded, dictionaryPage: dictionaryPage)
                .id(state)
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 620, height: 680, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    }
}

/// The surface owns one fixture graph for this scenario. Changing the scenario remounts it so
/// pending requests cannot leak into the next preview; ordinary button presses retain the graph.
private struct LearningCardPreviewSurface: View {
    let kind: LearningCardPreview.Kind
    let state: LearningCardPreviewState
    @Binding var expanded: Bool
    let dictionaryPage: Bool
    @StateObject private var model: LearningCardPreviewModel
    @State private var visible = true
    @State private var status = ""
    @State private var showingLookup = false

    init(kind: LearningCardPreview.Kind, state: LearningCardPreviewState,
         expanded: Binding<Bool>, dictionaryPage: Bool) {
        self.kind = kind; self.state = state; self.dictionaryPage = dictionaryPage
        _expanded = expanded
        _model = StateObject(wrappedValue: LearningCardPreviewModel(state: state))
    }

    var body: some View {
        VStack(spacing: 12) {
            if showingLookup {
                Button("返回翻译预览") { showingLookup = false }.buttonStyle(.link)
            }
            if visible {
                switch showingLookup ? .dictionary : kind {
                case .sentence:
                    LearningSentenceCard(presentation: LearningCardPreviewModel.sentence(state: state, expanded: expanded),
                        explanation: model.explanation, replace: { status = "已触发替换" },
                        expand: { expanded.toggle() }, dismiss: hide,
                        lookupText: { anchor, _ in
                            model.dictionary.open(.word(anchor.word), documentID: HomeLearningDemoFixtures.documentID,
                                language: .english, speechContext: HomeLearningDemoFixtures.translation)
                            showingLookup = true
                        },
                        lookupUnit: { anchor, _ in
                            model.dictionary.open(anchor.unit, documentID: HomeLearningDemoFixtures.documentID,
                                language: .english, speechContext: HomeLearningDemoFixtures.translation)
                            showingLookup = true
                        },
                        speech: model.speech, vocabulary: model.store, sizeChanged: { _ in })
                case .dictionary:
                    LearningDictionaryCard(session: model.dictionary, close: hide, sizeChanged: { _ in },
                        lookup: { query, _ in model.dictionary.followReference(query) },
                        speech: model.speech, vocabulary: model.store)
                case .explanation:
                    ScrollView {
                        LearningExplanationView(session: model.explanation, presentation: .contextual,
                            context: HomeLearningDemoFixtures.capture.example)
                    }
                    .frame(width: 340, height: state == .longText ? 440 : 280)
                    .padding(12).learningCardChrome(cornerRadius: 12)
                }
            } else {
                Button("重新显示卡片") {
                    visible = true
                    model.resume()
                    Task { await model.prepare(state: state, dictionaryPage: dictionaryPage) }
                }
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .task {
            // Canvas can keep this StateObject while hiding and remounting its surface. Only
            // the new, uncancelled appearance task may reopen the graph stopped on disappearance.
            guard !Task.isCancelled else { return }
            model.resume()
            await model.prepare(state: state, dictionaryPage: dictionaryPage)
        }
        .onDisappear { model.stop() }
    }

    private func hide() {
        visible = false
        model.stop()
    }
}
#endif
