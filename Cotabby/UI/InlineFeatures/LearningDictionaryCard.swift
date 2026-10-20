import AppKit
import SwiftUI

/// Presents every dictionary source inside the app-owned detail window. The session owns source
/// selection and captured examples; shared speech/favorite controls keep their existing owners.
/// Only the content body scrolls, leaving the source selector and primary actions reachable.
struct LearningDictionaryCard: View {
    @ObservedObject var session: LearningDictionarySession
    let close: () -> Void
    let sizeChanged: (CGSize) -> Void
    let lookup: (String, NSButton) -> Void
    var speech: LearningSpeechController?
    var vocabulary: VocabularyStore?
    var lookupWord: ((LearningDictionaryWord, NSButton) -> Void)?
    var popupWindows: LearningPopupWindowRegistry?
    @State private var viewport = LearningDictionaryViewport()
    @State private var measuredHTMLRequest: UUID?
    private var showsExplanation: Bool { session.page == .contextual }
    var body: some View {
        // Geometry transforms may execute outside MainActor. Capture immutable values rather
        // than reading the observable session from that transform.
        let query = session.query + (showsExplanation ? ":contextual" : ":dictionary"), requestID = session.requestIdentity
        let resolved = !showsExplanation && viewportCanLock
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if showsExplanation {
                    Text(explanationLanguageLabel).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else { LearningDictionarySourcePicker(session: session, popupWindows: popupWindows) }
                if session.explanation.service != nil {
                    LearningExplanationButton(session: session.explanation, configure: configureExplanation)
                }
                if let vocabulary, let capture = session.favoriteCapture {
                    VocabularyFavoriteButton(store: vocabulary, capture: capture)
                        .id(session.query + ":" + String(session.selectedWord?.range.location ?? -1))
                }
                if let speech, let request = speechRequest {
                    LearningSpeechButton(speech: speech, request: request,
                        playLabel: speechLabels.play, stopLabel: speechLabels.stop)
                }
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .help(String(localized: "Close dictionary · Esc", table: "Learning",
                        comment: "Tooltip for closing the learning dictionary panel with Escape."))
            }.frame(minHeight: 20)
            if session.isRelatedEntry {
                Button(String(localized: "← Back to the full expression", table: "Learning",
                    comment: "Returns from a word entry to the dictionary page for the whole expression."),
                    action: session.returnToExpression).buttonStyle(.plain).font(.caption)
            }
            Text(session.title).font(.title3.weight(.semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Text(showsExplanation ? " " : (session.definitionLanguageLabel ?? " "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityHidden(showsExplanation || session.definitionLanguageLabel == nil)
            if session.query != session.title {
                Text(String(localized: "Dictionary form: \(session.query)", table: "Learning",
                    comment: "Shows the normalized dictionary lookup form; the term is supplied by the learning content."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if session.explanation.service != nil {
                Picker(String(localized: "Dictionary", table: "Vocabulary"), selection: Binding(
                    get: { showsExplanation }, set: selectPage)) {
                    Text(session.explanation.input?.contextKind == LearningExplanationContext.none
                        ? String(localized: "Meaning", table: "Vocabulary")
                        : String(localized: "Contextual meaning", table: "Learning")).tag(true)
                    Text(String(localized: "Dictionary", table: "Vocabulary")).tag(false)
                }.pickerStyle(.segmented).labelsHidden()

            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if showsExplanation {
                        if let vocabulary, let capture = session.favoriteCapture {
                            LearningCapturedExplanationView(session: session.explanation, store: vocabulary,
                                capture: capture, configure: configureExplanation,
                                presentation: .contextual, context: session.contextExample)
                        } else { LearningExplanationView(session: session.explanation, configure: configureExplanation,
                            presentation: .contextual, context: session.contextExample) }
                    } else {
                        LearningDictionaryDefinitionView(session: session, measured: { measuredHTMLRequest = $0 })
                            .id(session.requestIdentity)
                    }
                    if let unit = session.unit, unit.kind != .word, !session.isRelatedEntry {
                        componentWords(unit)
                    }
                    if !showsExplanation, let example = session.contextExample { contextExample(example) }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: DictionaryBodyMeasurement.self) {
                        .init(height: $0.size.height, query: query, requestID: requestID, resolved: resolved)
                    } action: { measurement in
                        guard measurement.requestID == session.requestIdentity else { return }
                        viewport.measure(measurement.height, query: measurement.query, resolved: measurement.resolved)
                    }
            }
            .frame(height: viewport.height(for: query))
            .id(session.query)
            Group {
                if showsExplanation {
                    Text(session.explanation.record?.model ?? String(localized: "AI explanation", table: "Learning"))
                        .foregroundStyle(.secondary)
                } else { LearningDictionaryAttribution(session: session).foregroundStyle(.secondary) }
            }.font(.caption2).lineLimit(2).frame(height: 26, alignment: .topLeading)
        }
        .padding(12).frame(width: 340, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: LearningCardSizePreference.self, value: geometry.size)
        })
        .onPreferenceChange(LearningCardSizePreference.self, perform: sizeChanged)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: session.query) { oldQuery, newQuery in
            measuredHTMLRequest = nil
            guard oldQuery != newQuery, let documentID = session.documentID else { return }
            speech?.stop(target: SpeechTarget(ownerID: documentID, itemID: "detail.\(oldQuery)"))
        }
    }

    private var explanationLanguageLabel: String {
        let source = session.contentLanguage.compactLabel
        guard let language = session.explanation.service?.language, language != session.contentLanguage else { return source }
        return String(localized: "\(source) → \(language.compactLabel)", table: "Learning")
    }

    private func configureExplanation() {
        (session.explanation.service as? LearningExplanationService)?.configure?()
    }

    private func selectPage(_ contextual: Bool) {
        let targetIdentity = session.targetIdentity
        // The AppKit segmented control can write its binding while SwiftUI is updating it.
        // Defer observable session mutations to the next actor turn, retaining this target's
        // lifetime so a queued action cannot affect a later occurrence of the same word.
        Task { @MainActor in
            session.selectPage(contextual ? .contextual : .dictionary, targetIdentity: targetIdentity)
        }
    }

    private var viewportCanLock: Bool {
        switch session.content {
        case .result(.article(let article)): article.html.isEmpty || measuredHTMLRequest == session.requestIdentity
        case .result(.entries), .result(.systemText): true
        case .loading, .failed, .result(.notFound), .result(.website): false
        }
    }

    private func componentWords(_ unit: LearningUnit) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String(localized: "Words in this expression", table: "Learning"))
                .font(.caption).foregroundStyle(.secondary)
            LearningTextFlowLayout(spacing: 5, rowSpacing: 5, rightToLeft: session.contentLanguage == .arabic) {
                ForEach(Array(unit.words.enumerated()), id: \.offset) { _, word in
                    LearningDictionaryButton(word: word.text) { term, button in
                        if let lookupWord { lookupWord(word, button) } else { lookup(term, button) }
                    }
                }
            }.environment(\.layoutDirection, .leftToRight)
        }
    }

    private func contextExample(_ example: VocabularyExample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(String(localized: "This example", table: "Learning")).font(.caption).foregroundStyle(.secondary)
            Text(highlighted(example)).font(.callout)
            if !example.translation.isEmpty { Text(example.translation).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func highlighted(_ example: VocabularyExample) -> AttributedString {
        var result = AttributedString(example.text)
        for value in example.ranges {
            guard VocabularyPolicy.valid(value.nsRange, in: example.text), let range = Range(value.nsRange, in: example.text),
                  let converted = Range(range, in: result) else { continue }
            result[converted].foregroundColor = .accentColor
            result[converted].backgroundColor = Color.accentColor.opacity(0.12)
        }
        return result
    }

    private var speechRequest: SpeechRequest? {
        guard let unit = session.unit, let documentID = session.documentID else { return nil }
        let text: String?
        if let reference = session.referenceQuery {
            text = SpeechTextPolicy.sanitizedText(reference)
        } else if let selectedWord = session.selectedWord {
            text = SpeechTextPolicy.sanitizedText(selectedWord.text)
        } else {
            text = SpeechTextPolicy.spokenText(for: unit)
        }
        guard let text else { return nil }
        return SpeechRequest(
            target: SpeechTarget(ownerID: documentID, itemID: "detail.\(session.query)"),
            text: text, language: session.contentLanguage,
            context: session.speechContext ?? SpeechTextPolicy.spokenText(for: unit))
    }

    private var speechLabels: (play: String, stop: String) {
        if session.selectedWord != nil || session.unit?.kind == .word {
            return (
                String(localized: "Play word aloud", table: "Learning"),
                String(localized: "Stop speaking word", table: "Learning"))
        }
        return (
            String(localized: "Play expression aloud", table: "Learning"),
            String(localized: "Stop speaking expression", table: "Learning"))
    }

}

private nonisolated struct DictionaryBodyMeasurement: Equatable {
    let height: CGFloat
    let query: String
    let requestID: UUID
    let resolved: Bool
}
