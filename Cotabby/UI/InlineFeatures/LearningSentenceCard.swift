import AppKit
import SwiftUI

/// Shows the sentence pair without dictionary text or duplicate mapping rows. The shared detail
/// state supplies selection borders; the app-owned panel receives clicks and owns lookup I/O.
struct LearningSentenceCard: View {
    let presentation: LearningSentencePresentation
    @ObservedObject var detailState: LearningDetailState
    var explanation: LearningExplanationSession?
    var replace: (() -> Void)?
    let inspect: (Int) -> Void
    let expand: () -> Void
    let dismiss: () -> Void
    var lookup: (String, NSButton) -> Void = { _, _ in }
    var lookupText: (LearningDictionaryTextAnchor, NSTextView) -> Void = { _, _ in }
    var lookupUnit: ((LearningUnitTextAnchor, NSTextView) -> Void)?
    var speech: LearningSpeechController?
    var vocabulary: VocabularyStore?
    let sizeChanged: (CGSize) -> Void
    // Begin with the sentence pair's short layout; longer content measures itself below.
    // The former instruction-sized fallback leaves a blank block after the guide text is removed.
    @State private var detailsHeight: CGFloat = 100
    @State private var compactTranslationHeight: CGFloat = 20
    @State private var expandedWidth: CGFloat = 320
    @State private var copyActionsWidth: CGFloat = 0

    /// Width follows the sentence pair, not every streamed token or caret movement. This small
    /// value is the card's measurement identity: a new source/document or completed translation
    /// asks for one new measurement; partial translations wrap within the current viewport.
    private struct ExpandedSizingContent: Equatable {
        let documentID: UUID
        let source: String
        let translation: String?
        let isExpanded: Bool
    }

    private var expandedSizingContent: ExpandedSizingContent {
        ExpandedSizingContent(documentID: presentation.id, source: presentation.source,
            translation: presentation.isTranslating ? nil : presentation.translation,
            isExpanded: presentation.isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !presentation.isError, let reason = presentation.replacementUnavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if presentation.isError {
                Text(presentation.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            } else if presentation.isExpanded {
                details
            } else {
                if let previous = presentation.previousTranslation {
                    Text(previous).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !presentation.translation.isEmpty, !presentation.isStale {
                    compactTranslation
                } else {
                    Text(presentation.translation.isEmpty
                        ? (presentation.isStale
                            ? String(localized: "Waiting for a pause to update the expression…", table: "Learning",
                                comment: """
                                Compact card placeholder when the source text changed and a new translation will start after typing \
                                pauses.
                                """)
                            : String(localized: "Generating expression…", table: "Learning",
                                comment: "Compact card placeholder while the target-language translation is being generated."))
                        : presentation.translation)
                    .font(.system(size: 16)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(presentation.isStale ? Color.secondary : Color.primary)
                }
                if !presentation.isGenerating, !presentation.message.isEmpty {
                    Text(presentation.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(width: presentation.isExpanded ? min(480, max(expandedWidth, ceil(copyActionsWidth) + 20)) : 320, alignment: .topLeading)
        .onChange(of: expandedSizingContent, initial: true) { _, content in
            guard content.isExpanded else { return }
            expandedWidth = measuredExpandedWidth(content)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: LearningCardSizePreference.self, value: geometry.size)
        })
        .onPreferenceChange(LearningCardSizePreference.self, perform: sizeChanged)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Match the fonts used by the two existing TextKit views. The 320pt floor leaves room for
    /// header/copy actions, while the 480pt ceiling preserves the current wrapping and viewport
    /// limits. Status messages wrap at this width instead of widening a short sentence pair.
    private func measuredExpandedWidth(_ content: ExpandedSizingContent) -> CGFloat {
        let source = (content.source as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16)]).width
        let translation = ((content.translation ?? "") as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 18)]).width
        // The outer padding is already part of the panel's measured frame. A small glyph margin
        // keeps the final punctuation inside TextKit's line box despite fractional font advances.
        return min(480, max(320, ceil(max(source, translation)) + 22))
    }

    /// Compact describes the viewport, not a shortened translation. TextKit lays out the entire
    /// sentence; short content fits naturally and longer content scrolls without growing over the
    /// editor. Direct geometry observation also shrinks a reused host after a long sentence.
    private var compactTranslation: some View {
        ScrollView {
            LearningSentenceDictionaryText(text: presentation.translation, language: presentation.targetLanguage,
                lookup: lookupText, units: presentation.units, maximumLines: 0, lookupUnit: lookupUnit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if height.isFinite, height > 0 { compactTranslationHeight = height }
                }
        }
        .frame(height: min(max(compactTranslationHeight, 1), 180))
        .id(presentation.id)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(
                presentation.isError
                    ? String(
                        localized: "Translation preview unavailable", table: "Learning",
                        comment: "Header for an explicit preview capture error.")
                : presentation.isExpanded
                    ? String(localized: "\(presentation.sourceLanguage.label) → \(presentation.targetLanguage.label)",
                        table: "Learning", comment: "Source-to-target language direction in the expanded sentence card.")
                    : presentation.targetLanguage.label)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let vocabulary, let capture = VocabularyCaptureFactory.preview(presentation) {
                VocabularyFavoriteButton(store: vocabulary, capture: capture)
            }
            if !presentation.isExpanded, let speech, let request = translationSpeechRequest {
                LearningSpeechButton(speech: speech, request: request,
                    playLabel: String(localized: "Play translation aloud", table: "Learning"),
                    stopLabel: String(localized: "Stop speaking translation", table: "Learning"))
            }
            if !presentation.isError {
                replacementAction
                iconAction(presentation.isExpanded
                    ? String(localized: "Collapse", table: "Learning")
                    : String(localized: "Expand", table: "Learning"),
                    symbol: presentation.isExpanded ? "chevron.up" : "chevron.down", action: expand)
            }
            iconAction(String(localized: "Dismiss"), symbol: "xmark", action: dismiss)
        }
    }

    @ViewBuilder
    private var replacementAction: some View {
        if presentation.isCommitting {
            ProgressView().controlSize(.small).frame(width: 22, height: 22)
        } else {
            iconAction(String(localized: "Replace", table: "Learning"), symbol: "arrow.left.arrow.right",
                color: isReplacementEnabled ? .blue : .secondary, action: { if isReplacementEnabled { replace?() } })
                .disabled(!isReplacementEnabled)
        }
    }

    /// A stable disabled icon keeps the action row still while text streams. Availability also
    /// guards stale/incomplete results here, before the coordinator's exact-range write checks.
    private var isReplacementEnabled: Bool {
        presentation.canReplace && replace != nil && !presentation.isTranslating && !presentation.isStale
    }

    /// Disclosure and dismissal use familiar symbols with a full click target. Labels stay
    /// available to VoiceOver and hover help without competing with the translation for space.
    private func iconAction(_ title: String, symbol: String, color: Color = .secondary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .font(.caption.weight(.semibold)).foregroundStyle(color)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(presentation.sourceLanguage.label)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let vocabulary, let capture = VocabularyCaptureFactory.preview(presentation, original: true) {
                            VocabularyFavoriteButton(store: vocabulary, capture: capture)
                        }
                        if let speech, let request = sourceSpeechRequest {
                            LearningSpeechButton(speech: speech, request: request,
                                playLabel: String(localized: "Play source text aloud", table: "Learning"),
                                stopLabel: String(localized: "Stop speaking source text", table: "Learning"))
                        }
                    }
                    sentence(presentation.source, source: true)
                    HStack {
                        Text(presentation.targetLanguage.label)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let speech, let request = translationSpeechRequest {
                            LearningSpeechButton(speech: speech, request: request,
                                playLabel: String(localized: "Play translation aloud", table: "Learning"),
                                stopLabel: String(localized: "Stop speaking translation", table: "Learning"))
                        }
                    }
                    sentence(presentation.translation, source: false)
                    if !presentation.translation.isEmpty, presentation.chunks.isEmpty,
                       !presentation.isTranslating, presentation.isGenerating || !presentation.message.isEmpty {
                        Text(presentation.isGenerating
                            ? String(localized: "The translation appears first; chunk alignments are loading…", table: "Learning",
                                comment: "Status shown while the translation is available but phrase-alignment analysis is still running.")
                            : presentation.message)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let selected = detailState.chunk, selected.documentID == presentation.id,
                       presentation.chunks.contains(where: { $0.id == selected.chunkID }) {
                        Text(verbatim: "\(selected.source) → \(selected.target)")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !presentation.translation.isEmpty, presentation.unitStage == .failed {
                        Text(String(localized: "Expression highlights are unavailable; you can still double-click words to look them up.",
                            table: "Learning", comment: """
                            Status when expression recognition failed but dictionary lookup remains available.
                            """))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !presentation.translation.isEmpty, !presentation.isTranslating, presentation.unitStage == .pending {
                        Text(String(localized: "Recognizing expressions… You can still double-click words to look them up.",
                            table: "Learning", comment: """
                            Status while expression recognition runs; dictionary lookup is already available.
                            """))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !presentation.message.isEmpty, !presentation.isGenerating, !presentation.chunks.isEmpty {
                        Text(presentation.message).font(.caption).foregroundStyle(.secondary)
                    }
                    if let explanation {
                        Divider()
                        Text(String(localized: "AI explanation", table: "Learning")).font(.caption.weight(.semibold))
                        if let vocabulary, let capture = VocabularyCaptureFactory.preview(presentation) {
                            LearningCapturedExplanationView(session: explanation, store: vocabulary, capture: capture,
                                configure: { (explanation.service as? LearningExplanationService)?.configure?() })
                        } else {
                            LearningExplanationView(session: explanation,
                                configure: { (explanation.service as? LearningExplanationService)?.configure?() })
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    // Observe the content itself: a preference routed across ScrollView can
                    // retain its old value after the sentence gains lines. Intrinsic vertical
                    // sizing keeps this measurement independent of the bounded viewport.
                    if height.isFinite, height > 0 { detailsHeight = height }
                }
            }
            .frame(height: min(max(detailsHeight, 1), 320))
            copyActions
                .background(alignment: .topLeading) {
                    // Native SwiftUI button padding varies with locale/style. Measure the exact
                    // reused controls at their ideal width, without letting the measuring copy
                    // affect layout, accessibility, clipboard actions, or pointer hit testing.
                    copyActions.fixedSize(horizontal: true, vertical: true)
                        .hidden().accessibilityHidden(true).allowsHitTesting(false)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            if width.isFinite, width > 0 { copyActionsWidth = width }
                        }
                }
        }
    }

    /// The visible and sizing copies use one definition, so changing a localized title or native
    /// control style cannot make the width estimate drift away from the actual footer.
    private var copyActions: some View {
        HStack {
            Button(
                String(
                    localized: "Copy source text", table: "Learning", comment: "Copies the verified original text for manual recovery.")
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(presentation.source, forType: .string)
            }
            if !presentation.translation.isEmpty, !presentation.isTranslating {
                Button(String(localized: "Copy translation", table: "Learning",
                    comment: "Copies the target-language sentence to the clipboard.")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(presentation.translation, forType: .string)
                }
            }
            Spacer()
        }
    }

    private func sentence(_ text: String, source: Bool) -> some View {
        // Recognition owns underlines and click boundaries; the analysis service owns validated
        // meaning ranges. Paint each result as it arrives, without making either grain a gate
        // for the other. TextKit overlays these attributes on the same untouched sentence.
        LearningSentenceDictionaryText(text: text, language: source ? presentation.sourceLanguage : presentation.targetLanguage,
            lookup: lookupText, units: source ? [] : presentation.units, chunks: presentation.chunks,
            selectedChunk: detailState.chunk?.documentID == presentation.id ? detailState.chunk?.chunkID : nil,
            source: source, maximumLines: 0, fontSize: source ? 16 : 18,
            lookupUnit: lookupUnit, inspect: inspect)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceSpeechRequest: SpeechRequest? {
        guard !presentation.source.isEmpty, !presentation.isStale, !presentation.isError else { return nil }
        return SpeechRequest(
            target: SpeechTarget(ownerID: presentation.id, itemID: "preview.source"),
            text: presentation.source, language: presentation.sourceLanguage)
    }

    private var translationSpeechRequest: SpeechRequest? {
        // `isGenerating` also covers alignment work after a full translation is already visible.
        // A nonempty, nonstale value is the completed snapshot and is safe to read independently.
        guard !presentation.translation.isEmpty, !presentation.isTranslating,
              !presentation.isStale, !presentation.isError else { return nil }
        return SpeechRequest(
            target: SpeechTarget(ownerID: presentation.id, itemID: "preview.translation"),
            text: presentation.translation, language: presentation.targetLanguage)
    }

}

/// A tiny child observes only the shared playback controller. Cards keep their measured layout
/// stable during ordinary playback; an error caption appears only when the provider reports one.
struct LearningSpeechButton: View {
    @ObservedObject var speech: LearningSpeechController
    let request: SpeechRequest
    let playLabel: String
    let stopLabel: String

    private var isPlaying: Bool { speech.isPlaying(request.target) }
    private var error: String? { speech.error(for: request.target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { speech.toggle(request) } label: {
                Group {
                    if speech.isPreparing(request.target) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                    }
                }
                .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(error ?? (isPlaying ? stopLabel : playLabel))
            .accessibilityLabel(isPlaying ? stopLabel : playLabel)
            .accessibilityHint(error ?? "")
            .accessibilityValue(speech.isPreparing(request.target)
                ? String(localized: "Generating speech…", table: "Learning") : "")

            if let error {
                Text(error).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(error)
            }
        }
    }
}
