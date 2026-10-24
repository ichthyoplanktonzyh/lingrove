import Foundation
import Dispatch
import Darwin

/// The app owns one lazy local audio runtime. A separate process keeps libmtmd's evolving audio
/// ABI out of autocomplete's pinned llama library. This actor serializes helper sessions and
/// unloads weights after two idle minutes (or idle memory pressure). No model loads while typing.
actor LocalSpeechRuntime {
    private var session: SpeechHelperSession?
    private var configuration: SpeechLocalConfiguration?
    private var activeToken: SpeechPlaybackToken?
    private var idleTask: Task<Void, Never>?
    private var drainTask: Task<Bool, Never>?
    private var drainID: UUID?
    private var drainingSession: SpeechHelperSession?
    private var nextGeneration: UInt64 = 0
    private let helperURL: URL
    private let idleTimeout: Duration
    private let operationTimeout: Duration
    private let events: @Sendable (SpeechRuntimeEvent) async -> Void
    private var memoryPressure: (any DispatchSourceMemoryPressure)?

    // Backpressure is playback-paced: 60 seconds of audio at 0.5x needs 120 seconds by itself.
    // The deadline includes another minute for startup/generation instead of cancelling a healthy stream.
    init(helperURL: URL? = nil, idleTimeout: Duration = .seconds(120), operationTimeout: Duration = .seconds(180),
         events: @escaping @Sendable (SpeechRuntimeEvent) async -> Void = { _ in }) {
        self.helperURL = helperURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/lingrove-tts-helper")
        self.idleTimeout = idleTimeout
        self.operationTimeout = operationTimeout
        self.events = events
    }

    func stream(for request: SpeechAudioRequest, configuration: SpeechLocalConfiguration,
                receive: @escaping SpeechPCMReceiver) async throws {
        try Task.checkCancellation()
        guard let language = LocalSpeechLanguage.code(for: request.language) else { throw SpeechError.unsupportedLanguage }
        try await withTaskCancellationHandler {
            do {
                let helper = try await prepareSession(token: request.token, configuration: configuration)
                try await helper.startIfNeeded(token: request.token)
                try Task.checkCancellation()
                guard activeToken == request.token else { throw CancellationError() }
                try await helper.synthesize(id: request.token.rawValue, text: request.text,
                    language: language, referenceAudio: configuration.referenceAudioURL, sampling: request.sampling, receive: receive)
                try Task.checkCancellation()
                guard activeToken == request.token else { throw CancellationError() }
                activeToken = nil
                idleTask = Task { [weak self, idleTimeout] in
                    do { try await Task.sleep(for: idleTimeout) } catch { return }
                    await self?.releaseIfIdle()
                }
            } catch {
                await cancel(request.token)
                throw error
            }
        } onCancel: {
            Task { await self.cancel(request.token) }
        }
    }

    private func prepareSession(token: SpeechPlaybackToken, configuration: SpeechLocalConfiguration) async throws -> SpeechHelperSession {
        observeMemoryPressureIfNeeded()
        idleTask?.cancel()
        let mustRestart = activeToken != nil || self.configuration != configuration
        activeToken = token
        if mustRestart { try await retireSession() } else if drainTask != nil || drainingSession != nil { try await retireSession() }
        try Task.checkCancellation()
        guard activeToken == token else { throw CancellationError() }
        if let session, await session.hasStopped { try await retireSession() }
        try Task.checkCancellation()
        guard activeToken == token else { throw CancellationError() }
        let helper: SpeechHelperSession
        if let session { helper = session } else {
            nextGeneration &+= 1
            helper = SpeechHelperSession(executable: helperURL, configuration: configuration, timeout: operationTimeout,
                generation: nextGeneration, events: events)
            session = helper
            self.configuration = configuration
        }
        return helper
    }

    func cancel(_ token: SpeechPlaybackToken) async {
        guard activeToken == token else { return }
        activeToken = nil
        try? await retireSession()
    }

    func shutdown() async {
        memoryPressure?.cancel()
        memoryPressure = nil
        idleTask?.cancel()
        activeToken = nil
        try? await retireSession(reason: "shutdown")
    }

    /// Every caller awaits the same teardown barrier. Reserving the new request token before
    /// awaiting it prevents an older actor turn from starting a second model after reentrancy.
    private func retireSession(reason: String = "cancelled") async throws {
        if let previous = session {
            session = nil
            configuration = nil
            drainingSession = previous
        }
        if drainTask == nil, let drainingSession {
            drainID = UUID()
            drainTask = Task { await drainingSession.stop(reason: reason) }
        }
        let identity = drainID
        if let drainTask, !(await drainTask.value) {
            // Keep the old session reachable if native/driver shutdown outlasts the grace
            // period. A later click can retry reaping, but cannot start overlapping models.
            if drainID == identity { self.drainTask = nil; drainID = nil }
            throw SpeechError.runtimeUnavailable
        }
        if drainID == identity {
            drainTask = nil
            drainID = nil
            drainingSession = nil
        }
    }

    private func releaseIfIdle(reason: String = "idle") async {
        guard activeToken == nil else { return }
        try? await retireSession(reason: reason)
    }

    private func observeMemoryPressureIfNeeded() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in Task { await self?.releaseIfIdle(reason: "memory_pressure") } }
        source.resume()
        memoryPressure = source
    }
}

/// One helper's framed PCM exchange. All continuations are actor-owned and consumed exactly once.
/// The reader drains stdout asynchronously; native inference and waiting never block MainActor.
private actor SpeechHelperSession {
    private let executable: URL
    private let configuration: SpeechLocalConfiguration
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let timeout: Duration
    private let events: @Sendable (SpeechRuntimeEvent) async -> Void
    private let sessionID = UUID()
    private let generation: UInt64
    private var eventDelivery: Task<Void, Never>?
    private var eventSequence: UInt64 = 0
    private var lastToken: SpeechPlaybackToken?
    private var loadingStartedAt: TimeInterval = 0
    private var readTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var stopTask: Task<Bool, Never>?
    private var stopID: UUID?
    private var ready = false
    private var started = false
    private var closed = false
    private var failed = false
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var resultWaiter: CheckedContinuation<Void, Error>?
    private var expectedID: String?
    private var chunkReceiver: (SpeechPCMReceiver)?
    private var nextChunk = 0
    private var receivedSamples = 0
    private var sampleRate: Int?

    init(executable: URL, configuration: SpeechLocalConfiguration, timeout: Duration, generation: UInt64,
         events: @escaping @Sendable (SpeechRuntimeEvent) async -> Void) {
        self.executable = executable
        self.configuration = configuration
        self.timeout = timeout
        self.generation = generation
        self.events = events
    }

    var hasStopped: Bool { closed || (started && !process.isRunning) }

    // Keep staged startup and its single bounded reader together; none of these branches
    // represents a separate request or may install a second reader for the same child.
    // swiftlint:disable:next cyclomatic_complexity
    func startIfNeeded(token: SpeechPlaybackToken) async throws {
        lastToken = token
        if ready { notify(.ready, loadMs: 0); return }
        guard !started, !closed, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SpeechError.runtimeUnavailable
        }
        process.executableURL = executable
        process.arguments = ["--model", configuration.modelURL.path, "--mmproj", configuration.projectionURL.path,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        process.standardInput = input
        process.standardOutput = output
        // Native diagnostics may contain local model paths. The card receives a localized error,
        // while normal application logs retain only operation state, never prompts or audio.
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in Task { await self?.terminated() } }
        loadingStartedAt = ProcessInfo.processInfo.systemUptime
        do { try process.run() } catch { throw SpeechError.runtimeUnavailable }
        started = true
        notify(.loading)
        guard !closed else { throw CancellationError() }
        // Close the parent's unused writer so child exit really produces EOF. The reader owns
        // a duplicated descriptor until its loop exits: another actor must not close/reuse that
        // descriptor while a blocking read is in flight.
        try? output.fileHandleForWriting.close()
        let descriptor = fcntl(output.fileHandleForReading.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw SpeechError.runtimeUnavailable }
        // A single utility task performs blocking, bounded pipe reads. It does not inherit this
        // actor: holding the session actor in read() would prevent cancellation/reaping. Awaiting
        // each receiver bounds queued audio and lets a full OS pipe slow native generation.
        readTask = Task.detached(priority: .utility) { [weak self] in
            defer { Darwin.close(descriptor) }
            do {
                var decoder = SpeechAudioFrameDecoder()
                var bytes = [UInt8](repeating: 0, count: 16_384)
                while true {
                    try Task.checkCancellation()
                    // FileHandle.read(upToCount:) may fill its requested length on a pipe. A
                    // single POSIX read returns the ready header immediately, even if tiny.
                    let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else { throw SpeechError.generationFailed }
                    if count == 0 { break }
                    let data = Data(bytes.prefix(count))
                    try decoder.append(data)
                    while let frame = try decoder.next() {
                        try Task.checkCancellation()
                        await self?.receive(frame)
                    }
                }
                try decoder.finish()
                await self?.terminated()
            } catch { await self?.terminated() }
        }
        scheduleTimeout()
        try await withCheckedThrowingContinuation { waiter in
            if ready {
                waiter.resume()
            } else if closed || failed || !process.isRunning {
                waiter.resume(throwing: SpeechError.runtimeUnavailable)
            } else {
                readyWaiter = waiter
            }
        }
    }

    func synthesize(id: UUID, text: String, language: String, referenceAudio: URL?,
                    sampling: ModelSamplingOverrides = .init(), receive: @escaping SpeechPCMReceiver) async throws {
        guard ready, !closed, resultWaiter == nil else { throw SpeechError.generationFailed }
        let values = ModelSamplingValues.speech.applying(sampling)
        var payload: [String: Any] = ["id": id.uuidString, "type": "synthesize", "text": text,
            "language": language, "max_frames": 512, "seed": values.seed,
            "temperature": values.temperature, "top_p": values.topP, "top_k": values.topK,
            "repetition_penalty": values.repetitionPenalty]
        if let referenceAudio { payload["speaker_audio_path"] = referenceAudio.path }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(10)
        lastToken = SpeechPlaybackToken(rawValue: id)
        notify(.generating)
        guard !closed else { throw CancellationError() }
        expectedID = id.uuidString
        chunkReceiver = receive
        nextChunk = 0
        receivedSamples = 0
        sampleRate = nil
        scheduleTimeout()
        try await withCheckedThrowingContinuation { waiter in
            resultWaiter = waiter
            do { try input.fileHandleForWriting.write(contentsOf: data) } catch { failPending() }
        }
    }

    func stop(reason: String = "cancelled") async -> Bool {
        if let stopTask { return await stopTask.value }
        closed = true
        ready = false
        timeoutTask?.cancel()
        timeoutTask = nil
        failPending()
        // A timeout may itself initiate shutdown. Give reaping its own uncancelled task so
        // cancelling that timeout cannot skip the grace periods or temporary-file cleanup.
        // Every caller shares this task, including cancellation racing with process exit.
        let task = Task {
            self.notify(.stopping, reason: reason)
            return await self.terminateAndReap()
        }
        let identity = UUID()
        stopID = identity
        stopTask = task
        let stopped = await task.value
        if !stopped, stopID == identity { stopTask = nil; stopID = nil }
        return stopped
    }

    private func terminateAndReap() async -> Bool {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        // Reap this exact child before another helper is started. Async sleeps keep the actor
        // available to the reader/termination callback and never block the app's UI thread.
        for _ in 0..<40 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for _ in 0..<80 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard !process.isRunning else { return false }
        readTask?.cancel()
        try? output.fileHandleForReading.close()
        notify(.unloaded)
        return true
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            _ = await self?.stop(reason: "operation_timeout")
        }
    }

    private func notify(_ phase: SpeechLocalRuntimePhase, loadMs: Int? = nil, reason: String? = nil) {
        let snapshot = SpeechRuntimeSnapshot(sessionID: sessionID, generation: generation, phase: phase,
            processID: process.isRunning ? process.processIdentifier : nil, modelName: configuration.modelURL.lastPathComponent,
            loadedModelFilenames: [configuration.modelURL.lastPathComponent, configuration.projectionURL.lastPathComponent])
        eventSequence &+= 1
        let event = SpeechRuntimeEvent(snapshot: snapshot, token: lastToken, sequence: eventSequence,
            modelLoadMs: loadMs, reason: reason)
        let previous = eventDelivery
        // Preserve per-session event order while keeping UI/logging out of native cancellation,
        // pipe writes and readiness. A busy MainActor cannot delay SIGTERM or SIGKILL.
        eventDelivery = Task { [events] in
            await previous?.value
            await events(event)
        }
    }

    private func receive(_ frame: SpeechAudioFrameDecoder.Frame) async {
        guard !closed else { return }
        let header = frame.header
        if header.event == "ready", header.protocolVersion == 2, !ready, resultWaiter == nil {
            ready = true
            timeoutTask?.cancel()
            let loadMs = max(0, Int((ProcessInfo.processInfo.systemUptime - loadingStartedAt) * 1_000))
            notify(.ready, loadMs: loadMs)
            let waiter = readyWaiter
            readyWaiter = nil
            waiter?.resume()
        } else if header.event == "chunk", let id = header.id, id == expectedID,
                  header.sequence == nextChunk, header.format == "f32le", header.channels == 1,
                  let rate = header.sampleRate,
                  (8_000...192_000).contains(rate),
                  let count = header.samples, count > 0, count <= SpeechPCMChunk.maximumBytes / 4,
                  frame.payload.count == count * 4, sampleRate == nil || sampleRate == rate,
                  receivedSamples + count <= rate * 60,
                  receivedSamples + count <= SpeechHTTPTransfer.maximumBytes / 4, let chunkReceiver {
            do {
                let chunk = try SpeechPCMChunk(data: frame.payload, sampleRate: rate)
                sampleRate = rate
                receivedSamples += count
                nextChunk += 1
                try await chunkReceiver(chunk)
            } catch {
                guard !closed else { return }
                failPending()
                Task { _ = await self.stop(reason: "playback_rejected") }
            }
        } else if header.event == "result", header.id == expectedID, resultWaiter != nil {
            timeoutTask?.cancel()
            let waiter = resultWaiter
            resultWaiter = nil
            expectedID = nil
            self.chunkReceiver = nil
            guard header.ok == true, receivedSamples > 0, header.samples == receivedSamples,
                  header.sampleRate == sampleRate else {
                waiter?.resume(throwing: SpeechError.generationFailed)
                return
            }
            notify(.ready)
            waiter?.resume()
        } else {
            // This helper is strictly single-flight: a different operation id/version is a
            // protocol failure, rather than a stale result that can be ignored for two minutes.
            failPending()
            Task { _ = await self.stop() }
        }
    }

    private func failPending() {
        failed = true
        let startup = readyWaiter
        let result = resultWaiter
        readyWaiter = nil
        resultWaiter = nil
        expectedID = nil
        chunkReceiver = nil
        startup?.resume(throwing: SpeechError.generationFailed)
        result?.resume(throwing: SpeechError.generationFailed)
    }

    private func terminated() async {
        ready = false
        failPending()
        if !closed {
            notify(.failed, reason: "helper_exit")
            _ = await stop(reason: "helper_exit")
        }
    }
}
