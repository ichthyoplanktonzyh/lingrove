import AppKit
import SwiftUI

/// Shows one sentence pair with lexical underlines and existing learning actions. The app-owned
/// panel validates clicked occurrences and owns dictionary and explanation lifetimes.
struct LearningSentenceCard: View {
    let presentation: LearningSentencePresentation
    var explanation: LearningExplanationSession?
    var replace: (() -> Void)?
    let expand: () -> Void
    let dismiss: () -> Void
    var lookupText: (LearningDictionaryTextAnchor, NSTextView) -> Void = { _, _ in }
    var lookupUnit: ((LearningUnitTextAnchor, NSTextView) -> Void)?
    var speech: LearningSpeechController?
    var vocabulary: VocabularyStore?
    let sizeChanged: (CGSize) -> Void
    // Begin with the sentence pair's short layout; longer content measures itself below.
    // The former instruction-sized fallback leaves a blank block after the guide text is removed.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detailsHeight: CGFloat = 100
    @State private var compactTranslationHeight: CGFloat = 20
    @State private var expandedWidth: CGFloat = 320

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
        VStack(alignment: .leading, spacing: 7) {
            header
            if !presentation.isError, let reason = presentation.replacementUnavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if presentation.isError {
                Text(presentation.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            } else if presentation.isExpanded {
                details
                    .transition(.opacity)
            } else {
                if let previous = presentation.previousTranslation {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 2, height: 12)
                        Text(previous).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
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
        .frame(width: presentation.isExpanded ? min(480, expandedWidth) : 320, alignment: .topLeading)
        .onChange(of: expandedSizingContent, initial: true) { _, content in
            guard content.isExpanded else { return }
            expandedWidth = measuredExpandedWidth(content)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: LearningCardSizePreference.self, value: geometry.size)
        })
        .onPreferenceChange(LearningCardSizePreference.self, perform: sizeChanged)
        .learningCardChrome(cornerRadius: 12)
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 1.0), value: presentation.isExpanded)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: presentation.isTranslating)
    }

    /// Match the fonts used by the two existing TextKit views. The 320pt floor leaves room for
    /// header controls, while the 480pt ceiling preserves the current wrapping and viewport
    /// limits. Status messages wrap at this width instead of widening a short sentence pair.
    private func measuredExpandedWidth(_ content: ExpandedSizingContent) -> CGFloat {
        let source = (content.source as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16)]).width + 11
        let translation = ((content.translation ?? "") as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 18)]).width
        // The outer padding is already part of the panel's measured frame. A small glyph margin
        // keeps the final punctuation inside TextKit's line box despite fractional font advances.
        let speechWidth: CGFloat = speech == nil ? 0 : 28
        let copyWidth: CGFloat = 28
        return min(480, max(320, ceil(max(source, translation)) + 22 + speechWidth + copyWidth))
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

    private var headerTitle: String {
        if presentation.isError {
            return String(
                localized: "Translation preview unavailable", table: "Learning",
                comment: "Header for an explicit preview capture error.")
        }
        if presentation.isExpanded {
            guard let source = presentation.sourceLanguage?.compactLabel else { return presentation.targetLanguage.compactLabel }
            return String(localized: "\(source) → \(presentation.targetLanguage.compactLabel)",
                table: "Learning", comment: "Source-to-target language direction in the expanded sentence card.")
        }
        return presentation.targetLanguage.compactLabel
    }

    private var hasLearningToolsInHeader: Bool {
        explanation != nil ||
            (vocabulary != nil && VocabularyCaptureFactory.preview(presentation) != nil) ||
            (!presentation.isExpanded && speech != nil && translationSpeechRequest != nil)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                if presentation.isTranslating {
                    Circle()
                        .fill(LingroveBrand.accent)
                        .frame(width: 5, height: 5)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(headerTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
            Spacer(minLength: 0)
            if let explanation {
                LearningExplanationButton(session: explanation, prepare: { if !presentation.isExpanded { expand() } },
                    configure: { (explanation.service as? LearningExplanationService)?.configure?() })
            }
            if let vocabulary, let capture = VocabularyCaptureFactory.preview(presentation) {
                VocabularyFavoriteButton(store: vocabulary, capture: capture)
            }
            if !presentation.isExpanded, let speech, let request = translationSpeechRequest {
                LearningSpeechButton(speech: speech, request: request,
                    playLabel: String(localized: "Play translation aloud", table: "Learning"),
                    stopLabel: String(localized: "Stop speaking translation", table: "Learning"))
            }
            if !presentation.isError, hasLearningToolsInHeader {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1, height: 11)
                    .accessibilityHidden(true)
            }
            if !presentation.isError {
                replacementAction.learningAction(.replace)
                iconAction(presentation.isExpanded
                    ? String(localized: "Collapse", table: "Learning")
                    : String(localized: "Expand", table: "Learning"),
                    symbol: presentation.isExpanded ? "chevron.up" : "chevron.down", action: expand).learningAction(.expand)
            }
            iconAction(String(localized: "Dismiss"), symbol: "xmark", action: dismiss).learningAction(.dismiss)
        }
    }

    @ViewBuilder
    private var replacementAction: some View {
        if presentation.isCommitting {
            ProgressView().controlSize(.small).frame(width: 22, height: 22)
        } else {
            iconAction(String(localized: "Replace", table: "Learning"), symbol: "arrow.left.arrow.right",
                color: isReplacementEnabled ? .secondary : .secondary.opacity(0.42),
                isEnabled: isReplacementEnabled,
                action: { if isReplacementEnabled { replace?() } })
                .disabled(!isReplacementEnabled)
        }
    }

    /// A stable disabled icon keeps the action row still while text streams. Availability also
    /// guards stale/incomplete results here, before the coordinator's exact-range write checks.
    private var isReplacementEnabled: Bool {
        presentation.canReplace && replace != nil && !presentation.isTranslating && !presentation.isStale
    }

    /// Disclosure, replacement, and dismissal share one tactile 22pt control with hover and press
    /// feedback. Labels stay available to VoiceOver and hover help without competing for space.
    private func iconAction(_ title: String, symbol: String, color: Color = .secondary,
                            isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        LearningToolbarIconButton(title: title, symbol: symbol, color: color, isEnabled: isEnabled, action: action)
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    sentence(presentation.source, source: true)
                        .padding(.leading, 10.5)
                        .overlay(alignment: .leading) {
                            // Decoration must not add another HStack sizing probe: that
                            // probe can leave TextKit at infinite width after the row fits.
                            RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                                .fill(Color.secondary.opacity(0.32))
                                .frame(width: 2.5)
                                .padding(.vertical, 2)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    if let speech, let request = sourceSpeechRequest {
                        LearningSpeechButton(speech: speech, request: request,
                            playLabel: String(localized: "Play source text aloud", table: "Learning"),
                            stopLabel: String(localized: "Stop speaking source text", table: "Learning"))
                    }
                    if !presentation.source.isEmpty {
                        LearningCopyIconButton(
                            title: String(
                                localized: "Copy source text", table: "Learning",
                                comment: "Copies the verified original text for manual recovery."),
                            text: presentation.source
                        )
                    }
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)
                HStack(alignment: .top, spacing: 8) {
                    sentence(presentation.translation, source: false)
                    if let speech, let request = translationSpeechRequest {
                        LearningSpeechButton(speech: speech, request: request,
                            playLabel: String(localized: "Play translation aloud", table: "Learning"),
                            stopLabel: String(localized: "Stop speaking translation", table: "Learning"))
                    }
                    if !presentation.translation.isEmpty, !presentation.isTranslating {
                        LearningCopyIconButton(
                            title: String(localized: "Copy translation", table: "Learning",
                                comment: "Copies the target-language sentence to the clipboard."),
                            text: presentation.translation
                        )
                    }
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
                if !presentation.message.isEmpty, !presentation.isGenerating {
                    Text(presentation.message).font(.caption).foregroundStyle(.secondary)
                }
                if let explanation {
                    if let vocabulary, let capture = VocabularyCaptureFactory.preview(presentation) {
                        LearningCapturedExplanationView(session: explanation, store: vocabulary, capture: capture,
                            configure: { (explanation.service as? LearningExplanationService)?.configure?() }, presentation: .embedded)
                    } else {
                        LearningExplanationView(session: explanation,
                            configure: { (explanation.service as? LearningExplanationService)?.configure?() }, presentation: .embedded)
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
    }

    private func sentence(_ text: String, source: Bool) -> some View {
        LearningSentenceDictionaryText(text: text, language: source ? presentation.sourceLanguage : presentation.targetLanguage,
            lookup: lookupText, units: source ? [] : presentation.units,
            source: source, maximumLines: 0, fontSize: source ? 16 : 18,
            lookupUnit: lookupUnit)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceSpeechRequest: SpeechRequest? {
        guard !presentation.source.isEmpty, !presentation.isStale, !presentation.isError else { return nil }
        return SpeechRequest(
            target: SpeechTarget(ownerID: presentation.id, itemID: "preview.source"),
            text: presentation.source, language: presentation.sourceLanguage)
    }

    private var translationSpeechRequest: SpeechRequest? {
        // A streamed prefix is visible but is not a complete utterance. Read only the
        // validated final translation, independently of pending lexical highlights.
        guard !presentation.translation.isEmpty, !presentation.isTranslating,
              !presentation.isStale, !presentation.isError else { return nil }
        return SpeechRequest(
            target: SpeechTarget(ownerID: presentation.id, itemID: "preview.translation"),
            text: presentation.translation, language: presentation.targetLanguage)
    }

}

/// Tactile 22pt header button with hover highlight, pointer-down scale feedback, and smooth
/// symbol replacement when toggling states (such as expand/collapse chevrons).
private struct LearningToolbarIconButton: View {
    let title: String
    let symbol: String
    var color: Color = .secondary
    var isEnabled: Bool = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.caption.weight(.semibold))
                .foregroundStyle(hovering && isEnabled ? Color.primary : color)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(LearningIconActionButtonStyle(hovering: hovering, isEnabled: isEnabled))
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Inline 20pt icon control placed at the trailing edge of each sentence row in the expanded
/// details view. Keeping copy as a quiet row-level icon rather than a full-width footer row
/// preserves vertical density for low-frequency clipboard recovery while still giving immediate
/// symbol-replacement (`checkmark`) confirmation on click.
private struct LearningCopyIconButton: View {
    let title: String
    let text: String
    @Environment(\.learningInteraction) private var interact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            interact()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            resetTask?.cancel()
            withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.9)) {
                didCopy = true
            }
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    didCopy = false
                }
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11.5, weight: didCopy ? .bold : .regular))
                .foregroundStyle(didCopy ? Color.green : (hovering ? Color.primary : Color.secondary.opacity(0.65)))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(LearningIconActionButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .onDisappear { resetTask?.cancel() }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A tiny child observes only the shared playback controller. Cards keep their measured layout
/// stable during ordinary playback; an error caption appears only when the provider reports one.
struct LearningSpeechButton: View {
    @Environment(\.learningInteraction) private var interact
    @ObservedObject var speech: LearningSpeechController
    let request: SpeechRequest
    let playLabel: String
    let stopLabel: String
    @State private var hovering = false

    private var isPlaying: Bool { speech.isPlaying(request.target) }
    private var error: String? { speech.error(for: request.target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { interact(); speech.toggle(request) } label: {
                Group {
                    if speech.isPreparing(request.target) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .foregroundStyle(isPlaying ? Color.accentColor : (hovering ? Color.primary : Color.secondary))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(LearningIconActionButtonStyle(hovering: hovering))
            .onHover { hovering = $0 }
            .learningAction(.speech)
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

#if DEBUG
#Preview("翻译预览 · 交互") {
    LearningCardPreview(kind: .sentence)
}
#Preview("翻译详情 · 长文本") {
    LearningCardPreview(kind: .sentence, state: .longText, expanded: true)
}
#Preview("翻译预览 · 深色") {
    LearningCardPreview(kind: .sentence).preferredColorScheme(.dark)
}
#endif
