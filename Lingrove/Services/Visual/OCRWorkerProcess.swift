import Foundation
import CoreGraphics
import Darwin

/// One OCRRuntime's native thread exclusively owns this transport and its child. Nonblocking,
/// deadline-checked pipe I/O avoids readToEnd/waitUntilExit and never occupies a Dispatch worker.
/// A failed child stays retained until exit is observed; replacements cannot overlap it.
nonisolated final class OCRWorkerProcess {
    private let executable: URL
    private let onProcessChange: (Int32?) -> Void
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private(set) var preparationMilliseconds = 0.0
    var identifier: Int32? { process?.processIdentifier }
    var isRunning: Bool { process?.isRunning == true }

    init(executable: URL, onProcessChange: @escaping (Int32?) -> Void = { _ in }) {
        self.executable = executable
        self.onProcessChange = onProcessChange
    }

    func startIfNeeded() throws {
        if isRunning { return }
        closePipes()
        process = nil
        onProcessChange(nil)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw OCRRuntimeFailure.unavailable }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        onProcessChange(child.processIdentifier)
        input = stdin
        output = stdout
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        let writeDescriptor = stdin.fileHandleForWriting.fileDescriptor
        let readDescriptor = stdout.fileHandleForReading.fileDescriptor
        // A worker crash must become EPIPE, never SIGPIPE terminating the app. The option is
        // descriptor-local, so this module does not change signal handling for other features.
        guard fcntl(writeDescriptor, F_SETNOSIGPIPE, 1) != -1,
              fcntl(writeDescriptor, F_SETFL, O_NONBLOCK) != -1,
              fcntl(readDescriptor, F_SETFL, O_NONBLOCK) != -1 else {
            _ = stop()
            throw OCRRuntimeFailure.unavailable
        }
    }

    func recognize(image: CGImage, options: OCRRequestOptions, id: String, deadline: TimeInterval,
                   isShuttingDown: () -> Bool, isCancelled: () -> Bool = { false }) throws -> OCRWorkerResponse {
        let preparationStarted = ProcessInfo.processInfo.systemUptime
        let (request, pixels) = try rasterize(image, options: options, id: id)
        preparationMilliseconds = (ProcessInfo.processInfo.systemUptime - preparationStarted) * 1_000
        try check(deadline: deadline, isShuttingDown: isShuttingDown)
        if isCancelled() { throw CancellationError() }
        try startIfNeeded()
        // Before the first header byte, cancellation can skip Vision safely. Once a frame has
        // begun, it must be sent and drained completely to keep the persistent pipe synchronized.
        if isCancelled() { throw CancellationError() }
        guard let input, let output else { throw OCRRuntimeFailure.unavailable }
        let header = try JSONEncoder().encode(request)
        let writeDescriptor = input.fileHandleForWriting.fileDescriptor
        for data in [OCRWorkerProtocol.lengthPrefix(header.count), header, pixels] {
            try write(data, to: writeDescriptor, deadline: deadline, isShuttingDown: isShuttingDown)
        }
        let readDescriptor = output.fileHandleForReading.fileDescriptor
        let prefix = try read(4, from: readDescriptor, deadline: deadline, isShuttingDown: isShuttingDown)
        let length = OCRWorkerProtocol.length(in: prefix)
        guard (1...OCRWorkerProtocol.maximumResponseBytes).contains(length) else { throw OCRRuntimeFailure.invalidResponse }
        let data = try read(length, from: readDescriptor, deadline: deadline, isShuttingDown: isShuttingDown)
        guard let result = try? JSONDecoder().decode(OCRWorkerResponse.self, from: data),
              result.version == OCRWorkerProtocol.version, result.id == id,
              result.failure.map({ ["no-text", "recognition-failed", "response-too-large"].contains($0) }) ?? !result.lines.isEmpty
        else { throw OCRRuntimeFailure.invalidResponse }
        return result
    }

    /// Cancellation of a Swift caller does not enter here. Only timeout, transport failure,
    /// idle release or application shutdown retires the child, with TERM followed by KILL.
    @discardableResult
    func stop() -> Bool {
        guard let process else { closePipes(); return true }
        if process.isRunning { process.terminate() }
        waitForExit(until: ProcessInfo.processInfo.systemUptime + 0.15)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        waitForExit(until: ProcessInfo.processInfo.systemUptime + 0.75)
        guard !process.isRunning else { return false }
        closePipes()
        self.process = nil
        onProcessChange(nil)
        return true
    }

    private func waitForExit(until deadline: TimeInterval) {
        while isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    private func closePipes() {
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        input = nil
        output = nil
    }

    private func check(deadline: TimeInterval, isShuttingDown: () -> Bool) throws {
        if isShuttingDown() { throw OCRRuntimeFailure.shuttingDown }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw OCRRuntimeFailure.timedOut }
    }

    private func ready(_ descriptor: Int32, event: Int16, deadline: TimeInterval, isShuttingDown: () -> Bool) throws {
        while true {
            try check(deadline: deadline, isShuttingDown: isShuttingDown)
            var descriptor = pollfd(fd: descriptor, events: event, revents: 0)
            let result = poll(&descriptor, 1, 25)
            if result < 0 {
                if errno == EINTR { continue }
                throw OCRRuntimeFailure.workerExited
            }
            if result > 0 { return }
        }
    }

    private func write(_ data: Data, to descriptor: Int32, deadline: TimeInterval, isShuttingDown: () -> Bool) throws {
        var offset = 0
        while offset < data.count {
            try ready(descriptor, event: Int16(POLLOUT), deadline: deadline, isShuttingDown: isShuttingDown)
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), data.count - offset)
            }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw OCRRuntimeFailure.workerExited }
            offset += count
        }
    }

    private func read(_ count: Int, from descriptor: Int32, deadline: TimeInterval,
                      isShuttingDown: () -> Bool) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 65_536))
        while result.count < count {
            try ready(descriptor, event: Int16(POLLIN), deadline: deadline, isShuttingDown: isShuttingDown)
            let received = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, count - result.count))
            }
            if received < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard received > 0 else { throw OCRRuntimeFailure.workerExited }
            result.append(contentsOf: buffer.prefix(received))
        }
        return result
    }

    /// This work occurs only after admission on the runtime's own thread. RGBA copies are bounded
    /// before allocation; preserving input dimensions for reading keeps word boxes unchanged.
    private func rasterize(_ image: CGImage, options: OCRRequestOptions, id: String) throws -> (OCRWorkerRequest, Data) {
        guard options.maxImageDimension > 0 else { throw OCRRuntimeFailure.invalidImage }
        let scale = min(1, Double(options.maxImageDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard width >= 4, height >= 4 else { throw OCRRuntimeFailure.noRecognizedText }
        let request = OCRWorkerRequest(id: id, width: width, height: height,
            maximumCharacters: options.maxRecognizedCharacters, capturesWordBounds: options.capturesWordBounds,
            minimumTextHeight: options.minimumTextHeight, detectsLanguageAutomatically: options.detectsLanguageAutomatically)
        guard let count = request.imageByteCount,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue), let bytes = context.data else { throw OCRRuntimeFailure.invalidImage }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CoreGraphics owns the rendering buffer and its optimized scaling path. Copy into the
        // immutable frame before releasing that context; no borrowed bitmap pointer crosses I/O.
        return (request, Data(bytes: bytes, count: count))
    }

}
