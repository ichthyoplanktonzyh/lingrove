import Foundation

/// A file-backed parser owned by one app actor. This type deliberately is not Sendable: its
/// small decompressed-block caches are mutable, and calls must remain on their owning actor.
public final class MDictFile {
    private let reader: MDictReader
    public var title: String { reader.header.title }
    public var entryCount: Int { reader.entryCount }
    public var version: Double { reader.header.version }
    public var isHTML: Bool { reader.header.isHTML }

    public init(url: URL) throws { reader = try MDictReader(url: url) }
    public func definitions(for query: String) throws -> [String] {
        try Task.checkCancellation()
        return try reader.lookupAll(query)
    }
    public func resource(for key: String) throws -> Data? {
        try Task.checkCancellation()
        return try reader.lookupData(for: key)
    }
}
