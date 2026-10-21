import Foundation

/// Check the cached value graph before constructing/encoding an export projection. JSON escaping
/// can expand a UTF-8 byte to six ASCII bytes; generous per-entity overhead also covers keys,
/// UUIDs, dates and punctuation. This deliberately conservative bound avoids allocating a huge
/// intermediate Data buffer just to discover that a CLI entry cannot fit the wire limit.
nonisolated enum VocabularyCLIReadBudget {
    static func validate(_ entry: VocabularyEntry, maximum: Int = CLIInputPolicy.maximumBytes) throws {
        var remaining = maximum
        func take(_ amount: Int) throws {
            guard amount >= 0, amount <= remaining else { throw CLIError.invalid("Entry exceeds the CLI read budget. Use the app's export.") }
            remaining -= amount
        }
        func text(_ value: String) throws {
            let count = value.utf8.count
            guard count <= remaining / 6 else { throw CLIError.invalid("Entry exceeds the CLI read budget. Use the app's export.") }
            try take(count * 6 + 128)
        }
        func meanings(_ values: [VocabularyMeaning]) throws {
            for value in values { try take(512); try text(value.text) }
        }
        func explanations(_ values: [LearningExplanationRecord]) throws {
            for value in values { try take(512); try text(value.result.meaning); try text(value.result.explanation) }
        }
        try take(4_096); try text(entry.expression); try text(entry.dictionaryForm)
        for sense in entry.senses {
            try take(2_048); try text(sense.meaning); try text(sense.note)
            for tag in sense.tags { try text(tag) }
            try meanings(sense.standaloneMeanings); try meanings(sense.alternateMeanings); try explanations(sense.explanations)
            for block in sense.content ?? [] {
                try take(2_048)
                switch block.content { case let .text(value): try text(value.text); case let .image(_, caption): try text(caption) }
            }
            for usage in sense.examples {
                try take(2_048); try text(usage.text); try text(usage.translation); try text(usage.meaning)
                guard usage.ranges.count <= remaining / 128 else { throw CLIError.invalid("Entry exceeds the CLI read budget. Use the app's export.") }
                try take(usage.ranges.count * 128)
                try meanings(usage.translationVariants); try explanations(usage.explanations)
            }
        }
    }
}
