import Foundation

/// The archive passes this receipt into the same SQL transaction as a batch's content. It is
/// operational metadata, excluded from vocabulary exports and cards; a lost CLI reply can be
/// recovered without appending a second copy of the learning material.
nonisolated struct VocabularyCLIReceipt: Sendable {
    let key: String
    let fingerprint: String
    let result: Data
}
