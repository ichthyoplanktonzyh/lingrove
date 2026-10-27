import Combine
import Foundation
import Logging

/// App-owned model execution for one learning role. It reuses discovery and HTTP transport, while
/// its native engine, credentials, in-flight task and status belong only to this role. Views observe
/// this controller rather than constructing runtimes during SwiftUI body evaluation.
@MainActor
final class LearningModelController: ObservableObject {
    let profile: LearningModelSettings
    @Published private(set) var status = String(localized: "Not loaded", table: "Learning",
        comment: "Initial status shown in settings when this learning model is not resident.")
    @Published private(set) var availableModels: [RuntimeModelOption] = []
    /// Storage discovery stays separate from task admission so files are never reclassified by
    /// whichever settings page happened to refresh last.
    private var installedModels: [RuntimeModelOption] = []
    let endpointConnection: OpenAICompatibleConnectionModel
    var endpointModels: [OpenAICompatibleModelOption] { endpointConnection.models }
    private let core: any LearningLocalExecuting
    private let localModelURL: (String) throws -> URL
    private let modelOptionsProvider: () -> [RuntimeModelOption]
    private let templateResolver: @Sendable (URL) throws -> LearningChatTemplate
    private let client: OpenAICompatibleAPIClient
    private var task: Task<String, Error>?
    private var taskID = UUID()
    private var instructionRequestID = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var missingSelectedFile = false
    private var preparedSnapshot: LearningModelSnapshot?
    private var observedSnapshot: LearningModelSnapshot
    private var nativeMayBeResident = false
    private var lastNativeTrace: LearningRequestContext?
    private var warmupWork: Task<Void, Never>?
    private var templateWork: Task<Void, Never>?
    private var warmupID = UUID()
    /// Live policy reads close the gap between a @Published edit and the coalesced UI update.
    var generationEligibility: () -> Bool = { true }
    var warmupEligibility: () -> Bool = { true }
    private var idleRelease: Task<Void, Never>?
    private var generationAllowed = true
    private(set) var residency: LocalRuntimeResidency = .onDemand
    /// Explanation answers are cached by the service; its native weights can be released between
    /// sessions. Tests inject a short deadline without touching the user's settings or model files.
    var idleReleaseDelay: Duration = .seconds(60)

    init(profile: LearningModelSettings, client: OpenAICompatibleAPIClient,
         core: any LearningLocalExecuting = LearningLocalRuntime(),
         localModelURL: @escaping (String) throws -> URL = {
             try BundledRuntimeLocator().resolve(configuration: .default, selectedModelFilename: $0).modelFileURL
         },
         modelOptionsProvider: (() -> [RuntimeModelOption])? = nil,
         templateResolver: (@Sendable (URL) throws -> LearningChatTemplate)? = nil) {
        self.core = core; self.localModelURL = localModelURL
        self.profile = profile
        self.modelOptionsProvider = modelOptionsProvider ?? { BundledRuntimeLocator().availableModels(configuration: .default) }
        self.templateResolver = templateResolver ?? { try LearningLocalPrompt.resolve(.automatic, modelURL: $0) }
        observedSnapshot = profile.snapshot
        self.client = client
        endpointConnection = OpenAICompatibleConnectionModel(client: client)
        refreshModels()
        profile.changes.sink { [weak self] in self?.profileChanged() }.store(in: &subscriptions)
        endpointConnection.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        Publishers.Merge(profile.$baseURL.dropFirst().map { _ in () },
            profile.$credentialRevision.dropFirst().map { _ in () })
            .sink { [weak self] in self?.endpointConnection.invalidate() }.store(in: &subscriptions)
    }

    func refreshModels() {
        registerConfiguredModels()
        resolveModelTemplate()
        installedModels = modelOptionsProvider()
        updateCandidates()
        let selection = profile.snapshot
        if selection.backend == .local, !selection.localModel.isEmpty,
           let issue = taskIssue(for: selection.localModel, template: selection.template) {
            stop()
            status = issue
            return
        }
        if selection.backend == .local, !selection.localModel.isEmpty,
           !installedModels.contains(where: { $0.filename == selection.localModel }) {
            stop()
            status = String(localized: "The configured GGUF file is unavailable. Choose a model again.",
                table: "Learning", comment: "Status shown when a selected local model file can no longer be found.")
            missingSelectedFile = true
        } else if missingSelectedFile {
            missingSelectedFile = false
            status = String(localized: "Not loaded", table: "Learning",
                comment: "Status shown in settings when this learning model is not resident.")
        }
    }

    private func registerConfiguredModels() {
        // Existing manual/battery/AC references are explicit task choices. Preserve unknown
        // imports in that task; a known incompatible catalog entry cannot acquire a new role.
        for filename in profile.referencedLocalModels {
            profile.modelTaskAssignments.record(filename, for: LocalModelTask(profile.role))
        }
    }

    private func updateCandidates() {
        let task = LocalModelTask(profile.role)
        availableModels = installedModels.filter {
            LocalModelTaskPolicy.isCandidate($0.filename, task: task,
                assignedTasks: profile.modelTaskAssignments.tasks(for: $0.filename))
        }
    }

    func taskIssue(for filename: String, template: LearningChatTemplate = .automatic) -> String? {
        let task = LocalModelTask(profile.role)
        guard !filename.isEmpty else { return nil }
        guard LocalModelTaskPolicy.supports(filename, task: task),
              LocalModelTaskPolicy.permitsTemplate(template, task: task) else {
            return String(localized: "This model is not compatible with this task. Choose another model.", table: "Learning")
        }
        return nil
    }

    private func validateTaskSelection(_ snapshot: LearningModelSnapshot) async throws {
        guard snapshot.backend == .local else { return }
        if let issue = taskIssue(for: snapshot.localModel, template: snapshot.template) {
            throw LearningFailure.message(issue)
        }
        if profile.role == .explanation {
            if templateWork == nil { resolveModelTemplate() }
            await templateWork?.value
            try Task.checkCancellation()
            guard profile.snapshot == snapshot else { throw CancellationError() }
            guard profile.generalInstructionsAvailable == true else {
                throw LearningFailure.message(String(localized: "Choose a general instruction model for AI explanation.",
                    table: "Learning"))
            }
        }
    }

    func discoverEndpoint() async {
        do {
            // Discovery remains available when this task runs locally. Use the durable endpoint
            // fields rather than the canonical generation snapshot, which omits dormant values.
            let configuration = try OpenAICompatibleEndpointConfiguration(baseURLString: profile.baseURL,
                modelName: profile.endpointModel, apiMode: .chatCompletions)
            await endpointConnection.refresh(configuration: configuration, apiKey: try profile.apiKey())
        } catch {
            endpointConnection.setFailure(error.localizedDescription)
        }
    }

    /// Connect has the same explicit draft-submit behavior as completion. A failed Keychain
    /// write never falls through to a request authenticated by an older saved credential.
    func connect(using draft: String?) async {
        guard profile.saveAPIKey(draft) else { endpointConnection.setFailure(profile.credentialMessage); return }
        await discoverEndpoint()
    }
    func resetEndpointBaseURL() { profile.baseURL = OpenAICompatibleEndpointConfiguration.defaultBaseURLString }

    /// Automatic GGUF metadata is resolved off MainActor before explanation can use it. Filename
    /// filtering alone cannot stop a renamed translation specialist from receiving tutor prompts.
    func validateGeneralInstructionModel() async throws {
        let initial = profile.snapshot
        try await validateTaskSelection(initial)
        if initial.backend == .local {
            if templateWork == nil { resolveModelTemplate() }
            await templateWork?.value
        }
        try Task.checkCancellation()
        guard profile.snapshot == initial else { throw CancellationError() }
        guard profile.generalInstructionsAvailable == true else {
            throw LearningFailure.message(String(localized: "Choose a general instruction model for AI explanation.", table: "Learning"))
        }
    }

    /// Resolve style capabilities before freezing a translation plan. The shared metadata task
    /// yields MainActor, so the original destination and live eligibility must still agree afterward.
    private func resolveTranslationMetadata() async throws {
        let initial = profile.snapshot, identity = profile.contextIdentity
        if initial.backend == .local, initial.template == .automatic {
            // Background metadata is a UI convenience, not a request correctness guarantee.
            // Await the shared read before freezing a saved style on the very first request.
            // Awaiting yields MainActor; a changed destination must still cancel this caller.
            if templateWork == nil { resolveModelTemplate() }
            await templateWork?.value
            try Task.checkCancellation()
            guard profile.contextIdentity == identity, initial == profile.snapshot,
                  generationAllowed, generationEligibility() else { throw CancellationError() }
        }
    }

    /// Freeze a complete translation request before transport. Native planning borrows this role's
    /// serialized vocabulary off MainActor; endpoints use the disclosed estimate. A profile edit
    /// invalidates the lease, preventing preparation from handing text to a newly selected server.
    func translationPlan(
        input: LearningTranslationInput, sourceLanguage: LearningLanguage?,
        targetLanguage: LearningLanguage, output: Int
    ) async throws -> LearningTranslationPrompt.Request {
        guard generationAllowed, generationEligibility() else { throw CancellationError() }
        try await resolveTranslationMetadata()
        let snapshot = profile.snapshot
        try await validateTaskSelection(snapshot)
        try Task.checkCancellation()
        guard profile.snapshot == snapshot, generationAllowed, generationEligibility() else { throw CancellationError() }
        var input = input
        // The snapshot retains saved intent for stale-result checks. Capability resolution is
        // transient: an unsupported dormant preference must not mutate that identity mid-request.
        input.style = profile.translationStyleAvailable == false ? .init() : snapshot.translationStyle
        let frozenInput = input
        if snapshot.backend == .endpoint {
            let work = Task.detached(priority: .userInitiated) {
                try LearningTranslationBudget.prompt(
                    input: frozenInput, sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage, family: .init(endpointModel: snapshot.endpointModel),
                    total: snapshot.contextWindowTokens, output: output, estimated: true
                ) { text in
                    try Task.checkCancellation()
                    return ModelContextBudget.estimatedTokens(text)
                }
            }
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            try Task.checkCancellation()
            guard profile.snapshot == snapshot, generationAllowed, generationEligibility() else { throw CancellationError() }
            return result
        }
        guard !snapshot.localModel.isEmpty else {
            throw LearningFailure.message(String(localized: "Choose a local GGUF model for this task.", table: "Learning"))
        }
        idleRelease?.cancel(); idleRelease = nil
        task?.cancel(); task = nil
        let id = UUID(), core = core, url = try localModelURL(snapshot.localModel)
        taskID = id
        core.claim(id)
        nativeMayBeResident = true
        let trace = LearningRequestTrace.measurement?.context
        lastNativeTrace = trace
        let work = Task.detached(priority: .userInitiated) {
            try core.translationPlan(
                configuration: .init(modelURL: url, template: snapshot.template,
                    contextWindowTokens: snapshot.contextWindowTokens, samplingOverrides: snapshot.samplingOverrides),
                input: frozenInput, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                output: output, operationID: id, trace: trace)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel(); core.cancel(id)
            }
            try Task.checkCancellation()
            guard taskID == id, profile.snapshot == snapshot, generationAllowed, generationEligibility() else { throw CancellationError() }
            return result
        } catch {
            // Planning can load a vocabulary and then reject an oversized target. That failure
            // must still retire an on-demand native allocation, just like decode failures do.
            if taskID == id { scheduleIdleRelease() }
            throw error
        }
    }

    /// Reserve before async metadata/prompt preparation. A slower, older explanation must not
    /// arrive at generate later and supersede the expression request the user started after it.
    func reserveInstructionRequest() -> UUID {
        instructionRequestID = UUID()
        task?.cancel()
        return instructionRequestID
    }

    func validateInstructionRequest(_ identifier: UUID) throws {
        try Task.checkCancellation()
        guard instructionRequestID == identifier else { throw CancellationError() }
    }

    func generate(prompt: String, maxTokens: Int, userOnly: Bool = false,
                  sampling: LearningInstructionSampling? = nil,
                  localGrammar: String? = nil,
                  onDelta: (@MainActor (String) throws -> Void)? = nil) async throws -> String {
        guard generationAllowed, generationEligibility() else { throw CancellationError() }
        try Task.checkCancellation()
        idleRelease?.cancel(); idleRelease = nil
        let measurement = LearningRequestTrace.measurement
        measurement?.beginGeneration(prompt: prompt)
        // Explanation and expression assistance share this controller and one loaded engine.
        // Publish the new identity before awaiting the old task: a third request may arrive while
        // we suspend. Only the newest identity may then claim the native sequence or endpoint.
        let previous = task
        previous?.cancel()
        let id = UUID(), snapshot = profile.snapshot
        let request = InstructionRequest(id: id, snapshot: snapshot, prompt: prompt, maxTokens: maxTokens,
            userOnly: userOnly, sampling: sampling, localGrammar: localGrammar)
        taskID = id
        status = snapshot.backend == .local
            ? String(localized: "Loading / generating", table: "Learning",
                comment: "Model status while a local learning model loads or generates a result.")
            : String(localized: "Requesting", table: "Learning",
                comment: "Model status while a learning request is being sent to its configured endpoint.")
        let work = Task { [self] in
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            guard taskID == id, profile.snapshot == snapshot, generationAllowed, generationEligibility() else {
                throw CancellationError()
            }
            return try await generateResponse(request, onDelta: onDelta)
        }
        task = work
        do {
            let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard taskID == id, profile.snapshot == snapshot else { throw CancellationError() }
            status = String(localized: "Ready", table: "Learning",
                comment: "Model status after the learning request completes successfully.")
            task = nil
            scheduleIdleRelease()
            return result
        } catch {
            let cancelled = work.isCancelled || Task.isCancelled || taskID != id || profile.snapshot != snapshot || error is CancellationError
            if taskID == id {
                task = nil
                status = cancelled
                    ? String(localized: "Canceled", table: "Learning",
                        comment: "Model status after a learning request is canceled.")
                    : error.localizedDescription
                scheduleIdleRelease()
            }
            if cancelled { throw CancellationError() }
            throw error
        }
    }

    /// A frozen work item carries the shared executor's identity across its drain suspension.
    /// It has request lifetime; the controller owns it only through the current generation task.
    private struct InstructionRequest {
        let id: UUID
        let snapshot: LearningModelSnapshot
        let prompt: String
        let maxTokens: Int
        let userOnly: Bool
        let sampling: LearningInstructionSampling?
        // Compatible endpoints retain their existing prompt/parser contract; their schema
        // capabilities are not negotiated. Only the in-process executor consumes this grammar.
        let localGrammar: String?
    }

    private func generateResponse(_ request: InstructionRequest,
                                  onDelta: (@MainActor (String) throws -> Void)?) async throws -> String {
        let snapshot = request.snapshot, prompt = request.prompt, maxTokens = request.maxTokens
        try await validateTaskSelection(snapshot)
        try Task.checkCancellation()
        guard taskID == request.id, profile.snapshot == snapshot, generationAllowed, generationEligibility() else {
            throw CancellationError()
        }
        let userOnly = request.userOnly, id = request.id
        let sampling = (request.sampling ?? (userOnly ? .hyMT : .standard)).values.applying(snapshot.samplingOverrides)
        let measurement = LearningRequestTrace.measurement
        switch snapshot.backend {
        case .endpoint:
            let configuration = try endpoint(snapshot)
            if let onDelta {
                var raw = ""
                try await client.streamInstruction(configuration: configuration, apiKey: profile.apiKey(),
                    prompt: prompt, options: .init(maxPredictionTokens: maxTokens, temperature: sampling.temperature,
                        topP: sampling.topP), userOnly: userOnly) { delta in
                    guard self.profile.snapshot == snapshot else { throw CancellationError() }
                    measurement?.received(delta)
                    try onDelta(delta)
                    // Role-specific byte/eligibility checks run before this retained buffer grows.
                    // Invalid output must not be accumulated first and rejected afterwards.
                    raw += delta
                }
                return raw
            }
            let raw = try await client.generateInstruction(configuration: configuration, apiKey: profile.apiKey(),
                prompt: prompt, options: .init(maxPredictionTokens: maxTokens, temperature: sampling.temperature,
                    topP: sampling.topP), userOnly: userOnly,
                onRawText: { measurement?.received($0) })
            return raw
        case .local:
            guard !snapshot.localModel.isEmpty else {
                throw LearningFailure.message(String(localized: "Choose a local GGUF model for this task.",
                    table: "Learning", comment: "Error shown when local generation starts without a selected model."))
            }
            let modelURL = try localModelURL(snapshot.localModel)
            return try await runLocal(model: modelURL, snapshot: snapshot, prompt: prompt,
                                      maxTokens: maxTokens, id: id, grammar: request.localGrammar, onDelta: onDelta)
        }
    }

    private func runLocal(model: URL, snapshot: LearningModelSnapshot, prompt: String, maxTokens: Int,
                          id: UUID, grammar: String? = nil,
                          onDelta: (@MainActor (String) throws -> Void)?) async throws -> String {
        let core = self.core
        try Task.checkCancellation()
        core.claim(id)
        let measurement = LearningRequestTrace.measurement
        let trace = measurement?.context
        nativeMayBeResident = true
        lastNativeTrace = trace
        let pair = AsyncThrowingStream<NativeEvent, Error>.makeStream()
        let nativeTask = Task.detached(priority: profile.role == .translation ? .userInitiated : .utility) {
            do {
                let text = try core.generate(configuration: .init(modelURL: model, template: snapshot.template,
                    contextWindowTokens: snapshot.contextWindowTokens, samplingOverrides: snapshot.samplingOverrides,
                    outputGrammar: grammar), prompt: prompt,
                    maxTokens: maxTokens, operationID: id, trace: trace,
                    onLoad: { pair.continuation.yield(.loaded($0)) }) { pair.continuation.yield(.text($0)) }
                pair.continuation.finish()
                return text
            } catch {
                pair.continuation.finish(throwing: error)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            do {
                for try await event in pair.stream {
                    try Task.checkCancellation()
                    guard profile.snapshot == snapshot else { throw CancellationError() }
                    switch event {
                    case .loaded(let milliseconds):
                        preparedSnapshot = snapshot
                        measurement?.loaded(milliseconds: milliseconds)
                    case .text(let delta): measurement?.received(delta); try onDelta?(delta)
                    }
                }
                return try await nativeTask.value
            } catch {
                nativeTask.cancel()
                core.cancel(id)
                // Cancellation is cooperative. The successor must not begin until the old native
                // worker has left its sequence, even when the stream stopped delivering first.
                _ = await nativeTask.result
                throw error
            }
        } onCancel: { nativeTask.cancel(); core.cancel(id) }
    }

    private enum NativeEvent: Sendable { case loaded(Int), text(String) }

    private func endpoint(_ snapshot: LearningModelSnapshot) throws -> OpenAICompatibleEndpointConfiguration {
        try .init(baseURLString: snapshot.baseURL, modelName: snapshot.endpointModel, apiMode: .chatCompletions)
    }

    private func resolveModelTemplate() {
        templateWork?.cancel()
        let snapshot = profile.snapshot, identity = profile.contextIdentity
        guard snapshot.backend == .local, snapshot.template == .automatic || profile.role == .explanation,
              taskIssue(for: snapshot.localModel, template: snapshot.template) == nil,
              !snapshot.localModel.isEmpty, let url = try? localModelURL(snapshot.localModel) else { return }
        let resolver = templateResolver
        templateWork = Task { [weak self] in
            let work = Task.detached(priority: .utility) { try resolver(url) }
            let resolved = await withTaskCancellationHandler { try? await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let resolved, let self else { return }
            self.profile.setResolvedTemplate(resolved, expectedIdentity: identity)
        }
    }

    private func profileChanged() {
        registerConfiguredModels()
        updateCandidates()
        let next = profile.snapshot
        let previous = observedSnapshot
        observedSnapshot = next
        guard previous.usesSameRuntime(as: next) else { stop(); resolveModelTemplate(); return }
        // A committed request preference invalidates previews and active decode, but not weights.
        // invalidate changes the native lease so even planning work that has not returned cannot
        // publish an old prompt. The following operation reuses the same native allocation.
        warmupID = UUID(); warmupWork?.cancel(); warmupWork = nil
        taskID = UUID(); task?.cancel(); task = nil
        // stop() may already have queued a release for the previous destination. With no
        // active native ownership, changing its lease here would invalidate that release and
        // leave old weights resident without bookkeeping. HTTP cancellation needs no core lease.
        if nativeMayBeResident { _ = core.invalidate() }
        if preparedSnapshot?.usesSameRuntime(as: next) == true { preparedSnapshot = next }
        status = preparedSnapshot == nil
            ? String(localized: "Not loaded", table: "Learning") : String(localized: "Ready", table: "Learning")
        scheduleIdleRelease()
    }

    func stop() {
        warmupID = UUID(); warmupWork?.cancel(); warmupWork = nil
        idleRelease?.cancel(); idleRelease = nil
        let trace = lastNativeTrace
        if nativeMayBeResident, let trace { LearningRequestLog.emit(trace, phase: "runtime_release_requested") }
        nativeMayBeResident = false; lastNativeTrace = nil; preparedSnapshot = nil
        taskID = UUID()
        task?.cancel(); task = nil
        let lease = core.invalidate()
        Task.detached { [core] in core.unload(expectedLease: lease, trace: trace) }
        status = String(localized: "Not loaded", table: "Learning",
            comment: "Model status after the local learning model is unloaded.")
    }

    func prepare() async {
        let snapshot = profile.snapshot
        if let issue = taskIssue(for: snapshot.localModel, template: snapshot.template), snapshot.backend == .local {
            status = issue
            return
        }
        guard !Task.isCancelled, generationAllowed, generationEligibility(), warmupEligibility(), residency == .warm, snapshot.backend == .local,
              !snapshot.localModel.isEmpty, preparedSnapshot?.usesSameRuntime(as: snapshot) != true, task == nil else { return }
        do { try await validateTaskSelection(snapshot) } catch {
            if profile.snapshot == snapshot { status = error.localizedDescription }
            return
        }
        guard !Task.isCancelled, profile.snapshot == snapshot, generationAllowed, generationEligibility(),
              warmupEligibility(), residency == .warm, task == nil else { return }
        idleRelease?.cancel(); idleRelease = nil
        let id = UUID(); taskID = id
        let core = self.core
        core.claim(id)
        status = String(localized: "Loading", table: "Learning",
            comment: "Model status while preparing the local learning model.")
        let trace = LearningRequestContext(requestID: RequestID.generate(), operationID: RequestID.generate(),
            source: profile.role == .translation ? .translation : .explanation,
            modelName: snapshot.localModel, engine: "llama")
        lastNativeTrace = trace
        LearningRequestLog.emit(trace, phase: "warmup_started")
        do {
            let modelURL = try localModelURL(snapshot.localModel)
            nativeMayBeResident = true
            let work = Task.detached {
                try core.prepare(modelURL: modelURL, contextWindowTokens: snapshot.contextWindowTokens, operationID: id, trace: trace)
                return ""
            }
            task = work
            _ = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel(); core.cancel(id) }
            guard taskID == id, profile.snapshot == snapshot else { return }
            task = nil; preparedSnapshot = snapshot
            status = String(localized: "Ready", table: "Learning",
                comment: "Model status after the local learning model is prepared.")
            LearningRequestLog.emit(trace, phase: "warmup_finished")
        } catch {
            guard taskID == id else { return }
            task = nil
            status = error is CancellationError
                ? String(localized: "Canceled", table: "Learning",
                    comment: "Model status after local model preparation is canceled.")
                : error.localizedDescription
            LearningRequestLog.emit(trace, phase: error is CancellationError ? "warmup_cancelled" : "warmup_failed",
                details: ["error_type": String(reflecting: type(of: error))])
        }
    }

    /// The collection is the policy owner; the controller applies decisions without sharing a
    /// native context with another role. Repeated identical decisions do not reload the model.
    func applyResidency(_ decision: LocalRuntimeResidency, generationAllowed: Bool) {
        self.generationAllowed = generationAllowed
        let changed = residency != decision
        residency = decision
        if decision == .released {
            if !generationAllowed {
                if changed || task != nil || nativeMayBeResident || warmupWork != nil { stop() }
            } else if nativeMayBeResident {
                // Endpoint eligibility and native residency are separate. Releasing leftover
                // local memory must not cancel an eligible HTTP request during another role's edit.
                preparedSnapshot = nil; nativeMayBeResident = false
                let trace = lastNativeTrace; lastNativeTrace = nil
                let lease = core.invalidate()
                Task.detached { [core] in core.unload(expectedLease: lease, trace: trace) }
            }
        } else if decision == .warm {
            idleRelease?.cancel(); idleRelease = nil
            guard warmupWork == nil else { return }
            let id = UUID(); warmupID = id
            warmupWork = Task { [weak self] in
                guard let self, self.warmupID == id, !Task.isCancelled else { return }
                await self.prepare()
                if self.warmupID == id { self.warmupWork = nil }
            }
        } else {
            warmupID = UUID(); warmupWork?.cancel(); warmupWork = nil
            if task == nil { scheduleIdleRelease() }
        }
    }

    private func scheduleIdleRelease() {
        idleRelease?.cancel(); idleRelease = nil
        guard residency == .onDemand, nativeMayBeResident, task == nil else { return }
        idleRelease = Task { [weak self, idleReleaseDelay] in
            do { try await Task.sleep(for: idleReleaseDelay) } catch { return }
            guard let self, self.residency == .onDemand, self.task == nil else { return }
            self.stop()
        }
    }

    func shutdownSync() {
        templateWork?.cancel(); templateWork = nil
        warmupID = UUID(); warmupWork?.cancel(); warmupWork = nil
        idleRelease?.cancel(); idleRelease = nil
        task?.cancel(); task = nil
        core.shutdownSync()
    }
}
