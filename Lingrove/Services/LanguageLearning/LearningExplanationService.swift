import LingroveNotebook
import Combine
import Foundation

/// The model collection owns this explicit-only task. It borrows the general model controller shared with expression assistance
/// and the shared telemetry boundary, and caches a bounded number of complete results. Notebook
/// persistence is supplied by the composition root, keeping model work independent of storage/UI.
@MainActor
final class LearningExplanationService: LearningLookupGenerating {
    let settings: LanguageLearningSettings
    let model: LearningModelController
    private let telemetry: LearningRequestTelemetry
    private struct Key: Hashable {
        let input: LearningExplanationInput
        let language: LearningLanguage
        let profile: LearningModelSnapshot
    }
    private var cache: [Key: LearningExplanationRecord] = [:]
    private var cacheOrder: [Key] = []
    /// A detail belongs to one accepted pair under one model/language snapshot, not merely a spelling.
    private struct LookupKey: Hashable {
        let input: LearningLookupInput
        let language: LearningLanguage
        let profile: LearningModelSnapshot
        var basic: LearningLookupResult?
    }
    private var lookupCache: [LookupKey: LearningLookupRecord] = [:]
    private var detailCache: [LookupKey: LearningExplanationRecord] = [:]
    /// The content adapter captures an optional persistence destination before the first await.
    /// Model work knows only a closure, never a database/account object or an editable draft.
    var capturePersistence: (() -> ((LearningExplanationRecord) -> Void)?)?
    private var notebookEpoch = UUID()
    private let notebookChanges = PassthroughSubject<Void, Never>()
    var didExplain: ((LearningExplanationRecord) -> Void)?
    var configure: (() -> Void)?
    var loadPersisted: ((LearningExplanationInput, LearningLanguage) async -> LearningExplanationRecord?)?
    func loadSaved(for input: LearningExplanationInput) async -> LearningExplanationRecord? {
        let language = language, epoch = notebookEpoch
        let record = await loadPersisted?(input, language) ?? savedRecord(for: input)
        return self.language == language && notebookEpoch == epoch ? record : nil
    }
    var lookupSaved: ((LearningExplanationInput, LearningLanguage) -> LearningExplanationRecord?)?

    func savedRecord(for input: LearningExplanationInput) -> LearningExplanationRecord? { lookupSaved?(input, language) }

    init(settings: LanguageLearningSettings, model: LearningModelController, telemetry: LearningRequestTelemetry) {
        self.settings = settings; self.model = model; self.telemetry = telemetry
    }
    var changes: AnyPublisher<Void, Never> { settings.explanationChanges.merge(with: notebookChanges).eraseToAnyPublisher() }
    var language: LearningLanguage { settings.resolvedExplanationLanguage }
    var isConfigured: Bool {
        let profile = model.profile.snapshot
        let name = profile.backend == .local ? profile.localModel : profile.endpointModel
        return !name.isEmpty && LearningExplanationPolicy.supportsGeneralInstructions(model: name, template: profile.template)
    }

    /// Saving a legacy card may attach its already-computed full result. A staged lookup has
    /// its own accepted pair/details, so it explicitly opts out of target-only legacy enrichment.
    func enrich(_ capture: VocabularyCapture) -> VocabularyCapture {
        guard capture.allowsExplanationEnrichment, capture.explanation == nil else { return capture }
        var capture = capture
        let input = LearningExplanationPolicy.input(capture)
        capture.explanation = cached(input) ?? savedRecord(for: input)
        return capture
    }

    func cached(_ input: LearningExplanationInput) -> LearningExplanationRecord? {
        cache[Key(input: input, language: language, profile: model.profile.snapshot)]
    }

    func generate(_ input: LearningExplanationInput, requestID: String,
                  refresh: Bool = false) async throws -> LearningExplanationRecord {
        guard LearningExplanationPolicy.isValid(input) else { throw VocabularyError.invalidContent }
        let profile = model.profile.snapshot, language = language, epoch = notebookEpoch
        let persist = capturePersistence.map { $0() } ?? didExplain
        let key = Key(input: input, language: language, profile: profile)
        if !refresh {
            if let result = await loadSaved(for: input) ?? cache[key] {
                try Task.checkCancellation()
                guard model.profile.snapshot == profile, self.language == language, notebookEpoch == epoch else {
                    throw CancellationError()
                }
                return result
            }
        }
        try Task.checkCancellation()
        guard model.profile.snapshot == profile, self.language == language, notebookEpoch == epoch else {
                    throw CancellationError()
                }
        let lease = model.reserveInstructionRequest()
        return try await LearningRequestTrace.$requestID.withValue(requestID) {
            try await telemetry.perform(source: .explanation, profile: profile) {
                guard self.isConfigured else {
                    throw LearningFailure.message(String(
                        localized: "Choose a general instruction model for AI explanation.", table: "Learning"))
                }
                try await self.model.validateGeneralInstructionModel()
                let output = profile.maximumOutputTokens ?? 1_024
                let prompt = try LearningExplanationPolicy.prompt(input, language: language,
                    total: profile.contextWindowTokens, output: output)
                @MainActor func validate() throws {
                    try self.model.validateInstructionRequest(lease)
                    try Task.checkCancellation()
                    guard self.model.profile.snapshot == profile, self.language == language, self.notebookEpoch == epoch else {
                        throw CancellationError()
                    }
                }
                try validate()
                var bytes = 0
                let raw = try await self.model.generate(prompt: prompt, maxTokens: output,
                    localGrammar: LearningOutputGrammar.explanation) { delta in
                    try validate()
                    bytes += delta.utf8.count
                    guard bytes <= 24_000 else { throw VocabularyError.invalidContent }
                }
                try validate()
                let result = try LearningExplanationPolicy.parse(raw)
                LearningRequestTrace.measurement?.usable()
                let record = LearningExplanationRecord(id: UUID(), input: input, language: language, result: result,
                    model: profile.backend == .local ? profile.localModel : profile.endpointModel, createdAt: Date())
                if self.cache[key] == nil { self.cacheOrder.append(key) }
                self.cache[key] = record
                // Contexts dominate memory, so both entry count and retained UTF-8 bytes are bounded.
                while self.cacheOrder.count > 48 || self.cacheBytes > 4 * 1_024 * 1_024 {
                    self.cache.removeValue(forKey: self.cacheOrder.removeFirst())
                }
                persist?(record)
                return record
            }
        }
    }
    /// Basic and detail keys include their task and accepted pair. A detail for a previous
    /// interpretation cannot leak through the legacy target-only explanation cache.
    func lookup(_ input: LearningLookupInput, requestID: String, refresh: Bool) async throws -> LearningLookupRecord {
        let profile = model.profile.snapshot, language = language, epoch = notebookEpoch
        let key = LookupKey(input: input, language: language, profile: profile)
        if !refresh, let record = lookupCache[key] { try Task.checkCancellation(); return record }
        let result = try await lookupValue(input, basic: nil, requestID: requestID) {
            try LearningLookupPolicy.parse($0, input: input)
        }
        guard notebookEpoch == epoch else { throw CancellationError() }
        let record = LearningLookupRecord(input: input, language: language, result: result,
            model: profile.backend == .local ? profile.localModel : profile.endpointModel, createdAt: Date())
        lookupCache[key] = record
        if lookupCache.count > 48 || lookupCacheBytes > 4 * 1_024 * 1_024 { lookupCache = [key: record] }
        return record
    }

    func explainLookup(_ basic: LearningLookupRecord, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
        guard basic.language == language else { throw CancellationError() }
        let profile = model.profile.snapshot, epoch = notebookEpoch
        let persist = capturePersistence.map { $0() } ?? didExplain
        let key = LookupKey(input: basic.input, language: language, profile: profile, basic: basic.result)
        if !refresh, let record = detailCache[key] { try Task.checkCancellation(); return record }
        let text = try await lookupValue(basic.input, basic: basic.result, requestID: requestID,
            parse: LearningLookupPolicy.parseDetails)
        guard notebookEpoch == epoch else { throw CancellationError() }
        let record = LearningExplanationRecord(id: UUID(), input: basic.input.target, language: basic.language,
            result: .init(meaning: basic.result.meaning, explanation: text),
            model: profile.backend == .local ? profile.localModel : profile.endpointModel, createdAt: Date())
        detailCache[key] = record
        if detailCache.count > 48 || detailCacheBytes > 4 * 1_024 * 1_024 { detailCache = [key: record] }
        persist?(record)
        return record
    }

    private func lookupValue<Value>(_ input: LearningLookupInput, basic: LearningLookupResult?, requestID: String,
                                    parse: (String) throws -> Value) async throws -> Value {
        let profile = model.profile.snapshot, language = language, epoch = notebookEpoch
        try Task.checkCancellation()
        let lease = model.reserveInstructionRequest()
        return try await LearningRequestTrace.$requestID.withValue(requestID) {
            try await telemetry.perform(source: .explanation, profile: profile) {
                guard self.isConfigured else {
                    throw LearningFailure.message(String(
                        localized: "Choose a general instruction model for AI explanation.", table: "Learning"))
                }
                try await self.model.validateGeneralInstructionModel()
                let output = min(profile.maximumOutputTokens ?? 1_024, basic == nil ? 512 : 1_024)
                let prompt = try LearningLookupPolicy.prompt(input, language: language, total: profile.contextWindowTokens,
                    output: output, basic: basic)
                @MainActor func validate() throws {
                    try self.model.validateInstructionRequest(lease)
                    try Task.checkCancellation()
                    guard self.model.profile.snapshot == profile, self.language == language, self.notebookEpoch == epoch else {
                        throw CancellationError()
                    }
                }
                try validate()
                var bytes = 0
                // Only the basic pair has a machine-readable envelope. Detail prose stays text;
                // this service attaches it to the immutable accepted pair after validation.
                let grammar = basic == nil
                    ? LearningOutputGrammar.lookup(hasContext: input.target.contextKind != .none) : nil
                let raw = try await self.model.generate(prompt: prompt, maxTokens: output, localGrammar: grammar) { delta in
                    try validate()
                    bytes += delta.utf8.count
                    guard bytes <= 24_000 else { throw VocabularyError.invalidContent }
                }
                try validate()
                let value = try parse(raw)
                LearningRequestTrace.measurement?.usable()
                return value
            }
        }
    }

    /// An account switch invalidates ephemeral context as well as saved drafts. An in-flight
    /// model may finish physically, but epoch checks prevent its result from entering a new cache.
    func resetNotebookScope() {
        notebookEpoch = UUID()
        cache = [:]; cacheOrder = []; lookupCache = [:]; detailCache = [:]
        notebookChanges.send()
    }

    private var lookupCacheBytes: Int {
        lookupCache.values.reduce(0) { total, record in
            let inputBytes = lookupInputBytes(record.input)
            let resultBytes = record.result.meaning.utf8.count + record.result.sentenceTranslation.utf8.count
            return total + inputBytes + record.model.utf8.count + resultBytes
        }
    }
    private var detailCacheBytes: Int {
        detailCache.reduce(0) { total, entry in
            let inputBytes = lookupInputBytes(entry.key.input)
            let basicMeaningBytes = entry.key.basic?.meaning.utf8.count ?? 0
            let basicTranslationBytes = entry.key.basic?.sentenceTranslation.utf8.count ?? 0
            let resultBytes = entry.value.result.explanation.utf8.count + entry.value.model.utf8.count
            return total + inputBytes + resultBytes + basicMeaningBytes + basicTranslationBytes
        }
    }
    private func lookupInputBytes(_ input: LearningLookupInput) -> Int {
        let targetBytes = input.target.target.utf8.count + input.target.dictionaryForm.utf8.count
        let contextBytes = input.target.context.utf8.count + input.referenceTranslation.utf8.count
        let identityBytes = input.target.occurrenceIdentity?.utf8.count ?? 0
        return targetBytes + contextBytes + identityBytes + input.target.ranges.count * 16
    }
    private var cacheBytes: Int {
        cache.values.reduce(0) { total, record in
            let targetBytes = record.input.target.utf8.count + record.input.dictionaryForm.utf8.count
            let resultBytes = record.result.meaning.utf8.count + record.result.explanation.utf8.count
            return total + targetBytes + record.input.context.utf8.count + resultBytes
        }
    }
    func recordDisplay(requestID: String) { telemetry.recordDisplay(source: .explanation, requestID: requestID) }
}
