import Foundation
import LingroveNotebook

/// Native Cards retain their existing Markdown contract. This adapter turns the shared ordered
/// material into safe native markup; media uses workspace-owned identities, never export paths.
extension LingroveNotebookCardMaterial {
    public static func render(entry: VocabularyEntry, sense: VocabularySense, plan: ReviewMaterialPlan,
                              workspaceID: String) throws -> CardEditorInput {
        let resolved = try ReviewMaterialResolver.resolve(entry: entry, sense: sense, plan: plan)
        func face(_ parts: [ReviewResolvedPart]) throws -> String {
            try parts.map { part in
                switch part {
                case let .text(value): return plainMarkdown(value)
                case let .blocks(blocks):
                    return try blocks.map { block in
                        switch block.content {
                        case let .text(text):
                            var value = plainMarkdown(text.text)
                            if text.bold { value = "**" + value + "**" }
                            if text.italic { value = "*" + value + "*" }
                            switch text.style {
                            case .heading: value = "## " + value
                            case .bullet: value = "- " + value
                            case .paragraph: break
                            }
                            return value
                        case let .image(image, caption):
                            let reference = ReviewMaterialMediaReference(image: image)
                            return try managedImageMarkdownReference(mediaAssetId: mediaAssetID(reference: reference, workspaceID: workspaceID), altText: caption)
                                + (caption.isEmpty ? "" : "\n\n" + plainMarkdown(caption))
                        }
                    }.joined(separator: "\n\n")
                case let .audio(kind):
                    guard let audio = plan.audio[kind], let text = ReviewMaterialResolver.audioText(kind, entry: entry, sense: sense, plan: plan),
                          audio.textHash == ReviewMaterialAudio.textHash(text) else { throw ReviewMaterialError.missingAudio(kind) }
                    return "[Audio](fcasset:" + mediaAssetID(reference: audio.reference, workspaceID: workspaceID) + ")"
                }
            }.joined(separator: "\n\n")
        }
        return normalized(.init(frontText: try face(resolved.front), backText: try face(resolved.back), tags: sense.tags))
    }

    /// A scoped deterministic UUID survives retries and wire roundtrips. The same blob in a
    /// different account has another asset ID, so knowing a digest cannot grant account access.
    public static func mediaAssetID(reference: ReviewMaterialMediaReference, workspaceID: String) -> String {
        stableID("material-media|" + reference.digest, workspace: workspaceID,
                 sense: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!).uuidString.lowercased()
    }

    public static func mediaReferences(entry: VocabularyEntry, sense: VocabularySense,
                                       plan: ReviewMaterialPlan) throws -> Set<ReviewMaterialMediaReference> {
        let content = try ReviewMaterialResolver.resolve(entry: entry, sense: sense, plan: plan)
        var references = Set<ReviewMaterialMediaReference>()
        for part in content.front + content.back {
            switch part {
            case let .blocks(blocks): references.formUnion(VocabularyContentPolicy.images(blocks).map(ReviewMaterialMediaReference.init(image:)))
            case let .audio(kind):
                guard let audio = plan.audio[kind], let text = ReviewMaterialResolver.audioText(kind, entry: entry, sense: sense, plan: plan),
                      audio.textHash == ReviewMaterialAudio.textHash(text) else { throw ReviewMaterialError.missingAudio(kind) }
                references.insert(audio.reference)
            case .text: break
            }
        }
        return references
    }
}
