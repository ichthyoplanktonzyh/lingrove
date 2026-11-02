import Foundation
import LingroveNotebookSync

/// Networking receives frozen public bytes; callbacks carry the exact body hash
/// and original account-generation ticket. Receipt persistence is separate from
/// the later covering-window apply that may retire captured notebook journals.
extension LingroveNotebookEngine {
    public func nextLingroveNotebookUpload(binding: LingroveNotebookWindowBinding, transport: VocabularyWireUploadBatch.Transport = .direct,
                                    stagedCapability: VocabularyWireStagedCapabilities? = nil) throws -> LingroveNotebookPendingUpload? {
        try lingroveNotebookUploadStore.next(binding: binding, transport: transport, stagedCapability: stagedCapability)
    }
    public func lingroveNotebookUploadControl(_ pending: LingroveNotebookPendingUpload, binding: LingroveNotebookWindowBinding) throws -> LingroveNotebookUploadControl {
        try lingroveNotebookUploadStore.control(pending, binding: binding)
    }
    public func recordLingroveNotebookConfirmation(_ manifest: VocabularyWireConfirmationManifest, pending: LingroveNotebookPendingUpload,
                                           binding: LingroveNotebookWindowBinding) throws {
        try LingroveNotebookStagedUploadStore(core: core).recordManifest(manifest, pending: pending, binding: binding)
    }
    public func recordLingroveNotebookUploadClosure(_ manifest: VocabularyWireStagedManifest, pending: LingroveNotebookPendingUpload,
                                            binding: LingroveNotebookWindowBinding) throws {
        guard let upload = pending.stagedUpload else { throw LingroveNotebookUploadStoreError.receiptConflict }
        let closure = try VocabularyWireStagedClosure(manifest: manifest, upload: upload)
        try LingroveNotebookUploadClosureStore(core: core).record(closure, pending: pending, binding: binding)
    }
    public func resumeLingroveNotebookCancelledUploads(binding: LingroveNotebookWindowBinding) throws {
        try LingroveNotebookUploadClosureStore(core: core).resume(binding: binding)
    }
    public func recordLingroveNotebookConfirmationPage(_ page: VocabularyWireConfirmationPage, manifest: VocabularyWireConfirmationManifest,
                                               pending: LingroveNotebookPendingUpload, binding: LingroveNotebookWindowBinding) throws {
        try LingroveNotebookStagedUploadStore(core: core).recordPage(page, manifest: manifest, pending: pending, binding: binding)
    }
    public func recordLingroveNotebookReceipt(_ receipt: VocabularyWireGroupReceipt, bodySHA256: String, binding: LingroveNotebookWindowBinding) throws {
        try lingroveNotebookUploadStore.recordReceipt(receipt, bodySHA256: bodySHA256, binding: binding)
    }
    public func recordLingroveNotebookOutcome(_ outcome: VocabularyWireGroupOutcome, bodySHA256: String, binding: LingroveNotebookWindowBinding) throws {
        try lingroveNotebookUploadStore.recordOutcome(outcome, bodySHA256: bodySHA256, binding: binding)
    }
    public func requestLingroveNotebookUploadCancellation(groupID: UUID, bodySHA256: String, binding: LingroveNotebookWindowBinding) throws {
        try lingroveNotebookUploadStore.requestCancellation(groupID: groupID, bodySHA256: bodySHA256, binding: binding)
    }
}
