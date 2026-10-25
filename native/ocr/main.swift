import Foundation
import CoreGraphics
import NaturalLanguage
import Vision
import Darwin

/// A single process-lifetime loop performs one Vision request at a time. Only this executable
/// enters synchronous Vision; a stuck framework can be terminated without consuming app workers.
/// Each autorelease pool releases image/request intermediates before the next framed request.
enum OCRHelper {
    static func readExactly(_ count: Int, allowsEOF: Bool = false) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let part = try FileHandle.standardInput.read(upToCount: count - data.count), !part.isEmpty else {
                if allowsEOF && data.isEmpty { return nil }
                throw CocoaError(.fileReadCorruptFile)
            }
            data.append(part)
        }
        return data
    }

    static func nextRequest() throws -> (OCRWorkerRequest, Data)? {
        guard let prefix = try readExactly(4, allowsEOF: true) else { return nil }
        let length = OCRWorkerProtocol.length(in: prefix)
        guard (1...OCRWorkerProtocol.maximumHeaderBytes).contains(length), let header = try readExactly(length) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let request = try JSONDecoder().decode(OCRWorkerRequest.self, from: header)
        guard let count = request.imageByteCount, let pixels = try readExactly(count) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (request, pixels)
    }

    static func recognize(_ input: OCRWorkerRequest, pixels: Data) -> OCRWorkerResponse {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: input.width, height: input.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: input.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                                      CGBitmapInfo.byteOrder32Big.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            return OCRWorkerResponse(id: input.id, failure: "recognition-failed")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = input.minimumTextHeight
        request.automaticallyDetectsLanguage = input.detectsLanguageAutomatically
        do {
            // No callback bridge or native cancel is needed: the parent retires stale results
            // logically, and kills this owned process if perform never returns.
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return OCRWorkerResponse(id: input.id, failure: "recognition-failed")
        }
        let observations = (request.results ?? []).sorted {
            if abs($0.boundingBox.minY - $1.boundingBox.minY) > 0.02 { return $0.boundingBox.minY > $1.boundingBox.minY }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        var lines: [OCRWorkerResponse.Line] = []
        var words: [OCRWorkerResponse.Word] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if input.capturesWordBounds { words += self.words(in: observation, lineIndex: lines.count) }
            lines.append(.init(text: text, confidence: candidate.confidence, boundingBox: observation.boundingBox))
        }
        guard !lines.isEmpty else { return OCRWorkerResponse(id: input.id, failure: "no-text") }
        return OCRWorkerResponse(id: input.id, lines: lines, words: words)
    }

    static func words(in observation: VNRecognizedTextObservation, lineIndex: Int) -> [OCRWorkerResponse.Word] {
        guard let candidate = observation.topCandidates(1).first else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = candidate.string
        var result: [OCRWorkerResponse.Word] = []
        tokenizer.enumerateTokens(in: candidate.string.startIndex..<candidate.string.endIndex) { range, _ in
            if let box = try? candidate.boundingBox(for: range) {
                let offset = NSRange(range, in: candidate.string)
                let leading = candidate.string.prefix(while: \.isWhitespace).utf16.count
                result.append(.init(text: String(candidate.string[range]), boundingBox: box.boundingBox,
                    lineIndex: lineIndex, utf16Location: offset.location - leading,
                    utf16Length: offset.length, confidence: candidate.confidence))
            }
            return true
        }
        return result
    }

    static func write(_ response: OCRWorkerResponse) throws {
        var output = try JSONEncoder().encode(response)
        if output.count > OCRWorkerProtocol.maximumResponseBytes {
            output = try JSONEncoder().encode(OCRWorkerResponse(id: response.id, failure: "response-too-large"))
        }
        try FileHandle.standardOutput.write(contentsOf: OCRWorkerProtocol.lengthPrefix(output.count))
        try FileHandle.standardOutput.write(contentsOf: output)
    }
}

// A parent crash/SIGKILL closes its pipes, but a hung Vision call cannot read EOF. This native
// watchdog also exits the helper after reparenting, independently of its own Dispatch pool.
let parent = getppid()
Thread.detachNewThread {
    while getppid() == parent { Thread.sleep(forTimeInterval: 1) }
    _exit(0)
}
do {
    while let (request, pixels) = try OCRHelper.nextRequest() {
        try autoreleasepool { try OCRHelper.write(OCRHelper.recognize(request, pixels: pixels)) }
    }
} catch {
    // stdout is exclusively framed responses; malformed input/EOF ends the process cleanly.
    exit(1)
}
