import Darwin
import Foundation

/// One actor owns one local SQLite notebook. Synchronous transactions serialize read/modify/commit
/// away from MainActor; cached state advances only after the SQL commit succeeds. This is
/// user-triggered work, with no observer, model runtime, or per-keystroke disk activity.
actor VocabularyArchive {
    let url: URL?
    var images: VocabularyImageStorage
    private var document: VocabularyDocument?
    private var revision: UInt64 = 0
    private var database: VocabularySQLiteDatabase?

    /// nil is an isolated in-memory notebook for tests; it never probes the user's real archive.
    init(url: URL?) { self.url = url; images = VocabularyImageStorage(notebook: url) }

    func load() throws -> VocabularySnapshot {
        let database = try persistence()
        if let document, try database.revision() == revision { return .init(revision: revision, document: document) }
        let snapshot = try database.read()
        try validate(snapshot.document)
        document = snapshot.document; revision = snapshot.revision
        return snapshot
    }

    func persistence() throws -> VocabularySQLiteDatabase {
        if let database { return database }
        let value = try VocabularySQLiteDatabase(url: url); database = value; return value
    }

    /// A mutation has already built its candidate from this cached revision. Refreshing here
    /// would disguise an intervening writer as the candidate's baseline and lose its changes.
    func transactionBaseline() throws -> VocabularySnapshot {
        if let document { return .init(revision: revision, document: document) }
        return try load()
    }

    func storageAccess<T>(write: Bool, _ operation: () throws -> T) throws -> T {
        try persistence().access(write: write, operation)
    }

    func save(_ capture: VocabularyCapture) throws -> VocabularySnapshot {
        var next = try load().document
        _ = try VocabularyPolicy.save(capture, in: &next, now: Date())
        return try commit(next)
    }

    func update(_ entry: VocabularyEntry, basedOn baseline: VocabularyEntry,
                importedImages: [String: Data] = [:]) throws -> VocabularySnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { $0.id == entry.id }) else { throw VocabularyError.invalidContent }
        let original = next.entries[index]
        guard baseline.id == entry.id,
              Set(entry.senses.map(\.id)).count == entry.senses.count,
              Set(entry.examples.map(\.id)).count == entry.examples.count else { throw VocabularyError.invalidContent }
        guard entry.language == original.language, entry.kind == original.kind,
              !VocabularyPolicy.normalized(entry.expression).isEmpty else { throw VocabularyError.invalidContent }
        guard !next.entries.contains(where: { $0.id != entry.id && VocabularyPolicy.entryKey($0) == VocabularyPolicy.entryKey(entry) })
        else { throw VocabularyError.invalidContent }
        var merged = original
        merged.expression = try merge(baseline.expression, original.expression, entry.expression)
        merged.dictionaryForm = try merge(baseline.dictionaryForm, original.dictionaryForm, entry.dictionaryForm)
        merged.senses = try mergeSenses(baseline: baseline.senses, current: original.senses, edited: entry.senses)
        merged.updatedAt = Date()
        next.entries[index] = merged
        return try commitWithImages(next, supplied: importedImages)
    }

    /// A sheet edits one sense while cards may append another. Merge by stable IDs and fields;
    /// an explicit conflict is safer than losing a concurrent note, move or user-authored meaning.
    private func mergeSenses(baseline: [VocabularySense], current: [VocabularySense],
                             edited: [VocabularySense]) throws -> [VocabularySense] {
        var result = current
        for value in edited {
            guard let before = baseline.first(where: { $0.id == value.id }) else {
                guard !result.contains(where: { $0.id == value.id || $0.mergedFrom.contains(value.id) }) else {
                    throw VocabularyError.editConflict
                }
                result.append(value); continue
            }
            guard value != before else { continue }
            guard let index = result.firstIndex(where: { $0.id == value.id }) else { throw VocabularyError.editConflict }
            let live = result[index]
            var merged = live
            let meaning = try merge(VocabularyMeaning(text: before.meaning, language: before.meaningLanguage),
                VocabularyMeaning(text: live.meaning, language: live.meaningLanguage),
                VocabularyMeaning(text: value.meaning, language: value.meaningLanguage))
            merged.meaning = meaning.text; merged.meaningLanguage = meaning.language
            if merged.isSavedWithoutContext, value.meaning != before.meaning || value.meaningLanguage != before.meaningLanguage,
               !merged.standaloneMeanings.contains(meaning) { merged.standaloneMeanings.append(meaning) }
            if value.meaning != before.meaning || value.meaningLanguage != before.meaningLanguage ||
                value.meaningOrigin == .user && before.meaningOrigin != .user { merged.meaningOrigin = .user }
            merged.note = try merge(before.note, live.note, value.note)
            merged.tags = try merge(before.tags, live.tags, value.tags)
            merged.content = try merge(before.content, live.content, value.content)
            merged.examples = try mergeExamples(baseline: before.examples, current: live.examples, edited: value.examples)
            merged.updatedAt = Date()
            result[index] = merged
        }
        for before in baseline where !edited.contains(where: { $0.id == before.id }) {
            if let live = result.first(where: { $0.id == before.id }), live != before { throw VocabularyError.editConflict }
            result.removeAll { $0.id == before.id }
        }
        return result
    }

    private func merge<Value: Equatable>(_ baseline: Value, _ current: Value, _ edited: Value) throws -> Value {
        guard edited != baseline else { return current }
        guard current == baseline || current == edited else { throw VocabularyError.editConflict }
        return edited
    }

    /// Example IDs distinguish edits/deletions from captures appended after the editor opened.
    /// Newly typed examples deduplicate by their content; an unrelated live capture is preserved.
    private func mergeExamples(baseline: [VocabularyExample], current: [VocabularyExample],
                               edited: [VocabularyExample]) throws -> [VocabularyExample] {
        var merged = current
        for example in edited {
            guard let before = baseline.first(where: { $0.id == example.id }) else {
                if !merged.contains(where: { VocabularyPolicy.exampleKey($0) == VocabularyPolicy.exampleKey(example) }) {
                    merged.append(example)
                }
                continue
            }
            guard example != before else { continue }
            guard let index = merged.firstIndex(where: { $0.id == example.id }) else { throw VocabularyError.editConflict }
            var editedExample = example
            if example.text != before.text, example.meaning.isEmpty {
                // The editor clears a stale sense when the source changes. That automatic clear
                // is not a user-authored blank; a new explanation may fill the new occurrence.
                editedExample.meaningOrigin = .captured
            } else if example.meaning != before.meaning || example.meaningLanguage != before.meaningLanguage {
                editedExample.meaningOrigin = .user
            }
            merged[index] = try merge(before, merged[index], editedExample)
        }
        for before in baseline where !edited.contains(where: { $0.id == before.id }) {
            if let item = merged.first(where: { $0.id == before.id }), item != before { throw VocabularyError.editConflict }
            merged.removeAll { $0.id == before.id }
        }
        return merged
    }

    func remove(id: UUID) throws -> VocabularySnapshot {
        var next = try load().document
        next.entries.removeAll { $0.id == id }
        return try commit(next)
    }

    func remove(_ capture: VocabularyCapture) throws -> VocabularySnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { VocabularyPolicy.entryKey($0) == VocabularyPolicy.entryKey(capture) }),
              let destination = VocabularySensePolicy.destination(capture, in: next.entries[index]),
              let sense = VocabularySensePolicy.index(destination.senseID, in: next.entries[index]) else {
            return .init(revision: revision, document: next)
        }
        if let id = destination.exampleID {
            next.entries[index].senses[sense].examples.removeAll { $0.id == id }
        } else {
            next.entries[index].senses[sense].standaloneMeanings.removeAll()
            next.entries[index].senses[sense].isSavedWithoutContext = false
            next.entries[index].senses[sense].explanations.removeAll()
        }
        // Removing the exact favorite keeps other senses and their notes. A completely empty
        // captured identity can disappear; annotated identities require an explicit delete.
        let value = next.entries[index].senses[sense]
        if value.examples.isEmpty, !value.isSavedWithoutContext, value.note.isEmpty, value.tags.isEmpty,
           value.meaningOrigin != .user, value.mergedFrom.isEmpty, value.review == nil, (value.reviewCards ?? []).isEmpty,
               (value.content ?? []).isEmpty {
            next.entries[index].senses.remove(at: sense)
        }
        if next.entries[index].senses.isEmpty { next.entries.remove(at: index) }
        return try commit(next)
    }

    func mergeSenses(entryID: UUID, source: UUID, target: UUID) throws -> VocabularySnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { $0.id == entryID }) else { throw VocabularyError.invalidContent }
        try VocabularySensePolicy.merge(source: source, into: target, in: &next.entries[index], now: Date())
        return try commit(next)
    }

    func moveExample(entryID: UUID, exampleID: UUID, source: UUID, target: UUID?) throws -> VocabularySnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { $0.id == entryID }) else { throw VocabularyError.invalidContent }
        _ = try VocabularySensePolicy.move(exampleID: exampleID, from: source, to: target, in: &next.entries[index], now: Date())
        return try commit(next)
    }

    func createSense(entryID: UUID, senseID: UUID) throws -> VocabularySnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { $0.id == entryID }) else { throw VocabularyError.invalidContent }
        let now = Date()
        next.entries[index].senses.append(VocabularySense(id: senseID, meaning: "", createdAt: now, updatedAt: now))
        next.entries[index].updatedAt = now
        return try commit(next)
    }

    func removeSense(entryID: UUID, senseID: UUID) throws -> VocabularySnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { $0.id == entryID }),
              let sense = next.entries[index].senses.firstIndex(where: { $0.id == senseID }) else { throw VocabularyError.invalidContent }
        next.entries[index].senses.remove(at: sense)
        if next.entries[index].senses.isEmpty { next.entries.remove(at: index) }
        return try commit(next)
    }

    /// Review drafts use compare-and-swap rather than whole-entry replacement. A sheet cannot
    /// overwrite a newly merged binding or another window's review edits while HTTP is pending.
    func saveReview(entryID: UUID, senseID: UUID, value: VocabularyReview,
                    expected: VocabularyReview?, cardID: UUID? = nil, importedImages: [String: Data] = [:]) throws -> VocabularySnapshot {
        var next = try load().document
        guard let entry = next.entries.firstIndex(where: { $0.id == entryID }),
              let sense = next.entries[entry].senses.firstIndex(where: { $0.id == senseID }),
              next.entries[entry].senses[sense].reviewValue(cardID) == expected else { throw VocabularyError.editConflict }
        guard cardID == nil || value.plan.id == cardID else { throw VocabularyError.invalidContent }
        next.entries[entry].senses[sense].setReview(value, cardID: cardID)
        return try commitWithImages(next, supplied: importedImages)
    }

    /// A merge may finish during a network write. Resolve the retired sense ID, keep the latest
    /// draft intact, and append the verified receipt. Deleted senses are never resurrected.
    func recordAnkiBinding(entryID: UUID, senseID: UUID, binding: AnkiNoteBinding, cardID: UUID? = nil) throws -> VocabularySnapshot {
        var next = try load().document
        guard let entry = next.entries.firstIndex(where: { $0.id == entryID }),
              let sense = VocabularySensePolicy.index(senseID, in: next.entries[entry]),
              var review = next.entries[entry].senses[sense].reviewValue(cardID) else { throw VocabularyError.editConflict }
        if let index = review.bindings.firstIndex(where: { $0.id == binding.id }) { review.bindings[index] = binding } else {
            review.bindings.append(binding)
            if review.bindings.count > 1 { review.activeBindingID = nil }
        }
        if review.bindings.count == 1 { review.activeBindingID = binding.id }
        next.entries[entry].senses[sense].setReview(review, cardID: cardID)
        return try commit(next)
    }

    func export(to destination: URL) throws {
        try validateBackupDestination(destination)
        let data = try Self.encoded(load().document)
        try writeAtomically(data, to: destination)
    }

    func saveExplanation(_ record: LearningExplanationRecord) throws -> VocabularySnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { VocabularyPolicy.accepts(record, entry: $0) }) else {
            return .init(revision: revision, document: next)
        }
        VocabularyPolicy.storeExplanation(record, in: &next.entries[index])
        return try commit(next)
    }

    func commit(_ document: VocabularyDocument, receipt: VocabularyCLIReceipt? = nil) throws -> VocabularySnapshot {
        try storageAccess(write: true) { try commitUnlocked(document, receipt: receipt) }
    }

    private func commitUnlocked(_ document: VocabularyDocument, receipt: VocabularyCLIReceipt?) throws -> VocabularySnapshot {
        // Fixtures/restores may commit before browsing has loaded the notebook. Establish the
        // same baseline and durable revision that ordinary card/editor operations use.
        let baseline = try transactionBaseline()
        var next = document
        // Explanation snapshots remain attached to their exact current input. A moved usage
        // retains them intact; editing its text cannot relabel an old answer as a current one.
        for index in next.entries.indices {
            let entry = next.entries[index]
            for sense in entry.senses.indices {
                let value = entry.senses[sense]
                let generalInput = LearningExplanationPolicy.input(LearningExplanationPolicy.capture(entry, sense: value, example: nil))
                next.entries[index].senses[sense].explanations = value.explanations.filter {
                    value.supportsGeneralExplanation && $0.input == generalInput
                }
                for usage in value.examples.indices {
                    let input = LearningExplanationPolicy.input(
                        LearningExplanationPolicy.capture(entry, sense: value, example: value.examples[usage]))
                    next.entries[index].senses[sense].examples[usage].explanations = value.examples[usage].explanations.filter {
                        $0.input == input
                    }
                }
            }
        }
        try validate(next)
        let nextRevision = try persistence().write(next, previous: baseline.document, expectedRevision: baseline.revision, receipt: receipt)
        let previousImages = Self.imageReferences(self.document ?? VocabularyDocument())
        let retained = Set(Self.imageReferences(next).map(\.filename))
        self.document = next
        revision = nextRevision
        for image in previousImages where !retained.contains(image.filename) { images.remove(image) }
        return .init(revision: revision, document: next)
    }

    /// Validate the whole ownership graph on load and every write. UUID uniqueness includes
    /// retired aliases, preventing a later merge or edit from giving one identity two owners.
    func validate(_ document: VocabularyDocument) throws {
        guard document.schemaVersion == 3,
              Set(document.entries.map(VocabularyPolicy.entryKey)).count == document.entries.count else {
            throw VocabularyError.invalidArchive
        }
        try validateTemplates(document.reviewTemplates ?? [])
        var ids = Set<UUID>()
        for entry in document.entries {
            guard ids.insert(entry.id).inserted, !VocabularyPolicy.normalized(entry.expression).isEmpty, !entry.senses.isEmpty else {
                throw VocabularyError.invalidArchive
            }
            guard Set(entry.examples.map { VocabularyPolicy.exampleKey($0) }).count == entry.examples.count,
                  entry.senses.filter(\.isSavedWithoutContext).count <= 1 else { throw VocabularyError.invalidArchive }
            for sense in entry.senses {
                try VocabularyContentPolicy.validate(sense.content ?? [])
                try validateBlockIdentities(sense.content ?? [], ids: &ids)
                if let review = sense.review { try validateReview(review) }
                try validateCards(sense.reviewCards ?? [], ids: &ids)
                let generalInput = LearningExplanationPolicy.input(LearningExplanationPolicy.capture(entry, sense: sense, example: nil))
                guard ids.insert(sense.id).inserted, sense.mergedFrom.allSatisfy({ ids.insert($0).inserted }),
                      sense.explanations.count <= 128,
                      sense.explanations.allSatisfy({
                          LearningExplanationPolicy.isValid($0.input) && LearningExplanationPolicy.isValid($0.result) &&
                              $0.input == generalInput
                      })
                else { throw VocabularyError.invalidArchive }
                for usage in sense.examples {
                    let usageInput = LearningExplanationPolicy.input(LearningExplanationPolicy.capture(entry, sense: sense, example: usage))
                    guard ids.insert(usage.id).inserted, !usage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          usage.text.utf8.count <= 262_144,
                          usage.ranges.allSatisfy({ VocabularyPolicy.valid($0.nsRange, in: usage.text) }),
                          usage.explanations.count <= 24, usage.explanations.allSatisfy({
                              LearningExplanationPolicy.isValid($0.input) && LearningExplanationPolicy.isValid($0.result) &&
                                  $0.input == usageInput
                          }) else { throw VocabularyError.invalidArchive }
                }
            }
        }
    }

    func validateReview(_ review: VocabularyReview) throws {
        guard review.bindings.count <= 64, review.preservedPlans.count <= 64,
              Set(review.bindings.map(\.id)).count == review.bindings.count,
              review.activeBindingID == nil || review.bindings.contains(where: { $0.id == review.activeBindingID }) else {
            throw VocabularyError.invalidArchive
        }
        for plan in [review.plan] + review.preservedPlans {
            if let layout = plan.layout { try ReviewLayoutPolicy.validate(layout) }
            guard (plan.name?.utf8.count ?? 0) <= 1024, (plan.answer?.utf8.count ?? 0) <= 262_144, plan.fieldOverrides.count <= 32,
                  plan.fieldOverrides.allSatisfy({ $0.key.utf8.count <= 200 && $0.value.utf8.count <= 1_000_000 }) else {
                throw VocabularyError.invalidArchive
            }
        }
        for plan in [review.plan] + review.preservedPlans {
            guard (plan.audioReceipts?.count ?? 0) <= 2,
                  plan.audioReceipts?.values.allSatisfy({
                      $0.fingerprint.count == 64 && $0.textHash.count == 64 && SpeechExportPolicy.validFilename($0.filename) &&
                      AnkiReviewPolicy.endpoint($0.endpoint) != nil && !$0.profile.isEmpty
                  }) ?? true else { throw VocabularyError.invalidArchive }
        }
        for binding in review.bindings {
            guard binding.noteID.map({ $0 > 0 }) ?? true, !binding.profile.isEmpty, !binding.model.isEmpty,
                  AnkiReviewPolicy.endpoint(binding.endpoint) != nil, binding.mapping[.identity] == binding.identityField,
                  binding.fields[binding.identityField] == binding.originSenseID.uuidString.lowercased(),
                  binding.fields.count <= 32, binding.fields.allSatisfy({ $0.value.utf8.count <= 1_000_000 }) else {
                throw VocabularyError.invalidArchive
            }
        }
    }

    private static func encoded(_ document: VocabularyDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// Stage with owner-only permissions, synchronize and atomically rename within the same
    /// directory. No fallible operation follows the commit, so UI and disk cannot disagree after
    /// a successful rename. The actor is the sole in-process writer for this file.
    /// Export may cancel before commit; notebook edits retain their existing transaction semantics
    /// even if their originating view disappears while the write is finishing.
    func writeAtomically(_ data: Data, to url: URL, cancellable: Bool = false) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".notebook-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        if cancellable { try Task.checkCancellation() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        if cancellable { try Task.checkCancellation() }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
