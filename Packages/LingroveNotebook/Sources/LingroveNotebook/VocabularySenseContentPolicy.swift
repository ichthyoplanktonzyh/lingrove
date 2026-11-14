import Foundation

/// Creation and editor boundaries use this pure rule to distinguish language material from
/// an empty draft. It does not change the persisted format or invalidate previously saved
/// records. Tags, review recipes and generation receipts are not the sense's own content.
public nonisolated enum VocabularySenseContentPolicy {
    public static func hasContent(_ sense: VocabularySense) -> Bool {
        if hasText(sense.meaning) || hasText(sense.note) { return true }
        if (sense.standaloneMeanings + sense.alternateMeanings).contains(where: { hasText($0.text) }) { return true }
        if sense.examples.contains(where: { hasText($0.text) }) { return true }
        return (sense.content ?? []).contains { block in
            switch block.content {
            case let .text(value): hasText(value.text)
            case .image: true
            }
        }
    }

    private static func hasText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
