import AppKit
import Combine
import Foundation
import LingroveNotebookEngine

/// A destination-lifetime presentation model. The app repository remains the sole long-lived
/// notebook owner; this object owns only a read task, active subscriptions and immutable output.
/// Cancelling revokes publication identity even if the underlying SQLite read finishes later.
@MainActor
final class NotebookProgressModel: ObservableObject {
    enum State {
        case inactive
        case loading
        case loaded(NotebookProgressContent)
        case failed
    }

    @Published private(set) var state: State = .inactive
    private let repository: MacNotebookRepository
    private let reader: any NotebookProgressReading
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var subscriptions = Set<AnyCancellable>()
    private var readTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var lifetime = UUID()
    private var readIdentity = UUID()
    private var lastFence: NotebookProgressReadFence?
    private var isActive = false

    init(repository: MacNotebookRepository, reader: (any NotebookProgressReading)? = nil,
         now: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .current }) {
        self.repository = repository
        self.reader = reader ?? NotebookProgressIO(databaseURL: repository.databaseURL,
            mediaDirectoryURL: repository.mediaDirectoryURL)
        self.now = now
        self.calendar = calendar
    }

    deinit {
        readTask?.cancel()
        monitorTask?.cancel()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        lifetime = UUID()
        if active {
            repository.$changeSequence.dropFirst().sink { [weak self] _ in self?.reload() }
                .store(in: &subscriptions)
            for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                         NSApplication.didBecomeActiveNotification] {
                NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                    // AppKit posts these on its UI thread. Explicitly hop because Combine's
                    // callback type does not itself encode an actor promise.
                    Task { @MainActor [weak self] in self?.reload() }
                }.store(in: &subscriptions)
            }
            reload()
            monitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    self?.checkForStorageChanges()
                }
            }
        } else {
            subscriptions.removeAll()
            readTask?.cancel()
            readTask = nil
            monitorTask?.cancel()
            monitorTask = nil
            lastFence = nil
            state = .inactive
        }
    }

    func reload() {
        guard isActive else { return }
        readTask?.cancel()
        readIdentity = UUID()
        let operation = readIdentity
        let savedLifetime = lifetime
        let fence: NotebookProgressReadFence
        do { fence = try repository.engine.notebookProgressReadFence() } catch {
            readTask = nil
            lastFence = nil
            state = .failed
            return
        }
        lastFence = fence
        state = .loading
        // Freeze all civil-date inputs together, before the first suspension. The full SQL
        // snapshot must match this owner and the repository fence must still match at publish.
        let referenceNow = now()
        let referenceCalendar = calendar()
        readTask = Task { [weak self, reader] in
            do {
                let content = try await reader.load(scope: fence.scope, now: referenceNow, calendar: referenceCalendar)
                guard let self, self.isActive, self.lifetime == savedLifetime,
                      self.readIdentity == operation, !Task.isCancelled else { return }
                guard content.snapshot.scope == fence.scope,
                      try self.repository.engine.notebookProgressReadFence() == fence else {
                    self.reload()
                    return
                }
                self.state = .loaded(content)
            } catch {
                guard let self, self.isActive, self.lifetime == savedLifetime,
                      self.readIdentity == operation, !Task.isCancelled else { return }
                if let current = try? self.repository.engine.notebookProgressReadFence(), current != fence {
                    self.reload()
                } else {
                    self.state = .failed
                }
            }
        }
    }

    /// Repository notifications cover app writes and sync. A small metadata probe also detects
    /// another process's commit, even when that process cannot publish into this Combine graph.
    /// It never decodes the corpus or aggregates events on MainActor.
    func checkForStorageChanges() {
        guard isActive, let lastFence else { return }
        do {
            let current = try repository.engine.notebookProgressReadFence()
            if current != lastFence {
                reload()
            } else if case let .loaded(content) = state {
                let currentCalendar = calendar()
                if currentCalendar.timeZone != content.snapshot.calendar.timeZone
                    || !currentCalendar.isDate(now(), inSameDayAs: content.snapshot.now) {
                    reload()
                }
            }
        } catch {
            readIdentity = UUID()
            readTask?.cancel()
            state = .failed
        }
    }

    /// Integration tests await the real read (including a superseding retry), not a spinner.
    func waitForIdle() async {
        var identity: UUID
        repeat {
            identity = readIdentity
            await readTask?.value
        } while isActive && identity != readIdentity
    }
}
