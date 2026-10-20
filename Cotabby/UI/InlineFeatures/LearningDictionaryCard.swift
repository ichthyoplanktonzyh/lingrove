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
    @State private var definitionHeight: CGFloat = 60
    @State private var htmlHeight: CGFloat = 120
    @State private var showsSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sourceSelector
                Spacer()
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
            }
            if session.isRelatedEntry {
                Button(String(localized: "← Back to the full expression", table: "Learning",
                    comment: "Returns from a word entry to the dictionary page for the whole expression."),
                    action: session.returnToExpression).buttonStyle(.plain).font(.caption)
            }
            Text(session.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if session.query != session.title {
                Text(String(localized: "Dictionary form: \(session.query)", table: "Learning",
                    comment: "Shows the normalized dictionary lookup form; the term is supplied by the learning content."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    definition
                    if let unit = session.unit, unit.kind != .word, !session.isRelatedEntry {
                        componentWords(unit)
                    }
                    if let example = session.contextExample { contextExample(example) }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        // Read content directly so a ScrollView cannot swallow the measurement
                        // while the same host changes from a loaded phrase entry to a miss.
                        if height.isFinite, height > 0 { definitionHeight = height }
                    }
            }
            .frame(height: min(max(definitionHeight, 24), 300))
            .id(session.query)
            if case .result(.entries) = session.content, session.selectedSource == .bundled,
               let url = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/") {
                // Attribution stays outside the scroll viewport, including for long entries.
                Link(String(localized: "Wiktionary contributors / Kaikki · CC BY-SA 4.0", table: "Learning",
                    comment: "Attribution and license for the bundled Wiktionary-derived expression dictionary entries."),
                    destination: url)
                    .font(.caption2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).frame(width: 340, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: LearningCardSizePreference.self, value: geometry.size)
        })
        .onPreferenceChange(LearningCardSizePreference.self, perform: sizeChanged)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: session.query) { oldQuery, newQuery in
            showsSources = false
            guard oldQuery != newQuery, let documentID = session.documentID else { return }
            speech?.stop(target: SpeechTarget(ownerID: documentID, itemID: "detail.\(oldQuery)"))
        }
    }

    private var sourceSelector: some View {
        Button { showsSources.toggle() } label: {
            HStack(spacing: 4) {
                Text(session.sourceName).lineLimit(1)
                if session.availableSources.count > 1 { Image(systemName: "chevron.down").font(.caption2) }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(session.availableSources.count < 2)
        .accessibilityLabel(String(localized: "Dictionary sources", table: "Learning"))
        .accessibilityValue(session.sourceName)
        // Match the favorite action's existing SwiftUI popover boundary. Its child window is
        // recognized by the panel's outside-click policy, so mouse-down cannot retire the card.
        .popover(isPresented: $showsSources) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.availableSources) { source in
                        Button {
                            showsSources = false
                            session.selectSource(source)
                        } label: {
                            HStack {
                                Text(session.name(for: source)).lineLimit(2)
                                Spacer()
                                if source == session.selectedSource { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }.buttonStyle(.plain).padding(14)
            }.frame(width: 240, height: min(320, CGFloat(session.availableSources.count) * 40 + 28))
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

    @ViewBuilder private var definition: some View {
        switch session.content {
        case .loading:
            ProgressView(String(localized: "Looking up…", table: "Learning",
                comment: "Progress label while a dictionary lookup is running.")).font(.caption)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.secondary)
        case .result(.notFound):
            Text(session.selectedWord == nil && session.unit?.kind != .word
                ? String(localized: "No dictionary entry was found for this expression. Select a word below to look it up.",
                    table: "Learning", comment: "Empty state when the complete expression has no dictionary entry.")
                : String(localized: "No definition for this word was found in the available dictionaries.",
                    table: "Learning", comment: "Empty state when the configured dictionaries have no entry for a word."))
                .font(.callout).foregroundStyle(.secondary)
        case .result(.systemText(let text)):
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .result(.article(let article)):
            DictionaryHTMLView(article: article, loadResource: session.resourceLoader(for: article.resourceLibrary),
                               reference: session.followReference, height: $htmlHeight)
                .frame(height: htmlHeight)
                // Replacing the document also revokes its custom resource origin and tasks.
                .id(session.requestIdentity)
        case .result(.website(let url)):
            Link(destination: url) {
                Label(String(localized: "Open lookup website", table: "Learning"), systemImage: "arrow.up.right.square")
            }.font(.callout)
        case .result(.entries(let entries)):
            VStack(alignment: .leading, spacing: 14) {
                ForEach(entries, id: \.id) { entry in
                    if entry.headword != session.query { Text(entry.headword).font(.headline) }
                    if let phonetics = entry.phonetics, !phonetics.isEmpty {
                        Text(phonetics.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(entry.senses.enumerated()), id: \.offset) { _, sense in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(sense.partOfSpeech + (sense.labels.isEmpty ? "" : " · " + sense.labels.joined(separator: ", ")))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(sense.definitions.enumerated()), id: \.offset) { index, text in
                                Text(verbatim: "\(index + 1). \(text)").font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    ForEach(entry.examples ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    if let url = DictionaryLinkPolicy.externalURL(entry.sourceURL) {
                        Link(entry.sourceName ?? "Wiktionary / Kaikki", destination: url).font(.caption2)
                    }
                    if let licenseURL = entry.licenseURL, let url = DictionaryLinkPolicy.externalURL(licenseURL) {
                        Link(entry.licenseName ?? String(localized: "License", table: "Learning"), destination: url).font(.caption2)
                    } else if let name = entry.licenseName, !name.isEmpty {
                        Text(name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
