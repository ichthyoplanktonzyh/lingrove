import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Optional, app-owned diagnostic storage. The context generator submits immutable captures and
/// immediately continues; one background OS thread owns PNG encoding and every filesystem call.
/// A file provider can block even a directory listing indefinitely, so using Task.detached here
/// would risk occupying the same shared executor that OCR isolation was introduced to protect.
/// Admission retains at most one active and one latest pending capture, including during a stall.
nonisolated final class DebugScreenshotWriter: @unchecked Sendable {
    /// The pixel image is immutable and shared until encoding; submission does not copy its bytes.
    /// This value lives only until its write finishes, it is superseded, or admission shuts down.
    nonisolated struct Capture: Sendable {
        let image: CGImage
        let text: String
        let applicationName: String
        let capturedAt: Date
    }

    private let condition = NSCondition()
    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let writeCapture: @Sendable (Capture) throws -> Void
    private let onFailure: @Sendable () -> Void
    private var pending: Capture?
    private var started = false
    private var closed = false
    private var lastAccepted = -Double.infinity
    private static let maximumImageBytes = 64 * 1_024 * 1_024

    init(directory: URL? = nil, minimumInterval: TimeInterval = 5,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         writeCapture: (@Sendable (Capture) throws -> Void)? = nil,
         onFailure: @escaping @Sendable () -> Void = {}) {
        let store = DebugScreenshotStore(directory: directory)
        self.minimumInterval = minimumInterval
        self.now = now
        self.writeCapture = writeCapture ?? { try store.write($0) }
        self.onFailure = onFailure
    }

    /// Best-effort diagnostics may be sampled or dropped. The product's OCR result never waits
    /// for this return value, and no directory resolution, encoding or I/O happens in admission.
    @discardableResult
    func submit(image: CGImage, text: String, applicationName: String) -> Bool {
        guard image.height > 0, image.bytesPerRow > 0,
              image.bytesPerRow <= Self.maximumImageBytes / image.height else { return false }
        let instant = now()
        let capture = Capture(image: image, text: String(text.prefix(12_000)),
                              applicationName: applicationName, capturedAt: Date())
        condition.lock()
        guard !closed, instant - lastAccepted >= minimumInterval else { condition.unlock(); return false }
        let superseded = pending
        pending = capture
        lastAccepted = instant
        let shouldStart = !started
        started = true
        condition.signal()
        condition.unlock()
        // Release a superseded image outside the admission lock; ARC can destroy its backing data.
        withExtendedLifetime(superseded) {}
        if shouldStart {
            let thread = Thread { self.run() }
            thread.name = "Lingrove diagnostic screenshots"
            thread.qualityOfService = .background
            thread.start()
        }
        return true
    }

    /// Quitting closes admission and discards pending captures without joining a possibly blocked
    /// filesystem thread. Debug files are disposable; they must never delay application shutdown.
    func shutdown() {
        condition.lock()
        closed = true
        let discarded = pending
        pending = nil
        condition.signal()
        condition.unlock()
        withExtendedLifetime(discarded) {}
    }

    private func next() -> Capture? {
        condition.lock()
        defer { condition.unlock() }
        while pending == nil && !closed { condition.wait() }
        guard !closed else { return nil }
        let capture = pending
        pending = nil
        return capture
    }

    private func run() {
        while let capture = next() {
            autoreleasepool {
                do { try writeCapture(capture) } catch { onFailure() }
            }
        }
    }
}

/// Synchronous disk work owned exclusively by the writer's thread. Separating storage from
/// admission lets tests hold a write indefinitely without touching a real cloud-backed folder.
/// Captures live beside local logs; the old Desktop archive is left untouched. Timestamped names
/// let retention sort without fetching creation-date metadata for every file on every capture.
nonisolated struct DebugScreenshotStore: Sendable {
    let directory: URL?
    var maximumCapturesPerApp = 20

    func write(_ capture: DebugScreenshotWriter.Capture) throws {
        let root = directory ?? defaultDirectory()
        let folder = root.appendingPathComponent(sanitizedName(capture.applicationName), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        let name = "capture-\(formatter.string(from: capture.capturedAt))-\(UUID().uuidString)"
        let imageURL = folder.appendingPathComponent(name).appendingPathExtension("png")
        let textURL = folder.appendingPathComponent(name).appendingPathExtension("txt")
        do {
            guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL,
                UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, capture.image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            try capture.text.write(to: textURL, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: textURL)
            throw error
        }
        try trim(folder)
    }

    private func defaultDirectory() -> URL {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Lingrove"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    private func trim(_ folder: URL) throws {
        let images = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.pathExtension == "png" && $0.lastPathComponent.hasPrefix("capture-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for image in images.prefix(max(0, images.count - maximumCapturesPerApp)) {
            try FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: image.deletingPathExtension().appendingPathExtension("txt"))
        }
    }

    private func sanitizedName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? $0 : UnicodeScalar("_") }
        let result = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return result.isEmpty ? "unknown-app" : result
    }
}
