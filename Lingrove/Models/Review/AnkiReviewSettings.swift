import Combine
import Foundation
import Security

/// The environment owns one settings object shared by both windows. Only explicit connection
/// or send actions read its credential; no startup probe or background synchronization occurs.
@MainActor
final class AnkiReviewSettings: ObservableObject {
    @Published var address: String { didSet { defaults.set(address, forKey: "ankiReviewAddress") } }
    @Published var deck: String { didSet { defaults.set(deck, forKey: "ankiReviewDeck") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "ankiReviewModel") } }
    @Published var mapping: [ReviewField: String] { didSet { persistMapping() } }
    @Published var defaultRecognition: Bool { didSet { defaults.set(defaultRecognition, forKey: "ankiReviewRecognition") } }
    @Published var defaultGap: Bool { didSet { defaults.set(defaultGap, forKey: "ankiReviewGap") } }
    private let defaults: UserDefaults
    private let credentials: AnkiCredentialStore

    init(defaults: UserDefaults = .standard, credentials: AnkiCredentialStore? = nil) {
        self.defaults = defaults
        self.credentials = credentials ?? AnkiCredentialStore()
        address = defaults.string(forKey: "ankiReviewAddress") ?? "http://127.0.0.1:8765"
        deck = defaults.string(forKey: "ankiReviewDeck") ?? "Default"
        model = defaults.string(forKey: "ankiReviewModel") ?? AnkiReviewPolicy.presetName
        mapping = defaults.data(forKey: "ankiReviewMapping").flatMap {
            try? JSONDecoder().decode([ReviewField: String].self, from: $0)
        } ?? AnkiReviewPolicy.presetMapping
        defaultRecognition = defaults.object(forKey: "ankiReviewRecognition") as? Bool ?? true
        defaultGap = defaults.bool(forKey: "ankiReviewGap")
    }

    var effectiveMapping: [ReviewField: String] { model == AnkiReviewPolicy.presetName ? AnkiReviewPolicy.presetMapping : mapping }
    var hasSavedDeck: Bool { defaults.string(forKey: "ankiReviewDeck") != nil }

    func connection() throws -> AnkiConnection {
        guard let endpoint = AnkiReviewPolicy.endpoint(address) else {
            throw AnkiReviewError.message(String(localized: "Use a local AnkiConnect HTTP address.", table: "Vocabulary"))
        }
        return .init(endpoint: endpoint, apiKey: try credentials.read())
    }
    func readKey() throws -> String { try credentials.read() }
    func saveKey(_ value: String) throws { try credentials.save(value) }
    private func persistMapping() {
        if let data = try? JSONEncoder().encode(mapping) { defaults.set(data, forKey: "ankiReviewMapping") }
    }
}

/// A small Keychain boundary keeps Anki credentials separate from inference endpoint tokens.
/// A nil service is an isolated memory store for tests and never contacts the user's Keychain.
@MainActor
final class AnkiCredentialStore {
    private let service: String?
    private var memory = ""
    init(service: String? = (Bundle.main.bundleIdentifier ?? "io.ichthyoplanktonzyh.lingrove") + ".anki-connect") {
        self.service = service
    }
    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service ?? "", kSecAttrAccount as String: "api-key"]
    }
    func read() throws -> String {
        guard service != nil else { return memory }
        var query = identity
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            throw failure()
        }
        return text
    }
    func save(_ text: String) throws {
        guard service != nil else { memory = text; return }
        if text.isEmpty {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }
        } else {
            let attributes = [kSecValueData as String: Data(text.utf8)]
            let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
            if status == errSecSuccess { return }
            guard status == errSecItemNotFound else { throw failure() }
            var insert = identity.merging(attributes) { _, new in new }
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw failure() }
        }
    }
    private func failure() -> AnkiReviewError {
        .message(String(localized: "Could not access the Anki API key in Keychain.", table: "Vocabulary"))
    }
}
