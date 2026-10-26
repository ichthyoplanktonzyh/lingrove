import Combine
import Foundation
import Logging

/// File overview:
/// Publishes runtime bootstrap state and user-facing diagnostics for the menu bar and startup UI.
/// The manager does not talk to native llama.cpp APIs directly anymore; it delegates that work to
/// `LlamaRuntimeCore`, which keeps pointer ownership and generation serialization in a separate file.
///
/// `@MainActor` keeps the published state SwiftUI-friendly while the heavy inference work runs
/// inside `LlamaRuntimeCore`, a thread-safe class backed by the C++ `CotabbyInferenceEngine`.
@MainActor
final class LlamaRuntimeManager: ObservableObject {
    @Published private(set) var state: RuntimeBootstrapState = .idle
    @Published private(set) var diagnostics = LlamaRuntimeDiagnostics()
    @Published private(set) var availableModels: [RuntimeModelOption] = []

    private let configuration: LlamaRuntimeConfiguration
    private let runtimeLocator: BundledRuntimeLocator
    private let core: LlamaRuntimeCore
    private let shutdownOperation: @Sendable () -> Void
    private let cacheResetOperation: @Sendable () -> Void
    /// Resets must stay ordered even when the coordinator cancels a superseded reset caller.
    /// The newest barrier includes earlier maintenance, so no late reset can clear newer KV.
    private var pendingCacheReset: (id: UUID, task: Task<Void, Never>)?
    /// A new load must wait for every earlier unload; native serialization alone cannot preserve
    /// the manager cache if a late unload runs after a new preparation has published readiness.
    private var pendingShutdown: (id: UUID, task: Task<Void, Never>)?
    /// The composition root supplies completion eligibility; learning owns different native sessions.
    var isEnabledProvider: () -> Bool = { true }

    private var startupTask: Task<PreparedLlamaRuntime, Error>?
    private var startupModelFilename: String?
    private var startupContextWindowTokens: Int?
    private var startupID = UUID()
    /// The app supplies the selected model's saved budget for warmup; requests carry their own
    /// immutable choice. The manager remains the sole native-runtime lifecycle owner.
    var contextWindowTokensProvider: (() -> Int?)?
    private var cachedRuntime: PreparedLlamaRuntime?
    private var selectedModelFilename: String?
    private let modelTaskAssignments: LocalModelTaskAssignments

    /// Read-only view of the model currently selected for autocomplete generation. Used by
    /// downstream observers (the performance metrics recorder) that want to label a recorded
    /// request with the actual GGUF filename, e.g. `Qwen3-0.6B-Q8_0.gguf`. Returns nil when no
    /// model has been configured yet.
    var currentModelFilename: String? {
        selectedModelFilename
    }

    convenience init() {
        self.init(
            configuration: .default,
            runtimeLocator: BundledRuntimeLocator()
        )
    }

    init(
        configuration: LlamaRuntimeConfiguration,
        runtimeLocator: BundledRuntimeLocator,
        shutdownOperation: (@Sendable () -> Void)? = nil,
        cacheResetOperation: (@Sendable () -> Void)? = nil,
        modelTaskAssignments: LocalModelTaskAssignments? = nil
    ) {
        self.configuration = configuration
        self.runtimeLocator = runtimeLocator
        self.modelTaskAssignments = modelTaskAssignments ?? LocalModelTaskAssignments()
        let runtimeCore = LlamaRuntimeCore()
        core = runtimeCore
        self.shutdownOperation = shutdownOperation ?? { runtimeCore.shutdown() }
        self.cacheResetOperation = cacheResetOperation ?? { runtimeCore.resetPromptCache() }
        refreshAvailableModels()
    }

    private var isRefreshingModels = false

    /// Re-scans local runtime directories for GGUF files and republishes discovered options.
    /// This is called after model downloads so selection UI updates without app restart.
    func refreshAvailableModels() {
        guard !isRefreshingModels else { return }
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        availableModels = runtimeLocator.availableModels(configuration: configuration)
            .filter {
                var tasks = modelTaskAssignments.tasks(for: $0.filename)
                // An explicitly supplied runtime configuration is also an opt-in (used by
                // embedded/test runtimes); ordinary discovery has only the curated preferences.
                if configuration.preferredModelNames.contains($0.filename) { tasks.insert(.completion) }
                return LocalModelTaskPolicy.isCandidate($0.filename, task: .completion, assignedTasks: tasks)
            }
        selectedModelFilename = normalizedModelFilename(selectedModelFilename)
        LingroveLogger.runtime.info("Discovered \(self.availableModels.count) model(s)")
    }

    /// Records which discovered model should be loaded when preparation starts.
    /// This keeps persisted UI state separate from the runtime loading lifecycle.
    func configureSelectedModel(filename: String?) {
        // @Published sends the new list before storing it. RuntimeBootstrapModel reconciles its
        // choice synchronously inside that notification. Record the choice now, then let the
        // enclosing refresh normalize it against the committed list; rescanning here recurses
        // forever when the very first downloaded model was absent from the old list.
        if isRefreshingModels {
            selectedModelFilename = filename
            return
        }
        if let filename, modelTaskAssignments.record(filename, for: .completion),
           !availableModels.contains(where: { $0.filename == filename }) {
            refreshAvailableModels()
        }
        selectedModelFilename = normalizedModelFilename(filename)
        LingroveLogger.runtime.info("Configured selected model: \(self.selectedModelFilename ?? "none")")
    }

    /// Ensures the selected local model is resolved and prepared before any generation requests run.
    func prepare() async throws {
        _ = try await preparedRuntime()
    }

    /// Reloads the runtime in place with a newly selected local model.
    /// The manager instance stays alive; only the loaded model changes.
    func selectModel(filename: String) async throws {
        guard LocalModelTaskPolicy.supports(filename, task: .completion) else {
            throw LlamaRuntimeError.unavailable(String(
                localized: "This model is not compatible with this task. Choose another model.", table: "Learning"))
        }
        LingroveLogger.runtime.info("Selecting model: \(filename)")
        guard let normalizedFilename = normalizedModelFilename(filename) else {
            let error = LlamaRuntimeError.unavailable(
                String(localized: "The selected model \(filename) is unavailable."))
            diagnostics.lastError = error.localizedDescription
            throw error
        }

        selectedModelFilename = normalizedFilename

        if cachedRuntime?.resolvedRuntime.modelFileURL.lastPathComponent == normalizedFilename,
            cachedRuntime?.contextWindowTokens == (contextWindowTokensProvider?() ?? Int(configuration.contextWindowTokens)) {
            return
        }

        startupID = UUID()
        startupTask?.cancel()
        startupTask = nil
        startupModelFilename = nil
        cachedRuntime = nil

        _ = try await preparedRuntime()
    }

    /// Forwards one generation request to the runtime core after ensuring preparation.
    /// `cachedPrefixBytes` is a caller-provided reuse hint, not a correctness guarantee; the core
    /// still validates the token prefix before trusting any native KV state.
    func generate(
        prompt: String,
        cachedPrefixBytes: Int? = nil,
        options: LlamaGenerationOptions
    ) async throws -> LlamaGenerationOutput {
        try await generate(
            prompt: prompt,
            cachedPrefixBytes: cachedPrefixBytes,
            options: options,
            onPartialRawText: nil
        )
    }

    /// Streaming variant: `onPartialRawText` is invoked from the decode thread with the cumulative
    /// raw completion after each sampled token; see `LlamaRuntimeGenerating`.
    func generate(
        prompt: String,
        cachedPrefixBytes: Int? = nil,
        options: LlamaGenerationOptions,
        onPartialRawText: (@Sendable (String) -> Void)?
    ) async throws -> LlamaGenerationOutput {
        _ = try await preparedRuntime(contextWindowTokens: options.contextWindowTokens)
        // Loading can suspend while another reset is enqueued. Recheck immediately before
        // submitting decode/prefill, so ready metadata cannot bypass queued maintenance.
        try await awaitPendingCacheResetIfNeeded()

        let core = self.core
        let operationID = UUID()
        do {
            // `Task.detached` does not inherit the caller's cancellation, so an outer cancel
            // would otherwise leave `core.generate` running to its full prediction budget while
            // holding `autocompleteLock`. The handler forwards the cancel signal, and the loop
            // inside `core.generate` polls `Task.isCancelled` between sampleNext calls.
            let task = Task.detached {
                try core.generate(
                    prompt: prompt,
                    cachedPrefixBytes: cachedPrefixBytes,
                    options: options,
                    operationID: operationID,
                    onPartialRawText: onPartialRawText
                )
            }
            return try await withTaskCancellationHandler {
                // `core.generate` cooperates with cancellation by returning the partial buffer it
                // accumulated instead of throwing, which is the right behavior for the inference
                // layer (the abort target must clear and the lock must release on the way out;
                // cache restoration waits until the next request's prefix is known).
                // The manager surfaces the cancellation as a thrown `CancellationError` so the
                // `catch` below stays reachable and so callers see the same vocabulary as a
                // throwing path. The outer task is the one that was cancelled (that is why
                // `onCancel` ran), so `Task.checkCancellation()` throws here.
                let partial = try await task.value
                try Task.checkCancellation()
                return partial
            } onCancel: {
                task.cancel()
                // Task cancellation is only polled between sampled tokens, so an in-flight prompt
                // prefill would otherwise run to completion while holding the autocomplete lock,
                // making the superseding request wait out the whole stale decode. The engine-level
                // flag stops before the next prompt batch; an already-submitted batch finishes.
                core.abortInFlightGeneration(operationID: operationID)
            }
        } catch is CancellationError {
            LingroveLogger.runtime.debug("Generation cancelled")
            throw LlamaRuntimeError.cancelled
        } catch let error as LlamaRuntimeError {
            LingroveLogger.runtime.error("Generation runtime error: \(error.localizedDescription)")
            diagnostics.lastError = error.localizedDescription
            throw error
        } catch {
            LingroveLogger.runtime.error("Generation failed: \(error.localizedDescription)")
            let runtimeError = LlamaRuntimeError.generationFailed(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            throw runtimeError
        }
    }

    /// Clears KV without unloading weights. Native maintenance can wait behind a noninterruptible
    /// load/decode; calling it synchronously here would freeze every main-actor control, including
    /// the menu's completion switch. Detach only that blocking boundary and await its completion.
    /// Cancellation of a UI caller must not discard an already queued invalidation.
    func resetPromptCache() async {
        let previous = pendingCacheReset?.task
        let operation = cacheResetOperation
        let task = Task.detached {
            await previous?.value
            operation()
        }
        let id = UUID()
        pendingCacheReset = (id, task)
        await task.value
        if pendingCacheReset?.id == id { pendingCacheReset = nil }
    }

    /// All native entry paths await the latest reset chain. The actor may reenter during a
    /// wait, so repeat until even a newly appended reset has completed; only clear our own ID.
    private func awaitPendingCacheResetIfNeeded() async throws {
        while let reset = pendingCacheReset {
            await reset.task.value
            if pendingCacheReset?.id == reset.id { pendingCacheReset = nil }
            try Task.checkCancellation()
        }
    }

    /// Decodes `prompt` into the native prompt cache without sampling (the llama half of
    /// prewarm-on-focus). Best-effort by contract: cancellation is silent and failures only log,
    /// because a missed warmup just means the next generate pays the cold prefill it would have
    /// paid anyway. Errors are deliberately kept out of `diagnostics.lastError`.
    func prefill(
        prompt: String,
        cachedPrefixBytes: Int? = nil,
        options: LlamaGenerationOptions
    ) async throws {
        _ = try await preparedRuntime(contextWindowTokens: options.contextWindowTokens)
        // Loading can suspend while another reset is enqueued. Recheck immediately before
        // submitting decode/prefill, so ready metadata cannot bypass queued maintenance.
        try await awaitPendingCacheResetIfNeeded()

        let core = self.core
        let operationID = UUID()
        let task = Task.detached {
            try core.prefill(
                prompt: prompt,
                cachedPrefixBytes: cachedPrefixBytes,
                options: options,
                operationID: operationID
            )
        }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
            // A prefill is superseded the moment a real generation arrives; abort its native
            // work between batches so generation need not wait for the entire stale prompt.
            core.abortInFlightGeneration(operationID: operationID)
        }
    }

    /// Cancels any retained prepared runtime and releases backend resources.
    /// Shutdown runs on a detached thread so it does not block the main actor.
    func stop() {
        LingroveLogger.runtime.info("Runtime stop requested")
        prepareForStop()
        let previous = pendingShutdown?.task
        let operation = shutdownOperation
        let task = Task.detached {
            await previous?.value
            operation()
        }
        pendingShutdown = (UUID(), task)
    }

    /// Synchronously releases the llama runtime on the current thread after closing work admission.
    /// This is the termination-time path: C++ static destructors during `exit()` tear down the Metal
    /// device, so llama contexts must be released first to avoid `ggml_metal_rsets_free`. Returning
    /// promptly also keeps macOS's "Quit & Reopen" TCC handshake working after a permission grant —
    /// the previous `.terminateLater` approach delayed exit long enough that the relaunched process
    /// never picked up the new permission.
    /// `timeoutSeconds` is a drain grace period. A live native load cannot be safely interrupted,
    /// so the shared session still waits before freeing it instead of racing Metal teardown.
    func shutdownSync(timeoutSeconds: TimeInterval) {
        prepareForStop()
        core.shutdown(timeoutSeconds: timeoutSeconds)
    }

    private func prepareForStop() {
        startupID = UUID()
        startupTask?.cancel()
        startupTask = nil
        startupModelFilename = nil
        cachedRuntime = nil

        diagnostics.lastLoadStatus = "Stopped"
        state = .idle
    }

    /// Returns cached runtime metadata when available or performs one full preparation flow otherwise.
    private func preparedRuntime(contextWindowTokens: Int? = nil) async throws -> PreparedLlamaRuntime {
        try await awaitPendingCacheResetIfNeeded()
        try Task.checkCancellation()
        while let shutdown = pendingShutdown {
            await shutdown.task.value
            if pendingShutdown?.id == shutdown.id { pendingShutdown = nil }
            try Task.checkCancellation()
        }
        guard isEnabledProvider() else { throw CancellationError() }
        let requestedWindow = min(
            ModelContextBudget.maximumLocalTokens,
            max(
                1_024,
                contextWindowTokens ?? contextWindowTokensProvider?() ?? Int(configuration.contextWindowTokens)))
        let configuration = LlamaRuntimeConfiguration(
            runtimeDirectoryPath: configuration.runtimeDirectoryPath,
            preferredModelNames: configuration.preferredModelNames, contextWindowTokens: Int32(requestedWindow),
            batchSize: configuration.batchSize, gpuLayerCount: configuration.gpuLayerCount)
        let resolvedRuntime = try resolveSelectedRuntime()
        let requestedModelFilename = resolvedRuntime.modelFileURL.lastPathComponent

        if let cachedRuntime,
            cachedRuntime.resolvedRuntime.modelFileURL == resolvedRuntime.modelFileURL,
            cachedRuntime.contextWindowTokens == requestedWindow {
            LingroveLogger.runtime.trace("Using cached runtime for \(requestedModelFilename)")
            return cachedRuntime
        }

        // Deduplicate concurrent prepare calls for the same selected model, but cancel and
        // replace the task if the requested model changed while startup was already in flight.
        if let startupTask {
            if startupModelFilename == requestedModelFilename, startupContextWindowTokens == requestedWindow {
                LingroveLogger.runtime.debug("Reusing in-flight startup for \(requestedModelFilename)")
                return try await awaitPreparedRuntime(startupTask, id: startupID)
            }

            LingroveLogger.runtime.info("Model changed to \(requestedModelFilename), cancelling previous startup")
            startupTask.cancel()
            self.startupTask = nil
            startupModelFilename = nil
        }

        cachedRuntime = nil

        state = .starting(String(localized: "Initializing the in-process llama runtime.", table: "Learning"))
        diagnostics.lastError = nil
        diagnostics.lastLoadStatus = "Starting"
        diagnostics.modelFilePath = resolvedRuntime.modelFileURL.path
        let startupTask = Task.detached { [core, configuration] in
            try Task.checkCancellation()
            return try core.prepare(
                resolvedRuntime: resolvedRuntime,
                configuration: configuration
            )
        }
        startupID = UUID()
        self.startupTask = startupTask
        startupModelFilename = requestedModelFilename
        startupContextWindowTokens = requestedWindow
        LingroveLogger.runtime.info("Loading \(resolvedRuntime.modelDisplayName) into memory")
        state = .loading(String(localized: "Loading \(resolvedRuntime.modelDisplayName) into memory."))

        return try await awaitPreparedRuntime(startupTask, id: startupID)
    }

    /// Resolves either the explicitly selected model or the default preferred model order.
    private func resolveSelectedRuntime() throws -> ResolvedLlamaRuntime {
        if let selectedModelFilename, !LocalModelTaskPolicy.supports(selectedModelFilename, task: .completion) {
            throw LlamaRuntimeError.unavailable(String(
                localized: "This model is not compatible with this task. Choose another model.", table: "Learning"))
        }
        do {
            guard let selectedModelFilename else {
                throw LlamaRuntimeError.unavailable("No autocomplete GGUF model is available.")
            }
            return try runtimeLocator.resolve(
                configuration: configuration,
                selectedModelFilename: selectedModelFilename
            )
        } catch {
            let runtimeError = LlamaRuntimeError.unavailable(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(runtimeError.localizedDescription)
            throw runtimeError
        }
    }

    /// Validates the chosen filename against discovered local models and falls back to the first
    /// available option when the caller passes `nil` or a missing filename.
    private func normalizedModelFilename(_ filename: String?) -> String? {
        if let filename, !filename.isEmpty, !LocalModelTaskPolicy.supports(filename, task: .completion) {
            return filename
        }
        guard !availableModels.isEmpty else {
            return nil
        }

        guard let filename else {
            return availableModels.first?.filename
        }

        if availableModels.contains(where: { $0.filename == filename }) {
            return filename
        }

        return availableModels.first?.filename
    }

    /// Awaits the prepared runtime task and applies the published diagnostics on success.
    private func awaitPreparedRuntime(_ startupTask: Task<PreparedLlamaRuntime, Error>, id: UUID) async throws -> PreparedLlamaRuntime {
        let prepared: PreparedLlamaRuntime
        do {
            prepared = try await startupTask.value
        } catch {
            // A superseded load must not clear the newer load's task or publish its failure.
            guard startupID == id else { throw LlamaRuntimeError.cancelled }
            self.startupTask = nil; startupModelFilename = nil; startupContextWindowTokens = nil
            if error is CancellationError { throw LlamaRuntimeError.cancelled }
            let failure = (error as? LlamaRuntimeError) ?? .unavailable(error.localizedDescription)
            diagnostics.lastError = failure.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(failure.localizedDescription)
            throw failure
        }
        guard startupID == id else { throw LlamaRuntimeError.cancelled }
        cachedRuntime = prepared
        apply(prepared)
        self.startupTask = nil; startupModelFilename = nil; startupContextWindowTokens = nil
        return prepared
    }

    /// Copies prepared runtime metadata into published diagnostics for the menu and startup UI.
    private func apply(_ preparedRuntime: PreparedLlamaRuntime) {
        let model = preparedRuntime.resolvedRuntime.modelDisplayName
        let ctx = preparedRuntime.contextWindowTokens
        LingroveLogger.runtime.info(
            "Runtime ready: model=\(model) ctx=\(ctx) threads=\(preparedRuntime.threadCount) gpu=\(preparedRuntime.gpuLayerCount)"
        )
        diagnostics.runtimeDirectoryPath = preparedRuntime.resolvedRuntime.runtimeDirectoryURL.path
        diagnostics.modelFilePath = preparedRuntime.resolvedRuntime.modelFileURL.path
        diagnostics.backendName = preparedRuntime.backendName
        diagnostics.contextWindowTokens = preparedRuntime.contextWindowTokens
        diagnostics.batchSize = preparedRuntime.batchSize
        diagnostics.threadCount = preparedRuntime.threadCount
        diagnostics.gpuLayerCount = preparedRuntime.gpuLayerCount
        diagnostics.lastLoadStatus = "Loaded"
        diagnostics.lastError = nil

        state = .ready(String(localized: "Loaded \(preparedRuntime.resolvedRuntime.modelDisplayName) in-process.",
            table: "Learning"))
    }
}

extension LlamaRuntimeManager: LlamaRuntimeGenerating {}
