import LingroveNotebook
import LingroveNotebookEngine
import LingroveStudyExport
import Combine
import Foundation
import Logging

/// The environment owns this UI-facing notebook for the process lifetime. Views observe saved
/// values and pending keys; the archive actor owns disk transactions. Monotonic revisions reject
/// a slow load response arriving after a newer save. Logs contain counts and IDs, never content.
@MainActor
final class VocabularyStore: ObservableObject {
    @Published private(set) var semantics = VocabularySemanticIndex()
    @Published private(set) var classification = VocabularyClassificationIndex()
    @Published private(set) var reviewTemplates: [ReviewLayoutTemplate] = []
    @Published private(set) var entries: [VocabularyEntry] = []
    @Published private(set) var pending: Set<String> = []
    @Published private(set) var isLoaded = false
    @Published private(set) var mediaRevision = UUID()
    @Published var errorMessage: String?
    /// E injects its app-owned review navigation. Merely opening it does not save or enroll.
    var onRequestBuiltInReview: ((VocabularySelection?) -> Void)?
    var onRequestReviewTemplates: (() -> Void)?
    @Published private(set) var scopeIdentity = UUID()
    @Published private(set) var operationScope: VocabularyOperationScope?
    let isAvailable: Bool
    var openSelection: ((VocabularySelection?) -> Void)?
    /// Composition supplies cached annotations only; saving a favorite never starts a model.
    var enrichCapture: ((VocabularyCapture) -> VocabularyCapture)?
    private let archive: VocabularyArchive?
    private let repository: MacNotebookRepository?
    private let unavailableError: (any Error)?
    private var explanationScopeSubscription: AnyCancellable?
    private var repositorySubscription: AnyCancellable?
    private var loadIdentity = UUID()
    private var reloadRequested = false
    private var isShutDown = false
    private var activeAccesses = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadWork: Task<Void, Never>?
    @Published private(set) var canUndoSenseMerge = false
    private var senseMergeUndo: VocabularySenseMergeUndo?
    private var revision: UInt64 = 0
    var currentRevision: UInt64 { revision }
    private var savedKeys: Set<String> = []
    private var pendingCounts: [String: Int] = [:]
    private var entryKeys: Set<String> = []

    /// Standalone fixtures retain the same public surface without discovering application data.
    init(archive: VocabularyArchive) {
        self.archive = archive; repository = nil; unavailableError = nil; isAvailable = true
    }

    /// The composition root owns repository lifetime. The worker only receives immutable URLs;
    /// Combine carries content-free committed-change notifications back to this UI projection.
    init(repository: MacNotebookRepository) {
        self.repository = repository
        archive = VocabularyArchive(url: repository.databaseURL, mediaDirectoryURL: repository.mediaDirectoryURL,
            installsBundledClassification: true)
        unavailableError = nil; isAvailable = true
        operationScope = try? repository.snapshot()
        repositorySubscription = repository.$changeSequence.dropFirst().sink { [weak self] _ in
            self?.repositoryDidChange()
        }
    }

    private init(unavailable error: any Error) {
        archive = nil; repository = nil; unavailableError = error; isAvailable = false
        errorMessage = String(localized: "The notebook is unavailable. Your original data has been preserved.", table: "Vocabulary")
    }

    /// Opening the shared database may fail without preventing autocomplete/translation startup.
    /// This mode owns no replacement directory and every persistence request fails explicitly.
    static func unavailable(_ error: any Error) -> VocabularyStore { VocabularyStore(unavailable: error) }

    /// Composition calls this once in place of the old unscoped didExplain closure. Saved
    /// annotations are optional enrichment; a translation/explanation never collects a sense.
    func connectExplanations(to service: LearningExplanationService) {
        service.didExplain = nil
        service.capturePersistence = { [weak self] in
            guard let self, isAvailable, let scope = operationScope else { return nil }
            return { [weak self] record in
                Task { await self?.saveExplanation(record, scope: scope) }
            }
        }
        service.loadPersisted = { [weak self] input, language in
            guard let self else { return nil }
            let identity = scopeIdentity
            await load()
            guard identity == scopeIdentity else { return nil }
            return explanation(for: input, language: language)
        }
        service.lookupSaved = { [weak self] input, language in self?.explanation(for: input, language: language) }
        enrichCapture = { [weak service] capture in service?.enrich(capture) ?? capture }
        explanationScopeSubscription = $scopeIdentity.dropFirst().sink { [weak service] _ in service?.resetNotebookScope() }
    }

    func matches(_ scope: VocabularyOperationScope?) -> Bool {
        guard isAvailable, !isShutDown else { return false }
        guard let scope else { return repository == nil }
        if let repository {
            guard let current = try? repository.version() else { return false }
            return current.hasSameOwner(as: scope)
        }
        return operationScope?.hasSameOwner(as: scope) == true
    }

    private func access<T: Sendable>(
        scope: VocabularyOperationScope? = nil,
        _ operation: @Sendable (isolated VocabularyArchive) throws -> T
    ) async throws -> T {
        guard !isShutDown else { throw VocabularyError.editConflict }
        guard let archive else { throw unavailableError ?? VocabularyError.invalidArchive }
        activeAccesses += 1
        defer {
            activeAccesses -= 1
            if activeAccesses == 0 {
                let waiters = drainWaiters; drainWaiters = []
                for waiter in waiters { waiter.resume() }
            }
        }
        let live = try repository?.version()
        let original = scope.map(LingroveNotebookVersion.init) ?? live ?? operationScope.map(LingroveNotebookVersion.init)
        if let scope, let live, !live.hasSameOwner(as: scope) { throw VocabularyError.editConflict }
        let result = try await archive.perform(basedOn: original, operation)
        if !isShutDown, let repository, let live, let after = try? repository.version(),
           after.hasSameOwner(as: live), after.revision != live.revision { repository.publishChange() }
        return result
    }

    /// The mailbox borrows this process-wide store. Applying the archive's acknowledged snapshot
    /// refreshes an already-open notebook immediately; CLI failures stay in their JSON response.
    func executeCLI(_ request: CLIRequest) async -> CLIReply {
        guard isAvailable else {
            return .failure(request.id, .init(code: .unavailable,
                message: "The notebook is unavailable; its original data has been preserved."))
        }
        do {
            let (result, snapshot) = try await access { archive in try archive.executeCLI(request) }
            apply(snapshot)
            return .init(requestID: request.id, ok: true, result: result)
        } catch let error as CLIError {
            return .failure(request.id, error)
        } catch VocabularyError.editConflict {
            return .failure(request.id, .init(code: .conflict, message: "Notebook changed. Read it again before writing."))
        } catch VocabularyError.storageBusy {
            return .failure(request.id, .init(code: .busy, message: "Notebook is busy; retry the same idempotency key."))
        } catch VocabularyError.invalidContent {
            return .failure(request.id, .invalid("Content violates notebook limits or invariants."))
        } catch {
            return .failure(request.id, .init(code: .io, message: "Notebook operation failed. Check the app's storage status."))
        }
    }

    func loadIfNeeded() {
        guard isAvailable, !isShutDown, !isLoaded, loadWork == nil else { return }
        let identity = loadIdentity
        loadWork = Task { [weak self] in
            guard let self, loadIdentity == identity else { return }
            // A local commit can apply its acknowledged snapshot before its own notification's
            // queued reload starts. That result already contains the saved content and revision.
            guard !isLoaded else { loadWork = nil; reloadRequested = false; return }
            do {
                let snapshot = try await access { archive in try archive.load() }
                guard loadIdentity == identity else { return }
                apply(snapshot)
            } catch { if loadIdentity == identity { report(error) } }
            if loadIdentity == identity {
                loadWork = nil
                if reloadRequested { reloadRequested = false; isLoaded = false; loadIfNeeded() }
            }
        }
    }

    /// Reuse the single in-flight load when a card requests a saved explanation before browsing.
    func load() async { loadIfNeeded(); await loadWork?.value }

    func contains(_ capture: VocabularyCapture) -> Bool {
        if capture.example == nil {
            guard let sense = capture.senseID else { return entryKeys.contains(VocabularyPolicy.entryKey(capture)) }
            return entries.contains { VocabularyPolicy.entryKey($0) == VocabularyPolicy.entryKey(capture) &&
                VocabularySensePolicy.index(sense, in: $0) != nil }
        }
        if capture.senseID != nil { return VocabularyPolicy.contains(capture, in: entries) }
        return savedKeys.contains(VocabularyPolicy.captureKey(capture))
    }
    func isPending(_ capture: VocabularyCapture) -> Bool { pending.contains(VocabularyPolicy.captureKey(capture)) }

    func save(_ capture: VocabularyCapture, scope: VocabularyOperationScope? = nil) async {
        let enriched = enrichCapture?(capture) ?? capture
        await change(capture) { try await self.access(scope: scope) { archive in try archive.save(enriched) } }
    }

    func saveExplanation(_ record: LearningExplanationRecord, scope: VocabularyOperationScope? = nil) async {
        do { apply(try await access(scope: scope) { archive in try archive.saveExplanation(record) }) } catch { report(error) }
    }

    func explanation(for input: LearningExplanationInput, language: LearningLanguage) -> LearningExplanationRecord? {
        entries.lazy.flatMap { $0.explanations ?? [] }.last { $0.input == input && $0.language == language }
    }

    /// A record can be reused across identical contexts, but its write destination is explicit.
    /// In particular, two usages with different translation languages must not alias on adoption.
    func explanationDestination(_ capture: VocabularyCapture) -> VocabularyExplanationDestination? {
        guard let entry = entries.first(where: { VocabularyPolicy.entryKey($0) == VocabularyPolicy.entryKey(capture) }) else { return nil }
        var destination = VocabularySensePolicy.destination(capture, in: entry)
        destination?.scope = operationScope
        return destination
    }

    func userMeaning(at destination: VocabularyExplanationDestination) -> String? {
        guard let entry = entries.first(where: { $0.id == destination.entryID }) else { return nil }
        if let id = destination.exampleID {
            return entry.senses.first { $0.examples.contains { $0.id == id } && $0.meaningOrigin == .user }?.meaning
        }
        guard let index = VocabularySensePolicy.index(destination.senseID, in: entry) else { return nil }
        let sense = entry.senses[index]
        return sense.meaningOrigin == .user ? sense.meaning : nil
    }

    func adoptExplanation(_ record: LearningExplanationRecord, at destination: VocabularyExplanationDestination) async -> Bool {
        guard matches(destination.scope), let original = entries.first(where: { $0.id == destination.entryID }) else { return false }
        var edited = original
        if let exampleID = destination.exampleID {
            // A move can finish while the model runs. Stable usage identity resolves its current
            // owner; a late reply must never recreate the old sense or an already deleted usage.
            guard let owner = original.senses.firstIndex(where: { $0.examples.contains { $0.id == exampleID } }),
                  let index = original.senses[owner].examples.firstIndex(where: { $0.id == exampleID }),
                  LearningExplanationPolicy.input(LearningExplanationPolicy.capture(original, sense: original.senses[owner],
                    example: original.senses[owner].examples[index])) == record.input else { return false }
            edited.senses[owner].meaning = record.result.meaning
            edited.senses[owner].meaningLanguage = record.language
            edited.senses[owner].meaningOrigin = .user
        } else {
            guard let owner = VocabularySensePolicy.index(destination.senseID, in: original),
                  original.senses[owner].supportsGeneralExplanation,
                  LearningExplanationPolicy.input(LearningExplanationPolicy.capture(original, sense: original.senses[owner],
                    example: nil)) == record.input else { return false }
            edited.senses[owner].meaning = record.result.meaning
            edited.senses[owner].meaningLanguage = record.language
            edited.senses[owner].meaningOrigin = .user
        }
        return await update(edited, basedOn: original, scope: destination.scope)
    }

    /// Bool-returning UI commands keep failures on the observable store; throwing import/Anki
    /// commands below return their errors to the requesting sheet or structured CLI response.
    private func mutation(
        scope: VocabularyOperationScope? = nil,
        _ operation: @Sendable (isolated VocabularyArchive) throws -> VocabularyArchiveSnapshot
    ) async -> Bool {
        do { apply(try await access(scope: scope, operation)); return true } catch { report(error); return false }
    }

    func mergeSenses(entryID: UUID, source: UUID, target: UUID, scope: VocabularyOperationScope? = nil,
                     expectedRevision: UInt64? = nil) async -> Bool {
        do {
            let (snapshot, undo) = try await access(scope: scope) { archive in
                try archive.mergeSensesWithUndo(entryID: entryID, source: source, target: target,
                    expectedRevision: expectedRevision)
            }
            apply(snapshot)
            guard matches(undo.after), revision == undo.after.revision else { return true }
            senseMergeUndo = undo; canUndoSenseMerge = true
            return true
        } catch { report(error); return false }
    }

    func undoLastSenseMerge() async -> VocabularySelection? {
        guard let undo = senseMergeUndo else { return nil }
        do {
            let snapshot = try await access(scope: undo.after) { archive in try archive.undoSenseMerge(undo) }
            apply(snapshot)
            return undo.selection
        } catch { report(error); return nil }
    }

    func moveExample(
        entryID: UUID, exampleID: UUID, source: UUID, target: UUID?, scope: VocabularyOperationScope? = nil
    ) async -> Bool {
        await mutation(scope: scope) { archive in
            try archive.moveExample(entryID: entryID, exampleID: exampleID, source: source, target: target)
        }
    }

    func createSense(entryID: UUID, scope: VocabularyOperationScope? = nil) async -> UUID? {
        let id = UUID()
        let saved = await mutation(scope: scope) { archive in try archive.createSense(entryID: entryID, senseID: id) }
        return saved ? id : nil
    }

    /// Confirmation plans against the current document in the original business lifetime.
    /// A stale field merge or SQL CAS failure publishes no partial import or relationship.
    func addEntries(
        _ inputs: [VocabularyEntryInput], scope: VocabularyOperationScope? = nil
    ) async throws -> VocabularyEntryImportResult {
        let (snapshot, result) = try await access(scope: scope) { archive in try archive.addEntries(inputs) }
        apply(snapshot)
        return result
    }

    func removeSense(entryID: UUID, senseID: UUID, scope: VocabularyOperationScope? = nil) async -> Bool {
        await mutation(scope: scope) { archive in try archive.removeSense(entryID: entryID, senseID: senseID) }
    }

    func updateSemantics(
        _ value: VocabularySemanticIndex, basedOn baseline: VocabularySemanticIndex, scope: VocabularyOperationScope? = nil
    ) async -> Bool {
        await mutation(scope: scope) { archive in try archive.updateSemantics(value, basedOn: baseline) }
    }

    func updateMeaningOrganization(
        _ semantics: VocabularySemanticIndex, basedOn semanticBaseline: VocabularySemanticIndex,
        classification: VocabularyClassificationIndex, basedOn classificationBaseline: VocabularyClassificationIndex,
        scope: VocabularyOperationScope? = nil
    ) async -> Bool {
        await mutation(scope: scope) { archive in
            try archive.updateMeaningOrganization(semantics, basedOn: semanticBaseline,
                classification: classification, basedOn: classificationBaseline)
        }
    }

    func updateClassification(
        _ value: VocabularyClassificationIndex, basedOn baseline: VocabularyClassificationIndex, scope: VocabularyOperationScope? = nil
    ) async -> Bool {
        await mutation(scope: scope) { archive in try archive.updateClassification(value, basedOn: baseline) }
    }

    func saveReview(
        entryID: UUID, senseID: UUID, value: VocabularyReview, expected: VocabularyReview?, cardID: UUID? = nil,
        importedImages: [String: Data] = [:], scope: VocabularyOperationScope? = nil
    ) async throws {
        apply(try await access(scope: scope) { archive in
            try archive.saveReview(entryID: entryID, senseID: senseID, value: value, expected: expected,
                cardID: cardID, importedImages: importedImages)
        })
    }

    func recordAnkiBinding(
        entryID: UUID, senseID: UUID, binding: AnkiNoteBinding, cardID: UUID? = nil, scope: VocabularyOperationScope? = nil
    ) async throws {
        apply(try await access(scope: scope) { archive in
            try archive.recordAnkiBinding(entryID: entryID, senseID: senseID, binding: binding, cardID: cardID)
        })
    }

    func removeReview(
        entryID: UUID, senseID: UUID, cardID: UUID, expected: VocabularyReview, scope: VocabularyOperationScope? = nil
    ) async throws {
        apply(try await access(scope: scope) { archive in
            try archive.removeReview(entryID: entryID, senseID: senseID, cardID: cardID, expected: expected)
        })
    }

    func saveTemplate(
        _ template: ReviewLayoutTemplate, importedImages: [String: Data] = [:], scope: VocabularyOperationScope? = nil
    ) async throws {
        apply(try await access(scope: scope) { archive in try archive.saveTemplate(template, importedImages: importedImages) })
    }

    func removeTemplate(_ id: UUID, scope: VocabularyOperationScope? = nil) async throws {
        apply(try await access(scope: scope) { archive in try archive.removeTemplate(id) })
    }

    func remove(_ capture: VocabularyCapture, scope: VocabularyOperationScope? = nil) async {
        LingroveLogger.learning.debug("Vocabulary remove requested")
        await change(capture) { try await self.access(scope: scope) { archive in try archive.remove(capture) } }
    }

    func update(
        _ entry: VocabularyEntry, basedOn baseline: VocabularyEntry, importedImages: [String: Data] = [:],
        scope: VocabularyOperationScope? = nil
    ) async -> Bool {
        await mutation(scope: scope) { archive in try archive.update(entry, basedOn: baseline, importedImages: importedImages) }
    }

    func prepareImage(_ data: Data) async throws -> VocabularyPreparedImage {
        try await access { archive in try archive.prepareImage(data) }
    }
    func prepareImage(at url: URL) async throws -> VocabularyPreparedImage {
        try await access { archive in try archive.prepareImage(at: url) }
    }
    func image(_ reference: VocabularyImageReference, scope: VocabularyOperationScope? = nil) async -> Data? {
        try? await access(scope: scope) { archive in try archive.image(reference) }
    }

    func backup(to url: URL, scope: VocabularyOperationScope? = nil) async {
        do { try await access(scope: scope) { archive in try archive.backup(to: url) } } catch { report(error) }
    }
    func restore(from url: URL, scope: VocabularyOperationScope? = nil) async {
        if await mutation(scope: scope, { archive in try archive.restore(from: url) }) { mediaRevision = UUID() }
    }

    func remove(id: UUID, scope: VocabularyOperationScope? = nil) async -> Bool {
        await mutation(scope: scope) { archive in try archive.remove(id: id) }
    }

    func prepareExport(
        selections: [VocabularySelection], configuration: VocabularyExportConfiguration, scope: VocabularyOperationScope? = nil
    ) async throws -> VocabularyExportPackage {
        try await access(scope: scope) { archive in try archive.prepareExport(selections: selections, configuration: configuration) }
    }

    func writeExport(_ package: VocabularyExportPackage, to url: URL, scope: VocabularyOperationScope? = nil) async throws {
        try await access(scope: scope) { archive in try archive.writeExport(package, to: url) }
        LingroveLogger.learning.info("Vocabulary exported", metadata: ["format": .string(package.configuration.format.rawValue),
            "senses": .stringConvertible(package.senseCount), "with_images": .stringConvertible(package.configuration.includesImages)])
    }

    func export(to url: URL, scope: VocabularyOperationScope? = nil) async {
        do { try await access(scope: scope) { archive in try archive.export(to: url) } } catch { report(error) }
    }

    func show(_ capture: VocabularyCapture) {
        let destination = explanationDestination(capture)
        let selection = destination.map { VocabularySelection(entryID: $0.entryID, senseID: $0.senseID) }
            ?? entries.first { VocabularyPolicy.entryKey($0) == VocabularyPolicy.entryKey(capture) }.flatMap { entry in
                entry.senses.first.map { VocabularySelection(entryID: entry.id, senseID: $0.id) }
            }
        LingroveLogger.learning.debug("Vocabulary open requested", metadata: [
            "sense_found": .stringConvertible(selection != nil), "handler_available": .stringConvertible(openSelection != nil)
        ])
        openSelection?(selection)
    }

    private func change(_ capture: VocabularyCapture, operation: () async throws -> VocabularyArchiveSnapshot) async {
        let identity = scopeIdentity
        let key = VocabularyPolicy.captureKey(capture)
        pendingCounts[key, default: 0] += 1
        if pendingCounts[key] == 1 { pending.insert(key) }
        defer {
            if identity == scopeIdentity {
                let remaining = (pendingCounts[key] ?? 1) - 1
                if remaining == 0 { pendingCounts.removeValue(forKey: key); pending.remove(key) } else { pendingCounts[key] = remaining }
            }
        }
        do { apply(try await operation()) } catch { report(error) }
    }

    private func apply(_ snapshot: VocabularyArchiveSnapshot) {
        guard !isShutDown else { return }
        if let scope = snapshot.scope {
            if let repository {
                guard let current = try? repository.version(), current.hasSameOwner(as: scope) else { return }
                if current.revision > scope.revision {
                    reloadRequested = true; isLoaded = false
                    if loadWork == nil { reloadRequested = false; loadIfNeeded() }
                    return
                }
            }
            if let old = operationScope, !old.hasSameOwner(as: scope) { resetScope(to: scope) }
        }
        guard snapshot.revision >= revision else { return }
        if let scope = snapshot.scope { operationScope = scope }
        if let undo = senseMergeUndo, snapshot.revision != undo.after.revision {
            senseMergeUndo = nil; canUndoSenseMerge = false
        }
        entries = snapshot.document.entries
        semantics = snapshot.document.semantics
        classification = snapshot.document.classification
        entryKeys = Set(entries.filter { !$0.senses.isEmpty }.map(VocabularyPolicy.entryKey))
        savedKeys = Set(entries.flatMap { entry in
            entry.examples.map { VocabularyPolicy.entryKey(entry) + ":" + VocabularyPolicy.exampleKey($0) }
        })
        reviewTemplates = snapshot.document.reviewTemplates ?? []
        revision = snapshot.revision
        isLoaded = true
        errorMessage = nil
        LingroveLogger.learning.debug("Vocabulary updated", metadata: ["entry_count": .stringConvertible(entries.count)])
    }

    /// App termination (and isolated test fixtures) drains workers before the repository closes
    /// or its files are removed. Closing an ordinary vocabulary window never calls this method.
    func shutdown() async {
        isShutDown = true
        senseMergeUndo = nil; canUndoSenseMerge = false
        repositorySubscription = nil; explanationScopeSubscription = nil
        loadWork?.cancel()
        await loadWork?.value
        loadWork = nil
        if activeAccesses > 0 {
            await withCheckedContinuation { continuation in drainWaiters.append(continuation) }
        }
        await archive?.shutdown()
    }

    /// Scope identity is independent of a revision counter: a different account can start at
    /// revision zero. Rebuilding the window subtree discards all unsaved sheets and selections.
    private func resetScope(to scope: VocabularyOperationScope?) {
        loadIdentity = UUID(); loadWork?.cancel(); loadWork = nil; reloadRequested = false
        senseMergeUndo = nil; canUndoSenseMerge = false
        operationScope = scope; scopeIdentity = UUID(); revision = 0; isLoaded = false
        entries = []; semantics = .init(); classification = .init(); reviewTemplates = []
        savedKeys = []; entryKeys = []; pending = []; pendingCounts = [:]
        mediaRevision = UUID(); errorMessage = nil
    }

    private func repositoryDidChange() {
        do {
            guard let current = try repository?.version() else { return }
            if operationScope.map({ current.hasSameOwner(as: $0) }) != true { resetScope(to: nil) }
            if current.revision == revision, operationScope != nil { return }
            // Keep the complete saved draft scope until a fresh read is acknowledged. Same-scope
            // edits can merge; a late response from another generation is rejected by apply().
            isLoaded = false
            if loadWork != nil { reloadRequested = true } else { loadIfNeeded() }
            mediaRevision = UUID()
        } catch { resetScope(to: nil); report(error) }
    }

    private func report(_ error: Error) {
        guard !isShutDown else { return }
        errorMessage = isAvailable ? error.localizedDescription : String(
            localized: "The notebook is unavailable. Your original data has been preserved.", table: "Vocabulary")
        LingroveLogger.learning.error("Vocabulary operation failed", metadata: ["error_type": .string(String(describing: type(of: error)))])
    }
}
