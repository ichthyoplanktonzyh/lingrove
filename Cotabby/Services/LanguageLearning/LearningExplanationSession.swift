import Combine
import Foundation

/// A card/window owns one lightweight session. The app-owned service executes and caches work;
/// this object owns only the selected immutable target and its latest-wins presentation state.
/// Changing targets, preferences or hiding a card cancels work before a late reply can publish.
@MainActor
final class LearningExplanationSession: ObservableObject {
    @Published private(set) var input: LearningExplanationInput?
    @Published private(set) var record: LearningExplanationRecord?
    @Published private(set) var isGenerating = false
    @Published private(set) var error: String?
    let service: (any LearningExplanationGenerating)?
    private var work: Task<Void, Never>?
    private var lookupWork: Task<Void, Never>?
    private var revision = UUID()
    private var subscription: AnyCancellable?

    init(service: (any LearningExplanationGenerating)? = nil) {
        self.service = service
        subscription = service?.changes.sink { [weak self] in
            guard let self else { return }
            self.cancel(); self.record = nil; self.error = nil
            self.restoreSaved()
        }
    }
    var isConfigured: Bool { service?.isConfigured == true }

    func setTarget(_ input: LearningExplanationInput?, saved: LearningExplanationRecord? = nil) {
        let input = input.flatMap { LearningExplanationPolicy.isValid($0) ? $0 : nil }
        let saved = saved ?? input.flatMap { service?.savedRecord(for: $0) }
        guard self.input != input else {
            if record == nil, !isGenerating, saved?.input == input { record = saved }
            if record == nil, !isGenerating, lookupWork == nil { restoreSaved() }
            return
        }
        cancel()
        self.input = input
        record = saved?.input == input ? saved : nil
        error = nil
        if record == nil { restoreSaved() }
    }

    private func restoreSaved() {
        guard let input, let service else { return }
        let revision = revision
        lookupWork = Task { [weak self] in
            // Preferences publish before assignment. Read the committed language on the next turn.
            await Task.yield()
            let saved = await service.loadSaved(for: input)
            guard !Task.isCancelled, let self, self.revision == revision, self.input == input else { return }
            self.lookupWork = nil
            if self.record == nil, !self.isGenerating, saved?.language == service.language { self.record = saved }
        }
    }
    func explain(refresh: Bool = false) {
        guard let service, let input, !isGenerating, refresh || record == nil else { return }
        cancel()
        error = nil
        let revision = self.revision, requestID = RequestID.generate()
        isGenerating = true
        work = Task { [weak self] in
            do {
                let record = try await service.generate(input, requestID: requestID, refresh: refresh)
                try Task.checkCancellation()
                guard let self, self.revision == revision, self.input == input else { return }
                self.record = record
                self.isGenerating = false
                self.work = nil
                service.recordDisplay(requestID: requestID)
            } catch {
                guard let self, self.revision == revision else { return }
                self.isGenerating = false; self.work = nil
                if !(error is CancellationError), !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() {
        revision = UUID()
        lookupWork?.cancel(); lookupWork = nil
        work?.cancel(); work = nil
        isGenerating = false
    }
    func clear() { cancel(); input = nil; record = nil; error = nil }
}
