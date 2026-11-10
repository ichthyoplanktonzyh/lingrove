import Foundation
import LingroveNotebook

/// Check the cached value graph before constructing/encoding canonical read projections. JSON escaping
/// can expand a UTF-8 byte to six ASCII bytes; generous per-entity overhead also covers keys,
/// UUIDs, dates and punctuation. This deliberately conservative bound avoids allocating a huge
/// intermediate Data buffer just to discover that a CLI result cannot fit the wire limit.
nonisolated enum VocabularyCLIReadBudget {
    static func validate(_ entry: VocabularyEntry, maximum: Int = CLIInputPolicy.maximumBytes) throws {
        try validate([entry], maximum: maximum)
    }

    /// One allowance spans the entire batch; per-entry limits alone could admit 100 huge records.
    static func validate(_ entries: [VocabularyEntry], maximum: Int = CLIInputPolicy.maximumBytes) throws {
        var remaining = maximum
        func take(_ amount: Int) throws {
            guard amount >= 0, amount <= remaining else {
                throw CLIError.invalid("Read exceeds the CLI budget. Request fewer IDs or read individual senses.")
            }
            remaining -= amount
        }
        func text(_ value: String) throws {
            let count = value.utf8.count
            guard count <= remaining / 6 else {
                throw CLIError.invalid("Read exceeds the CLI budget. Request fewer IDs or read individual senses.")
            }
            try take(count * 6 + 128)
        }
        func meanings(_ values: [VocabularyMeaning]) throws {
            for value in values { try take(512); try text(value.text) }
        }
        for entry in entries {
            try take(4_096); try text(entry.expression); try text(entry.dictionaryForm)
            for sense in entry.senses {
                try take(2_048); try text(sense.meaning); try text(sense.note)
                for tag in sense.tags { try text(tag) }
                try text(entry.expression); try text(entry.dictionaryForm)
                for block in sense.content ?? [] {
                    try take(2_048)
                    switch block.content {
                    case let .text(value): try text(value.text)
                    case let .image(_, caption): try text(caption)
                    }
                }
                for usage in sense.examples {
                    try take(2_048); try text(usage.text); try text(usage.translation)
                    guard usage.ranges.count <= remaining / 128 else {
                        throw CLIError.invalid("Read exceeds the CLI budget. Request fewer IDs or read individual senses.")
                    }
                    try take(usage.ranges.count * 128)
                    try meanings(usage.translationVariants)
                }
            }
        }
    }
}
