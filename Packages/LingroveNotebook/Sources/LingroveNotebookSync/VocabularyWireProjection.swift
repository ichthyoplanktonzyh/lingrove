import Foundation
import LingroveNotebook

/// Stateless bridge shared by native hosts. It neither enables sync nor adopts
/// a server book; the host owns account scope, complete-window verification,
/// cancellation/background scheduling and the eventual local transaction.
public nonisolated enum VocabularyWireProjectionCodec {
    public static func project(
        _ document: VocabularyDocument, notebookID: UUID,
        retaining unattached: VocabularyWirePrivateState? = nil
    ) throws -> VocabularyWireProjection {
        guard document.schemaVersion == VocabularyDocument.currentVersion else { throw VocabularyWireError.unsupportedVersion }
        do { try VocabularyDocumentValidation.validate(document) } catch { throw VocabularyWireError.invalidDocument }
        if let unattached, unattached.notebookID != notebookID { throw VocabularyWireError.privateScopeMismatch }
        var encoder = VocabularyWireEncoder()
        let entities = try encoder.encode(document, notebookID: notebookID)
        guard entities.allSatisfy({ $0.fields.values.allSatisfy(\.hasFiniteNumbers) }) else { throw VocabularyWireError.invalidDocument }
        var state = try VocabularyWirePrivateOverlay.capture(document, notebookID: notebookID)
        if let unattached {
            var reviews = state.reviews, explanations = state.explanations
            for value in unattached.reviews where !reviews.contains(value) { reviews.append(value) }
            for value in unattached.explanations where !explanations.contains(value) { explanations.append(value) }
            state = .init(notebookID: notebookID, reviews: reviews, explanations: explanations)
        }
        return .init(notebookID: notebookID, entities: entities, privateState: state)
    }

    /// Only call with a verified complete window. The graph detects dangling
    /// references, but cannot infer whether an unrelated independent record was
    /// omitted by transport. No empty/missing-root page can erase a local book.
    public static func materializeComplete(
        _ entities: [VocabularyWireEntity], notebookID: UUID,
        preserving state: VocabularyWirePrivateState? = nil
    ) throws -> VocabularyWireMaterialization {
        let local = state ?? .init(notebookID: notebookID)
        guard local.notebookID == notebookID else { throw VocabularyWireError.privateScopeMismatch }
        var decoder = try VocabularyWireDecoder(entities, notebookID: notebookID)
        var document = try decoder.decode()
        let unattached = try VocabularyWirePrivateOverlay.apply(local, to: &document)
        // Remote materialization is strict. prepare() would reconcile/prune
        // invalid material and hide a protocol mismatch instead of rejecting it.
        do { try VocabularyDocumentValidation.validate(document) } catch { throw VocabularyWireError.invalidDocument }
        return .init(document: document, unattachedPrivateState: unattached)
    }
}
