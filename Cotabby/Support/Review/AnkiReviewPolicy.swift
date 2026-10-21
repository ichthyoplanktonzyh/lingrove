import Foundation

/// Narrow interoperability rules shared by the controller, archive and tests. Exact IDs and
/// three-way comparisons prevent a duplicate check from accidentally merging two word senses.
nonisolated enum AnkiReviewPolicy {
    static let presetName = "Lingrove v1"
    static let presetMapping = Dictionary(uniqueKeysWithValues: ReviewField.allCases.map { ($0, $0.rawValue) })

    static func removesExistingCard(_ plan: ReviewPlan, binding: AnkiNoteBinding) -> Bool {
        guard binding.noteID != nil else { return false }
        return !plan.recognition && !(binding.fields[binding.mapping[.recognition] ?? ""] ?? "").isEmpty ||
            !plan.gap && !(binding.fields[binding.mapping[.gapPrompt] ?? ""] ?? "").isEmpty
    }

    static func endpoint(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "http", let host = parts.host,
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", parts.port.map({ (1...65_535).contains($0) }) ?? true else { return nil }
        var normalized = parts; normalized.host = host.lowercased(); normalized.path = ""
        return normalized.url
    }

    static func fields(content: ReviewCardContent, identity: UUID, mapping: [ReviewField: String],
                       overrides: [String: String]) throws -> [String: String] {
        let selected = mapping.filter { !$0.value.isEmpty }
        guard selected[.identity] != nil, selected[.expression] != nil, selected[.meaning] != nil,
              Set(selected.values).count == selected.count,
              selected.values.allSatisfy({ !$0.contains(where: { $0.isNewline }) && $0.utf8.count <= 200 }) else {
            throw AnkiReviewError.message(String(localized: "Map unique fields for the sense ID, expression and answer.",
                table: "Vocabulary"))
        }
        let values = ReviewCardPolicy.values(content, identity: identity)
        var result = Dictionary(uniqueKeysWithValues: selected.map { ($0.value, values[$0.key] ?? "") })
        for (field, value) in overrides where result[field] != nil && field != selected[.identity] { result[field] = value }
        guard result.values.reduce(0, { $0 + $1.utf8.count }) <= 1_000_000 else {
            throw AnkiReviewError.message(String(localized: "The review content is too large to send.", table: "Vocabulary"))
        }
        return result
    }

    /// A remote-only edit is also surfaced: acknowledging it silently would hide a change to
    /// the learning answer. Unmapped fields are never included in an update request.
    static func conflicts(base: [String: String], local: [String: String], remote: [String: String]) -> [AnkiFieldConflict] {
        local.keys.sorted().compactMap { key in
            let theirs = remote[key] ?? "", ours = local[key] ?? ""
            guard theirs != base[key], theirs != ours else { return nil }
            return .init(id: key, local: ours, remote: theirs)
        }
    }

    static func merged(_ target: VocabularyReview?, _ source: VocabularyReview?) -> VocabularyReview? {
        guard var result = target ?? source else { return nil }
        guard let target, let source else { return result }
        result = target
        for binding in source.bindings where !result.bindings.contains(where: {
            $0.endpoint == binding.endpoint && $0.profile == binding.profile &&
                ($0.noteID != nil && $0.noteID == binding.noteID || $0.originSenseID == binding.originSenseID)
        }) { result.bindings.append(binding) }
        result.preservedPlans += [source.plan] + source.preservedPlans
        if result.bindings.count > 1 { result.activeBindingID = nil } else { result.activeBindingID = result.bindings.first?.id }
        return result
    }
}
