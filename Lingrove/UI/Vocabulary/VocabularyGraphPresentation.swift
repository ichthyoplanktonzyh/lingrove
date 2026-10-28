import Combine
import Foundation

/// Window-owned browsing state, not another vocabulary store. Layout frames go directly to
/// the AppKit canvas; only expansion, selection, settings and explicit commands publish changes.
@MainActor
final class VocabularyGraphPresentation: ObservableObject {
    enum Command { case zoomIn, zoomOut, fit, locate }
    @Published private(set) var expanded: Set<UUID> = []
    @Published private(set) var focusedEntryID: UUID?
    @Published private(set) var commandSerial = 0
    private(set) var command: Command = .fit
    @Published var settings: VocabularyGraphSettings {
        didSet {
            let normalized = settings.normalized
            if normalized != settings { settings = normalized }
            if let data = try? JSONEncoder().encode(normalized) { defaults.set(data, forKey: Self.settingsKey) }
        }
    }
    let worker = VocabularyGraphLayoutWorker()
    var camera = VocabularyGraphCamera()
    var hasCamera = false
    var fitsInitialLayout = true
    private var epoch: UInt64 = 0
    private let defaults: UserDefaults
    static let settingsKey = "vocabularyGraphSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(VocabularyGraphSettings.self, from: $0) }?.normalized ?? .init()
    }
    func toggle(_ entryID: UUID) {
        if expanded.remove(entryID) == nil {
            expanded.insert(entryID); focusedEntryID = entryID
        } else if focusedEntryID == entryID { focusedEntryID = nil }
    }
    func reveal(_ selection: VocabularySelection?) {
        guard let selection else { return }
        if !expanded.contains(selection.entryID) { expanded.insert(selection.entryID) }
        if focusedEntryID != selection.entryID { focusedEntryID = selection.entryID }
    }
    func clearFocus() { focusedEntryID = nil }
    func revealMeaning(_ id: UUID) {
        expanded.insert(id)
        focusedEntryID = id
    }
    func collapse() { expanded = []; focusedEntryID = nil }
    func send(_ command: Command) { self.command = command; commandSerial &+= 1 }
    func nextEpoch() -> UInt64 { epoch &+= 1; return epoch }
}
