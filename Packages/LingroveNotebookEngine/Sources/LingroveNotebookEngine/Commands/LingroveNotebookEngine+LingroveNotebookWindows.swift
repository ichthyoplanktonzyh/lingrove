import Foundation
import LingroveNotebookSync

/// The application facade borrows its existing connection and lifetime. These
/// calls stage transport only; the visible document and all pending journals
/// remain owned by their existing notebook/review writers.
extension LingroveNotebookEngine {
    public func captureLingroveNotebookWindowBinding(scope: VocabularyWireWindowScope) throws -> LingroveNotebookWindowBinding {
        try lingroveNotebookWindowStore.capture(scope: scope)
    }
    public func validateLingroveNotebookWindowBinding(_ binding: LingroveNotebookWindowBinding) throws {
        try core.inReadTransaction { try lingroveNotebookWindowStore.checkBindingInTransaction(binding) }
    }
    public func beginLingroveNotebookWindow(_ manifest: VocabularyWireWindowManifest, binding: LingroveNotebookWindowBinding, now: Date) throws -> LingroveNotebookWindowProgress {
        try lingroveNotebookWindowStore.begin(manifest, binding: binding, now: now)
    }
    public func receiveLingroveNotebookWindowPage(_ page: VocabularyWireWindowPage, binding: LingroveNotebookWindowBinding, manifestSHA256: String, now: Date) throws {
        try lingroveNotebookWindowStore.receive(page, binding: binding, manifestSHA256: manifestSHA256, now: now)
    }
    public func lingroveNotebookWindowProgress(binding: LingroveNotebookWindowBinding, windowID: UUID, now: Date) throws -> LingroveNotebookWindowProgress {
        try lingroveNotebookWindowStore.progress(binding: binding, windowID: windowID, now: now)
    }
    public func completeLingroveNotebookWindow(binding: LingroveNotebookWindowBinding, windowID: UUID, manifestSHA256: String, now: Date) throws -> VocabularyWireVerifiedWindow {
        try lingroveNotebookWindowStore.complete(binding: binding, windowID: windowID, manifestSHA256: manifestSHA256, now: now)
    }
    public func discardLingroveNotebookWindow(binding: LingroveNotebookWindowBinding, windowID: UUID) throws {
        try lingroveNotebookWindowStore.discard(binding: binding, windowID: windowID)
    }
}
