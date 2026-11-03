import Foundation

/// App startup and storage selection share this test-only admission rule. Copied validation
/// bundles remain isolated if a UI tool reopens them after XCTest has exited; ordinary Dev and
/// production bundles never carry this explicit marker and retain their usual startup path.
nonisolated enum LingroveTestHostPolicy {
    static var current: Bool {
        isActive(environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            validationFlag: Bundle.main.object(forInfoDictionaryKey: "LingroveIsolatedValidationHost") as? Bool == true)
    }

    static func isActive(environment: [String: String], bundleIdentifier: String?, validationFlag: Bool) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || (validationFlag && bundleIdentifier?.hasSuffix(".validation") == true)
    }
}
