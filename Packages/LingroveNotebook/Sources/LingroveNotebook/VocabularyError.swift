import Foundation

/// Decoding and storage operations share one error identity across module boundaries.
/// The host's Vocabulary localization table supplies the existing user-facing descriptions;
/// this value owns no archive, UI object or runtime and preserves existing catch behavior.
public nonisolated enum VocabularyError: LocalizedError {
    case invalidContent, unsupportedVersion, oversizedArchive, invalidArchive, editConflict, storageBusy
    public var errorDescription: String? {
        switch self {
        case .invalidContent: String(localized: "This vocabulary item could not be verified.", table: "Vocabulary")
        case .unsupportedVersion: String(localized: "This notebook was created by a newer version of Lingrove.", table: "Vocabulary")
        case .oversizedArchive: String(localized: "The notebook exceeds the supported file size.", table: "Vocabulary")
        case .invalidArchive:
            String(localized: "The notebook could not be read. The original file has been preserved.", table: "Vocabulary")
        case .editConflict: String(localized: "This item changed while you were editing. Reopen it to continue.", table: "Vocabulary")
        case .storageBusy: String(localized: "The notebook is busy. Try again shortly.", table: "Vocabulary")
        }
    }
}
