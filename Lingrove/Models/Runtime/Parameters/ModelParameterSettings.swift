import Foundation

/// One app-owned task keeps a small per-destination profile map. Identities contain canonical
/// model destinations, never credentials; the profile's value type owns validation/defaults.
/// The owning settings object publishes only after storage commits, so cancellation observes
/// the new profile. Views borrow that owner's projection rather than a second settings service.
@MainActor
struct ModelParameterSettings<Profile: Codable & Equatable> {
    private var profiles: [String: Profile]
    private let defaults: UserDefaults
    private let key: String

    init(key: String, defaults: UserDefaults) {
        self.key = key
        self.defaults = defaults
        profiles = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Profile].self, from: $0) } ?? [:]
    }

    mutating func reset() {
        guard !profiles.isEmpty else { return }
        profiles = [:]
        defaults.removeObject(forKey: key)
    }

    func profile(for identity: String) -> Profile? { profiles[identity] }

    @discardableResult mutating func set(_ profile: Profile, for identity: String) -> Bool {
        guard profiles[identity] != profile else { return false }
        var next = profiles
        next[identity] = profile
        guard let encoded = try? JSONEncoder().encode(next) else { return false }
        profiles = next
        defaults.set(encoded, forKey: key)
        return true
    }
}
