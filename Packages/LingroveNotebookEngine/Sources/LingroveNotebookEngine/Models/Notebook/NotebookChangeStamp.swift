import Foundation

/// Content-free invalidation domains shared by storage and its host. These flags describe
/// committed data dependencies, never permission to write or an account identity.
public nonisolated struct NotebookChangeDomains: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let corpus = Self(rawValue: 1 << 0)
    public static let review = Self(rawValue: 1 << 1)
    public static let progress = Self(rawValue: 1 << 2)
    public static let ownership = Self(rawValue: 1 << 3)
    public static let synchronization = Self(rawValue: 1 << 4)
    public static let all: Self = [.corpus, .review, .progress, .ownership, .synchronization]
}

/// A transactionally captured dependency token. Schema changes invalidate derived state, and
/// the random epoch prevents a rebuilt clock from reusing an earlier counter's identity.
public nonisolated struct NotebookChangeToken: Equatable, Sendable {
    let schemaVersion: Int
    let epoch: String
    let value: Int64
}

/// Owned by the caller of a metadata probe. SQLite triggers advance these counters in the same
/// transaction as the affected rows, including writes from CLI/other connections. No corpus,
/// review history or serialized account proposal is loaded to construct this value.
public nonisolated struct NotebookChangeStamp: Equatable, Sendable {
    public let corpus: NotebookChangeToken
    public let review: NotebookChangeToken
    public let progress: NotebookChangeToken
    public let ownership: NotebookChangeToken
    public let synchronization: NotebookChangeToken

    public func changes(since previous: Self) -> NotebookChangeDomains {
        var result: NotebookChangeDomains = []
        if corpus != previous.corpus { result.insert(.corpus) }
        if review != previous.review { result.insert(.review) }
        if progress != previous.progress { result.insert(.progress) }
        if ownership != previous.ownership { result.insert(.ownership) }
        if synchronization != previous.synchronization { result.insert(.synchronization) }
        return result
    }
}
