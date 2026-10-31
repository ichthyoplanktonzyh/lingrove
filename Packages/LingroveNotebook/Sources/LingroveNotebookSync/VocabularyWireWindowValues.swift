import CryptoKit
import Foundation

/// Server cursors/clocks are decimal Int64 strings, never JSON doubles or local
/// document revisions. This value preserves exactness above JavaScript's 2^53.
public nonisolated struct VocabularyWireSequence: Hashable, Comparable, Codable, Sendable {
    public let value: Int64
    public var rawValue: String { String(value) }
    public static let zero = Self(value: 0)
    private init(value: Int64) { self.value = value }
    public init(_ text: String) throws {
        guard let value = Int64(text), value >= 0, String(value) == text else { throw VocabularyWireWindowError.invalidRecord }
        self.value = value
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

/// A host supplies this independently of the response. Owner TEXT is compared
/// byte-for-byte: Swift's canonically equivalent Strings are not SQL identities.
public nonisolated struct VocabularyWireWindowScope: Equatable, Sendable {
    public let ownerUserID: String
    public let workspaceID: UUID
    public let notebookID: UUID
    public let replicaID: UUID
    public init(ownerUserID: String, workspaceID: UUID, notebookID: UUID, replicaID: UUID) {
        self.ownerUserID = ownerUserID; self.workspaceID = workspaceID; self.notebookID = notebookID; self.replicaID = replicaID
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ownerUserID.utf8.elementsEqual(rhs.ownerUserID.utf8) && lhs.workspaceID == rhs.workspaceID && lhs.notebookID == rhs.notebookID && lhs.replicaID == rhs.replicaID
    }
}

public nonisolated enum VocabularyWireWindowError: Error, Equatable, Sendable {
    case unsupportedVersion, invalidManifest, scopeMismatch, expiredWindow, invalidPage, incompleteWindow
    case invalidRecord, duplicateRecord, invalidShadow, cursorMismatch, uninitializedNotebook
}

/// Immutable public lease metadata. Decoding checks the exact remote schema and
/// digest; scope/time are checked again whenever bytes are accepted or completed.
public nonisolated struct VocabularyWireWindowManifest: Codable, Equatable, Sendable {
    public enum Mode: String, Sendable { case bootstrap, incremental }
    public let scope: VocabularyWireWindowScope
    public let windowID: UUID
    public let mode: Mode
    public let afterSequence: VocabularyWireSequence?
    public let highWaterSequence: VocabularyWireSequence
    public let initialized: Bool
    public let expiresAtMilliseconds: Int
    public let recordCount: Int
    public let pageCount: Int
    public let byteCount: Int
    public let pagesSHA256: String
    public let manifestSHA256: String
    public static let pageBytes = 256 * 1024
    private static let maximumSafeInteger = 9_007_199_254_740_991

    public init(from decoder: any Decoder) throws {
        var f = try VocabularyWireFields(VocabularyWireJSON(from: decoder))
        guard try f.integer("protocolVersion") == 1 else { throw VocabularyWireWindowError.unsupportedVersion }
        scope = .init(ownerUserID: try f.string("ownerUserId"), workspaceID: try f.uuid("workspaceId"),
            notebookID: try f.uuid("notebookId"), replicaID: try f.uuid("replicaId"))
        windowID = try f.uuid("windowId")
        guard let mode = Mode(rawValue: try f.string("mode")) else { throw VocabularyWireWindowError.invalidManifest }; self.mode = mode
        afterSequence = try f.optional("afterSequence") { try VocabularyWireSequence(VocabularyWireFields.string($0)) }
        highWaterSequence = try .init(f.string("highWaterSequence"))
        initialized = try f.bool("initialized")
        expiresAtMilliseconds = try f.integer("expiresAtMilliseconds", maximum: Self.maximumSafeInteger)
        recordCount = try f.integer("recordCount", maximum: Self.maximumSafeInteger)
        pageCount = try f.integer("pageCount", minimum: 1)
        byteCount = try f.integer("byteCount", maximum: Self.maximumSafeInteger, minimum: 2)
        pagesSHA256 = try f.string("pagesSha256"); manifestSHA256 = try f.string("manifestSha256"); try f.finish()
        guard Self.isSHA256(pagesSHA256), Self.isSHA256(manifestSHA256), pageCount == (byteCount - 1) / Self.pageBytes + 1,
              mode == .bootstrap ? afterSequence == nil : afterSequence.map({ $0 <= highWaterSequence }) == true,
              calculatedDigest == manifestSHA256 else { throw VocabularyWireWindowError.invalidManifest }
    }

    public func encode(to encoder: any Encoder) throws {
        let j = VocabularyWireJSON.object([
            "protocolVersion": .number(1), "workspaceId": .uuid(scope.workspaceID), "notebookId": .uuid(scope.notebookID),
            "replicaId": .uuid(scope.replicaID), "windowId": .uuid(windowID), "ownerUserId": .string(scope.ownerUserID),
            "mode": .string(mode.rawValue), "afterSequence": .optional(afterSequence) { .string($0.rawValue) },
            "highWaterSequence": .string(highWaterSequence.rawValue), "initialized": .bool(initialized),
            "expiresAtMilliseconds": .number(Double(expiresAtMilliseconds)), "recordCount": .number(Double(recordCount)),
            "pageCount": .number(Double(pageCount)), "byteCount": .number(Double(byteCount)), "pagesSha256": .string(pagesSHA256), "manifestSha256": .string(manifestSHA256)
        ]); try j.encode(to: encoder)
    }

    public func validate(expecting expected: VocabularyWireWindowScope, now: Date) throws {
        guard scope == expected else { throw VocabularyWireWindowError.scopeMismatch }
        let milliseconds = now.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds < Double(expiresAtMilliseconds) else { throw VocabularyWireWindowError.expiredWindow }
    }
    private var calculatedDigest: String {
        let owner = Data(scope.ownerUserID.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let lines = ["lingrove-corpus-window:1", scope.workspaceID.uuidString.lowercased(), scope.notebookID.uuidString.lowercased(),
            scope.replicaID.uuidString.lowercased(), windowID.uuidString.lowercased(), owner, mode.rawValue, afterSequence?.rawValue ?? "-",
            highWaterSequence.rawValue, initialized ? "1" : "0", String(expiresAtMilliseconds), String(recordCount), String(pageCount), String(byteCount), pagesSHA256, ""]
        return Self.sha256(Data(lines.joined(separator: "\n").utf8))
    }
    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func sha256(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
}

/// An individual transport page is untrusted until checked against its manifest.
/// Base64 keeps arbitrary byte splits intact; these values are not text pages.
public nonisolated struct VocabularyWireWindowPage: Codable, Equatable, Sendable {
    public let windowID: UUID
    public let ordinal: Int
    public let data: String
    public let sha256: String
    public let byteCount: Int
    public init(windowID: UUID, ordinal: Int, data: String, sha256: String, byteCount: Int) throws {
        guard ordinal >= 0, ordinal <= 2_147_483_647, VocabularyWireWindowManifest.isSHA256(sha256),
              byteCount >= 1, byteCount <= VocabularyWireWindowManifest.pageBytes,
              data.utf8.count <= ((VocabularyWireWindowManifest.pageBytes + 2) / 3) * 4 else { throw VocabularyWireWindowError.invalidPage }
        self.windowID = windowID; self.ordinal = ordinal; self.data = data; self.sha256 = sha256; self.byteCount = byteCount
    }
    public init(from decoder: any Decoder) throws {
        var f = try VocabularyWireFields(VocabularyWireJSON(from: decoder))
        let id = try f.uuid("windowId"), ordinal = try f.integer("ordinal"), encoding = try f.string("encoding")
        guard encoding == "base64" else { throw VocabularyWireWindowError.invalidPage }
        let data = try f.string("data"), sha = try f.string("sha256"), count = try f.integer("byteCount", maximum: VocabularyWireWindowManifest.pageBytes, minimum: 1)
        try f.finish(); try self.init(windowID: id, ordinal: ordinal, data: data, sha256: sha, byteCount: count)
    }
    public func encode(to encoder: any Encoder) throws {
        try VocabularyWireJSON.object(["windowId": .uuid(windowID), "ordinal": .number(Double(ordinal)), "encoding": .string("base64"),
            "data": .string(data), "sha256": .string(sha256), "byteCount": .number(Double(byteCount))]).encode(to: encoder)
    }
    public func verifiedBytes(for manifest: VocabularyWireWindowManifest, expecting scope: VocabularyWireWindowScope, now: Date) throws -> Data {
        try manifest.validate(expecting: scope, now: now)
        guard windowID == manifest.windowID, ordinal < manifest.pageCount,
              byteCount == (ordinal == manifest.pageCount - 1 ? manifest.byteCount - ordinal * VocabularyWireWindowManifest.pageBytes : VocabularyWireWindowManifest.pageBytes),
              let bytes = Data(base64Encoded: data), bytes.base64EncodedString() == data,
              bytes.count == byteCount, VocabularyWireWindowManifest.sha256(bytes) == sha256 else { throw VocabularyWireWindowError.invalidPage }
        return bytes
    }
}
