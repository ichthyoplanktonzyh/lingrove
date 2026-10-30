import LingroveNotebook
import Foundation

/// The archive passes this receipt into the same SQL transaction as a batch's content. It is
/// operational metadata, excluded from vocabulary exports and cards; a lost CLI reply can be
/// recovered without appending a second copy of the learning material.
public nonisolated struct VocabularyCLIReceipt: Sendable {
    public let key: String
    public let fingerprint: String
    public let result: Data
    public init(key: String, fingerprint: String, result: Data) {
        self.key = key
        self.fingerprint = fingerprint
        self.result = result
    }
}
