import Darwin
import Foundation

/// One actor owns one local archive. Its synchronous transactions serialize read/modify/atomic
/// write away from MainActor; cached state advances only after the replacement succeeds. This is
/// user-triggered work, with no observer, model runtime, or per-keystroke disk activity.
actor VocabularyArchive {
    private let url: URL?
    private var document: VocabularyDocument?
    private var revision: UInt64 = 0
    static let maximumBytes = 64 * 1_024 * 1_024

    /// nil is an isolated in-memory notebook for tests; it never probes the user's real archive.
    init(url: URL?) { self.url = url }

    func load() throws -> VocabularySnapshot {
        if let document { return .init(revision: revision, document: document) }
        let loaded: VocabularyDocument
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumBytes else { throw VocabularyError.oversizedArchive }
            do {
                loaded = try JSONDecoder().decode(VocabularyDocument.self, from: Data(contentsOf: url))
            } catch { throw VocabularyError.invalidArchive }
            guard loaded.schemaVersion == 2 else { throw VocabularyError.unsupportedVersion }
            guard Set(loaded.entries.map(\.id)).count == loaded.entries.count else { throw VocabularyError.invalidArchive }
            guard Set(loaded.entries.map(VocabularyPolicy.entryKey)).count == loaded.entries.count,
                  loaded.entries.allSatisfy({ entry in
                    !VocabularyPolicy.normalized(entry.expression).isEmpty &&
                        (entry.explanations?.count ?? 0) <= 24 && (entry.explanations ?? []).allSatisfy {
                            LearningExplanationPolicy.isValid($0.input) && VocabularyPolicy.accepts($0, entry: entry) &&
                                LearningExplanationPolicy.isValid($0.result)
                        } &&
                        Set(entry.examples.map(\.id)).count == entry.examples.count && entry.examples.allSatisfy { example in
                            !example.text.isEmpty && example.ranges.allSatisfy { VocabularyPolicy.valid($0.nsRange, in: example.text) }
                        }
                  }) else { throw VocabularyError.invalidArchive }
        } else { loaded = VocabularyDocument() }
        document = loaded
        return .init(revision: revision, document: loaded)
    }

    func save(_ capture: VocabularyCapture) throws -> VocabularySnapshot {
        var next = try load().document
        _ = try VocabularyPolicy.save(capture, in: &next, now: Date())
        return try commit(next)
    }

    func update(_ entry: VocabularyEntry, basedOn baseline: VocabularyEntry) throws -> VocabularySnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { $0.id == entry.id }) else { throw VocabularyError.invalidContent }
        let original = next.entries[index]
        guard baseline.id == entry.id else { throw VocabularyError.invalidContent }
        guard entry.language == original.language, entry.kind == original.kind,
              !VocabularyPolicy.normalized(entry.expression).isEmpty,
              entry.examples.allSatisfy({ example in
                  !example.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && example.text.utf8.count <= 262_144 &&
                      example.ranges.allSatisfy { VocabularyPolicy.valid($0.nsRange, in: example.text) }
              })
        else { throw VocabularyError.invalidContent }
        guard !next.entries.contains(where: { $0.id != entry.id && VocabularyPolicy.entryKey($0) == VocabularyPolicy.entryKey(entry) })
        else { throw VocabularyError.invalidContent }
        var merged = original
        // Three-way field edits preserve examples collected while the sheet was open. If two
        // editors changed the same field, report the conflict instead of silently choosing one.
        merged.expression = try merge(baseline.expression, original.expression, entry.expression)
        merged.dictionaryForm = try merge(baseline.dictionaryForm, original.dictionaryForm, entry.dictionaryForm)
        let meaning = try merge(VocabularyMeaning(text: baseline.meaning, language: baseline.meaningLanguage),
            VocabularyMeaning(text: original.meaning, language: original.meaningLanguage),
            VocabularyMeaning(text: entry.meaning, language: entry.meaningLanguage))
        merged.meaning = meaning.text
        merged.meaningLanguage = meaning.language
        if entry.meaning != baseline.meaning || entry.meaningLanguage != baseline.meaningLanguage ||
            entry.meaningOrigin == .user && baseline.meaningOrigin != .user {
            merged.meaningOrigin = .user
        }
        if entry.meaning != baseline.meaning || entry.meaningLanguage != baseline.meaningLanguage,
           merged.isSavedWithoutContext {
            if let index = merged.standaloneMeanings.firstIndex(where: { $0.language == meaning.language }) {
                merged.standaloneMeanings[index] = meaning
            } else { merged.standaloneMeanings.append(meaning) }
        }
        merged.note = try merge(baseline.note, original.note, entry.note)
        merged.tags = try merge(baseline.tags, original.tags, entry.tags)
        merged.examples = try mergeExamples(baseline: baseline.examples, current: original.examples, edited: entry.examples)
        if merged.examples.isEmpty, !merged.isSavedWithoutContext {
            // Deleting the last example normally keeps the word itself. If another action
            // explicitly removed its standalone save meanwhile, do not recreate that save.
            guard !baseline.isSavedWithoutContext else { throw VocabularyError.editConflict }
            merged.isSavedWithoutContext = true
            merged.standaloneMeanings = [VocabularyMeaning(text: merged.meaning, language: merged.meaningLanguage)]
        }
        next.entries[index] = merged
        next.entries[index].updatedAt = Date()
        return try commit(next)
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
                editedExample.captureIdentity = before.captureIdentity ?? .init(meaningLanguage: before.meaningLanguage)
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
        guard let index = next.entries.firstIndex(where: { VocabularyPolicy.entryKey($0) == VocabularyPolicy.entryKey(capture) })
        else { return .init(revision: revision, document: next) }
        if capture.example != nil {
            next.entries[index].examples.removeAll { VocabularyPolicy.exampleKey($0) == VocabularyPolicy.exampleKey(capture.example) }
        } else {
            next.entries[index].standaloneMeanings.removeAll { $0.language == capture.meaningLanguage }
            next.entries[index].isSavedWithoutContext = !next.entries[index].standaloneMeanings.isEmpty
        }
        // Removing this occurrence must not erase examples collected in other contexts.
        if !next.entries[index].isSavedWithoutContext && next.entries[index].examples.isEmpty { next.entries.remove(at: index) }
        return try commit(next)
    }

    func export(to destination: URL) throws {
        guard destination.standardizedFileURL != url?.standardizedFileURL else { throw VocabularyError.invalidContent }
        let data = try Self.encoded(load().document)
        try data.write(to: destination, options: .atomic)
    }

    func saveExplanation(_ record: LearningExplanationRecord) throws -> VocabularySnapshot {
        var next = try load().document
        guard let index = next.entries.firstIndex(where: { VocabularyPolicy.accepts(record, entry: $0) }) else {
            return .init(revision: revision, document: next)
        }
        VocabularyPolicy.storeExplanation(record, in: &next.entries[index])
        return try commit(next)
    }

    private func commit(_ document: VocabularyDocument) throws -> VocabularySnapshot {
        var next = document
        // Removing/editing a usage also removes its retained explanation context from exports.
        for index in next.entries.indices {
            let entry = next.entries[index]
            next.entries[index].explanations = entry.explanations?.filter { VocabularyPolicy.accepts($0, entry: entry) }
        }
        let data = try Self.encoded(next)
        guard data.count <= Self.maximumBytes else { throw VocabularyError.oversizedArchive }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try writeAtomically(data, to: url)
        }
        self.document = next
        revision &+= 1
        return .init(revision: revision, document: next)
    }

    private static func encoded(_ document: VocabularyDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// Stage with owner-only permissions, synchronize and atomically rename within the same
    /// directory. No fallible operation follows the commit, so UI and disk cannot disagree after
    /// a successful rename. The actor is the sole in-process writer for this file.
    private func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".notebook-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
