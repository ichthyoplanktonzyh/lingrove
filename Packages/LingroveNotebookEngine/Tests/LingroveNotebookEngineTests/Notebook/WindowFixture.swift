import Foundation
import CryptoKit
import LingroveNotebookSync
import Testing

struct WindowFixture {
    static let pageBytes = VocabularyWireWindowManifest.pageBytes

    let manifest: VocabularyWireWindowManifest
    let pages: [VocabularyWireWindowPage]
    let recordsJSON: Data

    static func empty(
        scope: VocabularyWireWindowScope,
        lifetimeMilliseconds: Int = 900_000,
        now: Date = Date()
    ) throws -> Self {
        try self.make(
            recordsJSON: Data("[]".utf8), recordCount: 0, scope: scope, initialized: false,
            lifetimeMilliseconds: lifetimeMilliseconds, now: now
        )
    }

    static func make(
        recordsJSON: Data,
        recordCount: Int,
        scope: VocabularyWireWindowScope,
        initialized: Bool,
        mode: String = "bootstrap",
        afterSequence: String? = nil,
        highWaterSequence: String = "1",
        windowID: UUID = UUID(),
        lifetimeMilliseconds: Int = 900_000,
        now: Date = Date()
    ) throws -> Self {
        precondition(recordsJSON.isEmpty == false)
        let rawPages = stride(from: 0, to: recordsJSON.count, by: Self.pageBytes).map { start in
            recordsJSON.subdata(in: start..<min(start + Self.pageBytes, recordsJSON.count))
        }
        let pageDigests = rawPages.map(Self.sha256)
        let descriptors = rawPages.enumerated().map { ordinal, bytes in
            "\(ordinal):\(pageDigests[ordinal]):\(bytes.count)\n"
        }.joined()
        let pagesSHA256 = Self.sha256(Data(descriptors.utf8))
        let expiresAtMilliseconds = Int(now.timeIntervalSince1970 * 1_000) + lifetimeMilliseconds
        let manifestFields: [String: Any] = [
            "protocolVersion": 1,
            "workspaceId": scope.workspaceID.uuidString.lowercased(),
            "notebookId": scope.notebookID.uuidString.lowercased(),
            "replicaId": scope.replicaID.uuidString.lowercased(),
            "windowId": windowID.uuidString.lowercased(),
            "ownerUserId": scope.ownerUserID,
            "mode": mode,
            "afterSequence": afterSequence.map { $0 as Any } ?? NSNull(),
            "highWaterSequence": highWaterSequence,
            "initialized": initialized,
            "expiresAtMilliseconds": expiresAtMilliseconds,
            "recordCount": recordCount,
            "pageCount": rawPages.count,
            "byteCount": recordsJSON.count,
            "pagesSha256": pagesSHA256
        ]
        let manifestSHA256 = Self.manifestDigest(
            scope: scope,
            windowID: windowID,
            initialized: initialized,
            mode: mode,
            afterSequence: afterSequence,
            highWaterSequence: highWaterSequence,
            expiresAtMilliseconds: expiresAtMilliseconds,
            recordCount: recordCount,
            pageCount: rawPages.count,
            byteCount: recordsJSON.count,
            pagesSHA256: pagesSHA256
        )
        var manifestObject = manifestFields
        manifestObject["manifestSha256"] = manifestSHA256
        let manifestData = try JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys])
        let manifest = try JSONDecoder().decode(VocabularyWireWindowManifest.self, from: manifestData)
        let pages = try rawPages.enumerated().map { ordinal, bytes in
            try VocabularyWireWindowPage(
                windowID: windowID,
                ordinal: ordinal,
                data: bytes.base64EncodedString(),
                sha256: pageDigests[ordinal],
                byteCount: bytes.count
            )
        }
        return Self(manifest: manifest, pages: pages, recordsJSON: recordsJSON)
    }

    static func manifestDigest(
        scope: VocabularyWireWindowScope,
        windowID: UUID,
        initialized: Bool,
        mode: String = "bootstrap",
        afterSequence: String? = nil,
        highWaterSequence: String = "1",
        expiresAtMilliseconds: Int,
        recordCount: Int,
        pageCount: Int,
        byteCount: Int,
        pagesSHA256: String
    ) -> String {
        let owner = Data(scope.ownerUserID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let lines = [
            "lingrove-corpus-window:1",
            scope.workspaceID.uuidString.lowercased(),
            scope.notebookID.uuidString.lowercased(),
            scope.replicaID.uuidString.lowercased(),
            windowID.uuidString.lowercased(),
            owner,
            mode,
            afterSequence ?? "-",
            highWaterSequence,
            initialized ? "1" : "0",
            String(expiresAtMilliseconds),
            String(recordCount),
            String(pageCount),
            String(byteCount),
            pagesSHA256,
            ""
        ]
        return Self.sha256(Data(lines.joined(separator: "\n").utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
