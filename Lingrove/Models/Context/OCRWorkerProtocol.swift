import Foundation
import CoreGraphics

/// The app and bundled OCR executable compile this same local-only wire contract. Length-prefixed
/// JSON describes a bounded RGBA image; pixel bytes follow separately, never through disk or a URL.
/// Version and request identity keep a restarted worker's output from satisfying another request.
nonisolated enum OCRWorkerProtocol {
    static let version = 1
    static let maximumHeaderBytes = 65_536
    static let maximumImageBytes = 128 * 1_024 * 1_024
    static let maximumResponseBytes = 8 * 1_024 * 1_024

    static func lengthPrefix(_ count: Int) -> Data {
        var value = UInt32(count).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    static func length(in data: Data) -> Int {
        data.reduce(0) { ($0 << 8) | Int($1) }
    }
}

/// Priority belongs to the user's operation, not to Vision's configuration. Both paths share one
/// runtime, with at most the latest queued request for each purpose retained in memory.
nonisolated enum OCRRequestPurpose: Sendable, CaseIterable, Hashable {
    case visualContext, reading
}

/// Immutable per-call options preserve the existing context and reading recognition behavior.
/// The runtime owns admission before rasterization, so cancelled queued images incur no CPU work.
nonisolated struct OCRRequestOptions: Sendable {
    var maxImageDimension: Int
    var maxRecognizedCharacters: Int
    var capturesWordBounds = false
    var minimumTextHeight: Float = 0.008
    var detectsLanguageAutomatically = false
    var purpose = OCRRequestPurpose.visualContext
}

/// Transient request metadata; only the helper validates and consumes it. The size check precedes
/// allocation and multiplication, so malformed dimensions cannot request an unbounded image buffer.
nonisolated struct OCRWorkerRequest: Codable, Sendable {
    var version = OCRWorkerProtocol.version
    let id: String
    let width: Int
    let height: Int
    let maximumCharacters: Int
    let capturesWordBounds: Bool
    let minimumTextHeight: Float
    let detectsLanguageAutomatically: Bool

    var imageByteCount: Int? {
        guard version == OCRWorkerProtocol.version, width >= 4, height >= 4,
              width <= OCRWorkerProtocol.maximumImageBytes / 4 / height,
              (1...1_000_000).contains(maximumCharacters), minimumTextHeight.isFinite,
              (0...1).contains(minimumTextHeight), id.utf8.count <= 64 else { return nil }
        return width * height * 4
    }
}

/// Recognition values are owned by one response and released after conversion to the app's
/// existing ExtractedScreenText. Coordinates retain Vision's normalized bottom-left convention.
nonisolated struct OCRWorkerResponse: Codable, Sendable {
    var version = OCRWorkerProtocol.version
    let id: String
    var failure: String?
    var lines: [Line] = []
    var words: [Word] = []

    nonisolated struct Line: Codable, Sendable {
        let text: String
        let confidence: Float
        let boundingBox: CGRect
    }

    nonisolated struct Word: Codable, Sendable {
        let text: String
        let boundingBox: CGRect
        /// Exact offset into the emitted line, preserving repeated words without string search.
        var lineIndex: Int?
        var utf16Location: Int?
        var utf16Length: Int?
        var confidence: Float?
    }
}

/// Internal runtime outcomes are separate from UI wording. The extractor maps these into the
/// existing unavailable-context/reading-error paths; cancellation keeps its normal Swift meaning.
nonisolated enum OCRRuntimeFailure: String, Error, Sendable {
    case timedOut, unavailable, invalidImage, invalidResponse, workerExited, shuttingDown, noRecognizedText
}
