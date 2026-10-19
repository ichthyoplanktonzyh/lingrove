import Combine
import Foundation

/// Owned once by SuggestionSettingsModel. The model persists writing and reading translation preferences; legacy vocabulary keys are intentionally left untouched and never read.
/// UI observes this object while each service request captures its immutable snapshot.
@MainActor
final class LanguageLearningSettings: ObservableObject {
    private let defaults: UserDefaults
    let translation: LearningModelSettings
    let analysis: LearningModelSettings
    /// Reading has its own direction; changing it never reverses the writing preview.
    @Published var selectionTranslationEnabled: Bool {
        didSet { defaults.set(selectionTranslationEnabled, forKey: "learningSelectionEnabled") }
    }
    @Published var selectionIconEnabled: Bool { didSet { defaults.set(selectionIconEnabled, forKey: "learningSelectionIcon") } }
    @Published var readingTargetLanguage: LearningLanguage {
        didSet { defaults.set(readingTargetLanguage.rawValue, forKey: "learningReadingTarget") }
    }
    @Published var selectionKeyCode: UInt16 { didSet { defaults.set(Int(selectionKeyCode), forKey: "learningSelectionKey") } }
    @Published var selectionModifiers: ShortcutModifierMask {
        didSet { defaults.set(Int(selectionModifiers.rawValue), forKey: "learningSelectionModifiers") }
    }
    @Published var selectionKeyLabel: String { didSet { defaults.set(selectionKeyLabel, forKey: "learningSelectionLabel") } }

    @Published var pointerTranslationEnabled: Bool { didSet { defaults.set(pointerTranslationEnabled, forKey: "learningPointerEnabled") } }
    @Published var screenshotTranslationEnabled: Bool {
        didSet { defaults.set(screenshotTranslationEnabled, forKey: "learningScreenshotEnabled") }
    }
    @Published var pointerKeyCode: UInt16 { didSet { defaults.set(Int(pointerKeyCode), forKey: "learningPointerKey") } }
    @Published var pointerModifiers: ShortcutModifierMask {
        didSet { defaults.set(Int(pointerModifiers.rawValue), forKey: "learningPointerModifiers") }
    }
    @Published var pointerKeyLabel: String { didSet { defaults.set(pointerKeyLabel, forKey: "learningPointerLabel") } }
    @Published var screenshotKeyCode: UInt16 { didSet { defaults.set(Int(screenshotKeyCode), forKey: "learningScreenshotKey") } }
    @Published var screenshotModifiers: ShortcutModifierMask {
        didSet { defaults.set(Int(screenshotModifiers.rawValue), forKey: "learningScreenshotModifiers") }
    }
    @Published var screenshotKeyLabel: String { didSet { defaults.set(screenshotKeyLabel, forKey: "learningScreenshotLabel") } }

    func readingEnabled(_ source: LearningReadingSource) -> Bool {
        switch source {
        case .selection: selectionTranslationEnabled
        case .pointer: pointerTranslationEnabled
        case .screenshot: screenshotTranslationEnabled
        }
    }
    func readingBinding(_ source: LearningReadingSource) -> (key: UInt16, modifiers: ShortcutModifierMask, label: String) {
        switch source {
        case .selection: (selectionKeyCode, selectionModifiers, selectionKeyLabel)
        case .pointer: (pointerKeyCode, pointerModifiers, pointerKeyLabel)
        case .screenshot: (screenshotKeyCode, screenshotModifiers, screenshotKeyLabel)
        }
    }
    func setReadingBinding(_ source: LearningReadingSource, key: UInt16, modifiers: ShortcutModifierMask, label: String) {
        switch source {
        case .selection:
            selectionKeyCode = key
            selectionModifiers = modifiers
            selectionKeyLabel = label
        case .pointer:
            pointerKeyCode = key
            pointerModifiers = modifiers
            pointerKeyLabel = label
        case .screenshot:
            screenshotKeyCode = key
            screenshotModifiers = modifiers
            screenshotKeyLabel = label
        }
    }

    /// The coordinator retires only receipts from the edited source. Keeping these events typed
    /// prevents an unrelated entry switch from cancelling an otherwise valid translation.
    var readingSourceChanges: AnyPublisher<LearningReadingSource, Never> {
        Publishers.MergeMany([
            $pointerTranslationEnabled.dropFirst().map { _ in LearningReadingSource.pointer }.eraseToAnyPublisher(),
            $screenshotTranslationEnabled.dropFirst().map { _ in LearningReadingSource.screenshot }.eraseToAnyPublisher(),
            $selectionTranslationEnabled.dropFirst().map { _ in LearningReadingSource.selection }.eraseToAnyPublisher(),
        ]).eraseToAnyPublisher()
    }

    var readingChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            $readingTargetLanguage.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $translationEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            translation.changes,
        ]).eraseToAnyPublisher()
    }
    @Published var analysisEnabled: Bool {
        didSet { defaults.set(analysisEnabled, forKey: "learningAnalysisEnabled") }
    }

    @Published var translationEnabled: Bool {
        didSet { defaults.set(translationEnabled, forKey: "learningTranslationEnabled") }
    }
    var model: String {
        get { translation.endpointModel }
        set {
            translation.backend = .endpoint
            translation.endpointModel = newValue
            defaults.set(newValue, forKey: "learningInstructionModel")
        }
    }
    @Published var keyCode: UInt16 {
        didSet { defaults.set(Int(keyCode), forKey: "learningTranslationKey") }
    }
    @Published var modifiers: ShortcutModifierMask {
        didSet { defaults.set(Int(modifiers.rawValue), forKey: "learningTranslationModifiers") }
    }
    @Published var keyLabel: String {
        didSet { defaults.set(keyLabel, forKey: "learningTranslationLabel") }
    }
    @Published var sourceLanguages: [LearningLanguage] {
        didSet { defaults.set(sourceLanguages.map(\.rawValue), forKey: "learningSourceLanguages") }
    }
    @Published var targetLanguage: LearningLanguage {
        didSet { defaults.set(targetLanguage.rawValue, forKey: "learningTargetLanguage") }
    }
    @Published var sentencePreviewEnabled: Bool {
        didSet { defaults.set(sentencePreviewEnabled, forKey: "learningSentencePreviewEnabled") }
    }
    @Published var referenceMode: LearningReferenceMode {
        didSet { defaults.set(referenceMode.rawValue, forKey: "learningReferenceMode") }
    }
    @Published var replacementKeyCode: UInt16 { didSet { saveReplacementShortcut() } }
    @Published var replacementModifiers: ShortcutModifierMask { didSet { saveReplacementShortcut() } }
    @Published var replacementKeyLabel: String { didSet { saveReplacementShortcut() } }

    /// A generation snapshots all settings that can change its prompt or eligibility. The
    /// publisher lets coordinators cancel work as soon as one of those values is edited.
    var changes: AnyPublisher<Void, Never> {
        Publishers.MergeMany(
            [
                $translationEnabled.map { _ in () }.eraseToAnyPublisher(),
                $sourceLanguages.map { _ in () }.eraseToAnyPublisher(),
                $targetLanguage.map { _ in () }.eraseToAnyPublisher(),
                $sentencePreviewEnabled.map { _ in () }.eraseToAnyPublisher(),
                $referenceMode.map { _ in () }.eraseToAnyPublisher(),
            ].map { $0.dropFirst().eraseToAnyPublisher() } + [translation.changes]
        ).eraseToAnyPublisher()
    }

    /// Bindings affect presentation, not the meaning of a generated translation. Repaint labels
    /// without discarding the current source or cancelling a valid response.
    var shortcutChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany(
            [
                $keyCode.map { _ in () }.eraseToAnyPublisher(),
                $modifiers.map { _ in () }.eraseToAnyPublisher(),
                $keyLabel.map { _ in () }.eraseToAnyPublisher(),
                $replacementKeyCode.map { _ in () }.eraseToAnyPublisher(),
                $replacementModifiers.map { _ in () }.eraseToAnyPublisher(),
                $replacementKeyLabel.map { _ in () }.eraseToAnyPublisher(),
                $selectionKeyCode.map { _ in () }.eraseToAnyPublisher(),
                $selectionModifiers.map { _ in () }.eraseToAnyPublisher(),
                $pointerKeyCode.map { _ in () }.eraseToAnyPublisher(),
                $pointerModifiers.map { _ in () }.eraseToAnyPublisher(),
                $pointerKeyLabel.map { _ in () }.eraseToAnyPublisher(),
                $screenshotKeyCode.map { _ in () }.eraseToAnyPublisher(),
                $screenshotModifiers.map { _ in () }.eraseToAnyPublisher(),
                $screenshotKeyLabel.map { _ in () }.eraseToAnyPublisher(),
                $selectionKeyLabel.map { _ in () }.eraseToAnyPublisher(),
            ].map { $0.dropFirst().eraseToAnyPublisher() }
        ).eraseToAnyPublisher()
    }

    var analysisChanges: AnyPublisher<Void, Never> {
        Publishers.Merge($analysisEnabled.dropFirst().map { _ in () }, analysis.changes).eraseToAnyPublisher()
    }

    var snapshot: LearningSettingsSnapshot {
        .init(
            translationEnabled: translationEnabled,
            model: translation.snapshot.endpointModel,
            sentencePreviewEnabled: sentencePreviewEnabled,
            sourceLanguages: sourceLanguages,
            targetLanguage: targetLanguage,
            translationModel: translation.snapshot, referenceMode: referenceMode
        )
    }

    /// App-wide reset keeps the shortcut contract while disabling both explicit language features.
    func resetToDefaults() {
        pointerTranslationEnabled = false
        screenshotTranslationEnabled = false
        setReadingBinding(.pointer, key: 17, modifiers: [.control, .shift], label: "⌃⇧T")
        setReadingBinding(.screenshot, key: 17, modifiers: [.control, .option, .shift], label: "⌃⌥⇧T")
        selectionTranslationEnabled = false
        selectionIconEnabled = false
        readingTargetLanguage = .chinese
        selectionKeyCode = 17
        selectionModifiers = [.option, .shift]
        selectionKeyLabel = "⌥⇧T"
        translationEnabled = false
        sentencePreviewEnabled = true
        referenceMode = .currentSentence
        replacementKeyCode = 17
        replacementModifiers = [.control, .option]
        replacementKeyLabel = "⌃⌥T"
        sourceLanguages = [.chinese]
        targetLanguage = .english
        model = ""
        translation.reset()
        analysisEnabled = false
        analysis.reset()
        keyCode = 17
        modifiers = [.option]
        keyLabel = "⌥T"
    }

    init(
        defaults: UserDefaults = .standard,
        translationCredentials: (any OpenAICompatibleCredentialStoring)? = nil,
        analysisCredentials: (any OpenAICompatibleCredentialStoring)? = nil
    ) {
        self.defaults = defaults
        pointerTranslationEnabled = defaults.bool(forKey: "learningPointerEnabled")
        screenshotTranslationEnabled = defaults.bool(forKey: "learningScreenshotEnabled")
        pointerKeyCode = UInt16(clamping: defaults.object(forKey: "learningPointerKey") as? Int ?? 17)
        pointerModifiers = ShortcutModifierMask(
            rawValue: UInt32(clamping: defaults.object(forKey: "learningPointerModifiers") as? Int ?? 10))
        pointerKeyLabel = defaults.string(forKey: "learningPointerLabel") ?? "⌃⇧T"
        screenshotKeyCode = UInt16(clamping: defaults.object(forKey: "learningScreenshotKey") as? Int ?? 17)
        screenshotModifiers = ShortcutModifierMask(
            rawValue: UInt32(clamping: defaults.object(forKey: "learningScreenshotModifiers") as? Int ?? 14))
        screenshotKeyLabel = defaults.string(forKey: "learningScreenshotLabel") ?? "⌃⌥⇧T"
        selectionTranslationEnabled = defaults.bool(forKey: "learningSelectionEnabled")
        selectionIconEnabled = defaults.bool(forKey: "learningSelectionIcon")
        readingTargetLanguage = LearningLanguage(rawValue: defaults.string(forKey: "learningReadingTarget") ?? "") ?? .chinese
        selectionKeyCode = UInt16(clamping: defaults.object(forKey: "learningSelectionKey") as? Int ?? 17)
        selectionModifiers = ShortcutModifierMask(
            rawValue: UInt32(clamping: defaults.object(forKey: "learningSelectionModifiers") as? Int ?? 6))
        selectionKeyLabel = defaults.string(forKey: "learningSelectionLabel") ?? "⌥⇧T"
        translation = LearningModelSettings(role: .translation, defaults: defaults, credentials: translationCredentials)
        analysis = LearningModelSettings(role: .analysis, defaults: defaults, credentials: analysisCredentials)
        analysisEnabled = defaults.bool(forKey: "learningAnalysisEnabled")
        translationEnabled = defaults.bool(forKey: "learningTranslationEnabled")
        sourceLanguages =
            defaults.stringArray(forKey: "learningSourceLanguages")?
            .compactMap(LearningLanguage.init(rawValue:)) ?? [.chinese]
        targetLanguage =
            LearningLanguage(rawValue: defaults.string(forKey: "learningTargetLanguage") ?? "en")
            ?? .english
        sentencePreviewEnabled = defaults.object(forKey: "learningSentencePreviewEnabled") as? Bool ?? true
        referenceMode = LearningReferenceMode(rawValue: defaults.string(forKey: "learningReferenceMode") ?? "") ?? .currentSentence
        replacementKeyCode = UInt16(clamping: defaults.object(forKey: "learningReplacementKey") as? Int ?? 17)
        replacementModifiers = ShortcutModifierMask(
            rawValue: UInt32(
                clamping:
                    defaults.object(forKey: "learningReplacementModifiers") as? Int ?? 12))
        replacementKeyLabel = defaults.string(forKey: "learningReplacementLabel") ?? "⌃⌥T"
        keyCode = UInt16(clamping: defaults.object(forKey: "learningTranslationKey") as? Int ?? 17)
        modifiers = ShortcutModifierMask(
            rawValue: UInt32(clamping: defaults.object(forKey: "learningTranslationModifiers") as? Int ?? 9)
        )
        keyLabel = defaults.string(forKey: "learningTranslationLabel") ?? "⌃⌘T"
        // Migrate only our old default; custom bindings remain the user's choice.
        if keyCode == 17, modifiers == [.command, .control], keyLabel == "⌃⌘T" {
            modifiers = [.option]
            keyLabel = "⌥T"
            defaults.set(Int(modifiers.rawValue), forKey: "learningTranslationModifiers")
            defaults.set(keyLabel, forKey: "learningTranslationLabel")
        }
    }

    private func saveReplacementShortcut() {
        defaults.set(Int(replacementKeyCode), forKey: "learningReplacementKey")
        defaults.set(Int(replacementModifiers.rawValue), forKey: "learningReplacementModifiers")
        defaults.set(replacementKeyLabel, forKey: "learningReplacementLabel")
    }
}

/// Immutable behavior boundary retained by one generation. Equality rejects a reply after any
/// learning preference change that could make the result stale.
nonisolated struct LearningSettingsSnapshot: Equatable, Sendable {
    let translationEnabled: Bool
    let model: String
    var sentencePreviewEnabled: Bool = true
    let sourceLanguages: [LearningLanguage]
    let targetLanguage: LearningLanguage
    var translationModel: LearningModelSnapshot? = nil
    var referenceMode: LearningReferenceMode = .currentSentence
}
