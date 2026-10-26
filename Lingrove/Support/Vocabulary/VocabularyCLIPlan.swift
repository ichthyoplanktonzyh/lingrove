import CryptoKit
import Foundation

/// Pure batch planning reuses notebook identities and validation rules. The archive supplies an
/// immutable baseline and prepared images; this type returns a candidate, never performs IO or
/// starts a model. Stable generated IDs make a dry run and its later commit easy to correlate.
nonisolated struct VocabularyCLIPlan {
    var document: VocabularyDocument
    var outcomes: [CLIJSON] = []
    var images: [String: Data] = [:]

    static func fingerprint(_ batch: CLIBatch) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(batch)).map { String(format: "%02x", $0) }.joined()
    }

    init(batch: CLIBatch, snapshot: VocabularySnapshot, fingerprint: String,
         prepared: [String: VocabularyPreparedImage], now: Date) throws {
        guard batch.version == 1, (1...200).contains(batch.idempotencyKey.utf8.count),
              !batch.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...100).contains(batch.operations.count) else {
            throw CLIError.invalid("Invalid batch version, idempotency key or operation count.")
        }
        document = snapshot.document
        for (index, change) in batch.operations.enumerated() {
            let context = OperationContext(index: index, batchKey: batch.idempotencyKey, fingerprint: fingerprint, now: now)
            try apply(change, context: context, revision: snapshot.revision, prepared: prepared)
        }
        document.schemaVersion = VocabularyDocument.requiredVersion(for: document.entries)
    }

    /// A batch operation owns this immutable value only while planning. It carries the original
    /// ID seed/path and timestamp through the helpers, so splitting the rules cannot change the
    /// identities that clients correlate between dry runs, commits and retries.
    private struct OperationContext {
        let index: Int
        let now: Date
        private let seed: String
        var prefix: String { String(index) }

        init(index: Int, batchKey: String, fingerprint: String, now: Date) {
            self.index = index
            self.now = now
            seed = batchKey + "\0" + fingerprint + "\0" + String(index) + "."
        }

        func id(_ suffix: String) -> UUID {
            var bytes = Array(SHA256.hash(data: Data((seed + suffix).utf8)).prefix(16))
            bytes[6] = (bytes[6] & 0x0F) | 0x50
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }
    }

    private mutating func apply(
        _ change: CLIChange, context: OperationContext, revision: UInt64, prepared: [String: VocabularyPreparedImage]
    ) throws {
        guard [change.add != nil, change.append != nil, change.update != nil].filter({ $0 }).count == 1 else {
            throw CLIError.invalid("Each operation needs exactly one action.")
        }
        let entryCount = document.entries.count
        let target: (entry: Int, sense: Int)
        if let add = change.add {
            target = try addSense(add, context: context)
        } else {
            target = try existingTarget(for: change)
        }
        var sense = document.entries[target.entry].senses[target.sense]
        if let update = change.update { try Self.applyUpdate(update, to: &sense, revision: revision) }
        let examples = change.add?.examples ?? change.append?.examples ?? []
        let blocks = change.add?.content ?? change.append?.content ?? []
        if let append = change.append { try Self.appendTags(append, to: &sense) }
        guard examples.count <= 100, blocks.count <= 64 else { throw CLIError.invalid("Too many examples or content blocks.") }
        let usageIDs = try Self.appendExamples(examples, to: &sense, entry: document.entries[target.entry], context: context)
        let blockIDs = try appendBlocks(blocks, to: &sense, prepared: prepared, context: context)
        try VocabularyContentPolicy.validate(sense.content ?? [])
        sense.updatedAt = context.now
        document.entries[target.entry].senses[target.sense] = sense
        document.entries[target.entry].updatedAt = context.now
        outcomes.append(.object([
            "operation": .integer(Int64(context.index)), "entryID": .string(document.entries[target.entry].id.uuidString),
            "senseID": .string(sense.id.uuidString), "createdEntry": .bool(document.entries.count > entryCount),
            "usageIDs": .array(usageIDs.map { .string($0.uuidString) }),
            "blockIDs": .array(blockIDs.map { .string($0.uuidString) })
        ]))
    }

    private mutating func addSense(_ add: CLINewSense, context: OperationContext) throws -> (entry: Int, sense: Int) {
        let expression = try Self.text(add.expression, limit: 32_000, nonempty: true)
        guard let language = LearningLanguage(rawValue: add.language),
              let kind = VocabularyEntry.Kind(rawValue: add.kind) else {
            throw CLIError.invalid("Unknown language or expression kind.")
        }
        let dictionary = try Self.text(add.dictionaryForm ?? expression, limit: 32_000, nonempty: true)
        let key = VocabularyPolicy.entryKey(.init(expression: expression, dictionaryForm: dictionary, language: language, kind: kind))
        let entryIndex: Int
        if let existing = document.entries.firstIndex(where: { VocabularyPolicy.entryKey($0) == key }) {
            entryIndex = existing
        } else {
            entryIndex = document.entries.count
            document.entries.append(.init(id: context.id("entry"), expression: expression, dictionaryForm: dictionary,
                language: language, kind: kind, senses: [], createdAt: context.now, updatedAt: context.now))
        }
        let senseIndex = document.entries[entryIndex].senses.count
        document.entries[entryIndex].senses.append(.init(id: context.id("sense"),
            meaning: try Self.text(add.meaning, limit: 32_000, nonempty: true),
            meaningLanguage: try Self.language(add.meaningLanguage), meaningOrigin: .user,
            note: try Self.text(add.note ?? "", limit: 262_144), tags: try Self.tags(add.tags ?? []),
            createdAt: context.now, updatedAt: context.now))
        return (entryIndex, senseIndex)
    }

    private func existingTarget(for change: CLIChange) throws -> (entry: Int, sense: Int) {
        guard let entryID = change.append?.entryID ?? change.update?.entryID,
              let senseID = change.append?.senseID ?? change.update?.senseID,
              let entry = document.entries.firstIndex(where: { $0.id == entryID }),
              let sense = document.entries[entry].senses.firstIndex(where: { $0.id == senseID }) else {
            throw CLIError(code: .notFound, message: "Entry or sense no longer exists. Read it again before writing.")
        }
        return (entry, sense)
    }

    private static func applyUpdate(_ update: CLIUpdate, to sense: inout VocabularySense, revision: UInt64) throws {
        guard update.expectedRevision == revision else {
            throw CLIError(code: .conflict, message: "Notebook revision changed. Read the entry again.")
        }
        guard update.meaning != nil || update.meaningLanguage != nil || update.note != nil || update.tags != nil else {
            throw CLIError.invalid("An update needs at least one field.")
        }
        if let meaning = update.meaning {
            sense.meaning = try text(meaning, limit: 32_000, nonempty: true)
            sense.meaningOrigin = .user
        }
        if let code = update.meaningLanguage {
            sense.meaningLanguage = try language(code)
            sense.meaningOrigin = .user
        }
        if let note = update.note { sense.note = try text(note, limit: 262_144) }
        if let values = update.tags { sense.tags = try tags(values) }
    }

    private static func appendTags(_ append: CLIAppend, to sense: inout VocabularySense) throws {
        guard !(append.examples ?? []).isEmpty || !(append.content ?? []).isEmpty || !(append.tags ?? []).isEmpty else {
            throw CLIError.invalid("An append needs examples, content or tags.")
        }
        for tag in try tags(append.tags ?? []) where !sense.tags.contains(tag) { sense.tags.append(tag) }
        sense.tags = try tags(sense.tags)
    }

    private static func appendExamples(
        _ examples: [CLIExample], to sense: inout VocabularySense, entry: VocabularyEntry, context: OperationContext
    ) throws -> [UUID] {
        var usageIDs: [UUID] = []
        for (position, input) in examples.enumerated() {
            let value = try example(input, expression: entry.expression, id: context.id("example." + String(position)), now: context.now)
            let key = VocabularyPolicy.exampleKey(value)
            if let existing = sense.examples.firstIndex(where: { VocabularyPolicy.exampleKey($0) == key }) {
                try mergeExample(value, into: &sense.examples[existing])
                usageIDs.append(sense.examples[existing].id)
                continue
            }
            guard !entry.examples.contains(where: { VocabularyPolicy.exampleKey($0) == key }) else {
                throw CLIError(code: .conflict, message: "This usage already belongs to another sense. Append to its current owner.")
            }
            sense.examples.append(value)
            usageIDs.append(value.id)
        }
        return usageIDs
    }

    /// Duplicate captures may add a translation, but never overwrite an explicitly edited meaning
    /// (including an intentionally empty one). The retained usage keeps its original identity.
    private static func mergeExample(_ value: VocabularyExample, into retained: inout VocabularyExample) throws {
        if !value.meaning.isEmpty, !retained.meaning.isEmpty || retained.meaningOrigin == .user,
           value.meaning != retained.meaning || value.meaningLanguage != retained.meaningLanguage {
            throw CLIError(code: .conflict, message: "This usage has a different saved meaning. Edit it in the app.")
        }
        if !value.translation.isEmpty {
            if retained.translation.isEmpty {
                retained.translation = value.translation
                retained.translationLanguage = value.translationLanguage
            } else {
                let variant = VocabularyMeaning(text: value.translation, language: value.translationLanguage)
                if variant != VocabularyMeaning(text: retained.translation, language: retained.translationLanguage),
                   !retained.translationVariants.contains(variant) { retained.translationVariants.append(variant) }
            }
        }
        if retained.meaning.isEmpty, retained.meaningOrigin != .user, !value.meaning.isEmpty {
            retained.meaning = value.meaning
            retained.meaningLanguage = value.meaningLanguage
            retained.meaningOrigin = .user
        }
    }

    private mutating func appendBlocks(
        _ blocks: [CLIBlock], to sense: inout VocabularySense, prepared: [String: VocabularyPreparedImage], context: OperationContext
    ) throws -> [UUID] {
        var blockIDs: [UUID] = []
        for (position, block) in blocks.enumerated() {
            let key = context.prefix + "." + String(position)
            let blockID = context.id("block." + String(position))
            let value: VocabularyContentBlock.Content
            if let text = block.text, block.image == nil {
                value = .text(.init(text: try Self.text(text, limit: 262_144, nonempty: true),
                    bold: block.bold ?? false, italic: block.italic ?? false))
            } else if let image = block.image, block.text == nil, let ready = prepared[key], image.path == nil, image.data != nil,
                      block.bold == nil, block.italic == nil {
                value = .image(ready.reference, caption: try Self.text(image.caption ?? "", limit: 16_384))
                images[ready.reference.filename] = ready.data
            } else {
                throw CLIError.invalid("A block needs text or an image; image paths must be resolved by the CLI.")
            }
            sense.content = (sense.content ?? []) + [.init(id: blockID, content: value)]
            blockIDs.append(blockID)
        }
        return blockIDs
    }

    private static func text(_ value: String, limit: Int, nonempty: Bool = false) throws -> String {
        guard value.utf8.count <= limit, !nonempty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.invalid("Text is empty or exceeds its field limit.")
        }
        return value
    }
    private static func language(_ value: String?) throws -> LearningLanguage? {
        guard let value else { return nil }
        guard let language = LearningLanguage(rawValue: value) else { throw CLIError.invalid("Unknown language code.") }
        return language
    }
    private static func tags(_ values: [String]) throws -> [String] {
        guard values.count <= 100 else { throw CLIError.invalid("At most 100 tags are allowed.") }
        var result: [String] = []
        for value in values {
            let tag = try text(value.trimmingCharacters(in: .whitespacesAndNewlines), limit: 200, nonempty: true)
            if !result.contains(tag) { result.append(tag) }
        }
        return result
    }
    private static func example(_ input: CLIExample, expression: String, id: UUID, now: Date) throws -> VocabularyExample {
        let text = try text(input.text, limit: 262_144, nonempty: true)
        let ranges: [VocabularyTextRange]
        if let supplied = input.ranges {
            ranges = supplied.map { .init(NSRange(location: $0.location, length: $0.length)) }
        } else {
            let range = (text as NSString).range(of: expression)
            if range.location != NSNotFound {
                // Start after the first start, not its end: targets such as "ana" in
                // "banana" have overlapping occurrences and still require disambiguation.
                let tail = NSRange(location: range.location + 1, length: text.utf16.count - range.location - 1)
                guard (text as NSString).range(of: expression, range: tail).location == NSNotFound else {
                    throw CLIError.invalid("Expression occurs more than once. Supply explicit UTF-16 ranges.")
                }
            }
            ranges = range.location == NSNotFound ? [] : [.init(range)]
        }
        guard ranges.count <= 64, ranges.allSatisfy({ VocabularyPolicy.valid($0.nsRange, in: text) }),
              let completeness = VocabularyExample.Completeness(rawValue: input.completeness ?? "sentence") else {
            throw CLIError.invalid("Invalid UTF-16 ranges or context completeness.")
        }
        return .init(id: id, text: text, translation: try self.text(input.translation ?? "", limit: 262_144),
            translationLanguage: try language(input.translationLanguage), ranges: ranges, completeness: completeness,
            meaning: try self.text(input.meaning ?? "", limit: 32_000), meaningLanguage: try language(input.meaningLanguage),
            meaningOrigin: input.meaning == nil ? .captured : .user, createdAt: now)
    }
}
