import Foundation

/// Validates saved review material and optional legacy tool receipts, without connecting to a
/// review tool. Both notebook stores call these rules; scheduling and tool-owned history remain
/// outside this boundary. Empty Anki bindings are valid and require no Anki configuration.
public nonisolated enum VocabularyReviewValidation {
    public static func validate(_ layout: ReviewLayout) throws {
        guard layout.parts.count <= 64, Set(layout.parts.map(\.id)).count == layout.parts.count else {
            throw VocabularyError.invalidContent
        }
        for part in layout.parts {
            guard part.source == .custom || part.content.isEmpty else { throw VocabularyError.invalidContent }
            try VocabularyContentPolicy.validate(part.content)
        }
        try VocabularyContentPolicy.validate(layout.customContent)
    }

    public static func validate(_ review: VocabularyReview) throws {
        guard review.bindings.count <= 64, review.preservedPlans.count <= 64,
              Set(review.bindings.map(\.id)).count == review.bindings.count,
              review.activeBindingID == nil || review.bindings.contains(where: { $0.id == review.activeBindingID }) else {
            throw VocabularyError.invalidArchive
        }
        for plan in [review.plan] + review.preservedPlans {
            if let layout = plan.layout { try validate(layout) }
            guard (plan.name?.utf8.count ?? 0) <= 1024, (plan.answer?.utf8.count ?? 0) <= 262_144, plan.fieldOverrides.count <= 32,
                  plan.fieldOverrides.allSatisfy({ $0.key.utf8.count <= 200 && $0.value.utf8.count <= 1_000_000 }) else {
                throw VocabularyError.invalidArchive
            }
        }
        for plan in [review.plan] + review.preservedPlans {
            guard (plan.audioReceipts?.count ?? 0) <= 2,
                  plan.audioReceipts?.values.allSatisfy({
                      $0.fingerprint.count == 64 && $0.textHash.count == 64 && validAudioFilename($0.filename) &&
                      legacyAnkiEndpoint($0.endpoint) != nil && !$0.profile.isEmpty
                  }) ?? true else { throw VocabularyError.invalidArchive }
        }
        for binding in review.bindings {
            guard binding.noteID.map({ $0 > 0 }) ?? true, !binding.profile.isEmpty, !binding.model.isEmpty,
                  legacyAnkiEndpoint(binding.endpoint) != nil, binding.mapping[.identity] == binding.identityField,
                  binding.fields[binding.identityField] == binding.originSenseID.uuidString.lowercased(),
                  binding.fields.count <= 32, binding.fields.allSatisfy({ $0.value.utf8.count <= 1_000_000 }) else {
                throw VocabularyError.invalidArchive
            }
        }
    }

    /// Flexible-card plan IDs participate in the document's existing identity namespace;
    /// layout-part IDs, legacy plans and tool receipt IDs retain their narrower local scopes.
    public static func validateCards(_ cards: [VocabularyReview], ids: inout Set<UUID>) throws {
        guard cards.count <= 64 else { throw VocabularyError.invalidArchive }
        for card in cards {
            guard ids.insert(card.plan.id).inserted, let layout = card.plan.layout else { throw VocabularyError.invalidArchive }
            try validate(layout)
            try validate(card)
        }
    }

    public static func validateTemplates(_ templates: [ReviewLayoutTemplate]) throws {
        guard templates.count <= 64, Set(templates.map(\.id)).count == templates.count else { throw VocabularyError.invalidArchive }
        for template in templates {
            guard !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  template.name.utf8.count <= 1024 else { throw VocabularyError.invalidArchive }
            try validate(template.layout)
        }
    }

    /// Parse only the legacy persisted Anki address contract. This performs no network or
    /// credential access; the external-tool adapter uses it too so the two rules cannot drift.
    public static func legacyAnkiEndpoint(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "http", let host = parts.host,
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", parts.port.map({ (1...65_535).contains($0) }) ?? true else { return nil }
        var normalized = parts; normalized.host = host.lowercased(); normalized.path = ""
        return normalized.url
    }

    public static func validAudioFilename(_ value: String) -> Bool {
        value.range(of: "^lingrove-[a-f0-9]{64}\\.(wav|mp3)$", options: .regularExpression) != nil
    }
}

extension VocabularySense {
    /// Retained plans participate in media ownership even while hidden in the current editor.
    /// A backup or garbage collector must see every saved use of a resource, on either platform.
    public nonisolated var reviewLayouts: [ReviewLayout] {
        ([review].compactMap { $0 } + (reviewCards ?? [])).flatMap {
            ([$0.plan] + $0.preservedPlans).compactMap(\.layout)
        }
    }
}
