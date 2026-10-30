import Foundation
import LingroveNotebook

/// The app keeps its established names while both Apple targets use one shared
/// content and backup implementation. These aliases add no second representation
/// or codec; the app-owned archive continues to own persistence and media IO.
typealias VocabularyContentBlock = LingroveNotebook.VocabularyContentBlock
typealias VocabularyTextContent = LingroveNotebook.VocabularyTextContent
typealias VocabularyImageReference = LingroveNotebook.VocabularyImageReference
typealias VocabularyPreparedImage = LingroveNotebook.VocabularyPreparedImage

/// A portable, versioned single-file backup includes exactly the referenced media. Base64 is
/// the JSON transport, not the live storage format; regular notebook writes remain small.
typealias VocabularyBackup = LingroveNotebook.VocabularyBackup
