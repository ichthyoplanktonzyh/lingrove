import Foundation
import LingroveNotebookSync

/// Native sync orchestration borrows the same database lifetime as local edits.
/// Preparation yields a value; commit fences concurrent edits and never releases
/// held Card/review operations into the legacy sync dispatcher.
extension LingroveNotebookEngine {
    public func prepareLingroveNotebookApply(_ window: VocabularyWireVerifiedWindow, binding: LingroveNotebookWindowBinding,
                                      images: [String: Data] = [:], now: Date) throws -> LingroveNotebookApplyPlan {
        try lingroveNotebookSyncStore.prepare(window, binding: binding, images: images, now: now)
    }
    public func commitLingroveNotebookApply(_ plan: LingroveNotebookApplyPlan, now: Date) throws -> LingroveNotebookSnapshot {
        try lingroveNotebookSyncStore.commit(plan, now: now)
    }
    public func confirmedLingroveNotebookShadow(binding: LingroveNotebookWindowBinding) throws -> VocabularyWireServerShadow? {
        try lingroveNotebookSyncStore.confirmedShadow(binding: binding)
    }
}
