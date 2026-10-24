import Foundation
import Testing
@testable import Lingrove

/// Each case owns a temporary preference domain. These tests exercise the same upgrade as launch
/// without reading or writing the developer's real application preferences or Keychain.
@MainActor
struct LingrovePreferencesMigrationTests {
    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let domain = "LingrovePreferencesMigrationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults, domain)
    }

    @Test
    func preservesValuesAndKeepsNewSettingsWhenBothNamesExist() throws {
        try withDefaults { defaults, domain in
            defaults.set(false, forKey: "cotabbyGloballyEnabled")
            defaults.set(0, forKey: "cotabbyTotalAcceptedWordCount")
            defaults.set([String](), forKey: "cotabbyResponseLanguages")
            defaults.set("old.gguf", forKey: "cotabbySelectedModelFilename")
            defaults.set("chosen.gguf", forKey: "lingroveSelectedModelFilename")
            defaults.set("window-frame", forKey: "NSWindow Frame CotabbySettingsWindowV7")
            #expect(LingrovePreferencesMigration.migrate(defaults, domainName: domain) == 4)
            #expect(defaults.object(forKey: "lingroveGloballyEnabled") as? Bool == false)
            #expect(defaults.integer(forKey: "lingroveTotalAcceptedWordCount") == 0)
            #expect(defaults.stringArray(forKey: "lingroveResponseLanguages") == [])
            #expect(defaults.string(forKey: "lingroveSelectedModelFilename") == "chosen.gguf")
            #expect(defaults.string(forKey: "NSWindow Frame LingroveSettingsWindowV7") == "window-frame")
            #expect(defaults.string(forKey: "cotabbySelectedModelFilename") == "old.gguf")
        }
    }

    @Test
    func completedMigrationDoesNotReviveAResetPreference() throws {
        try withDefaults { defaults, domain in
            defaults.set("old.gguf", forKey: "cotabbySelectedModelFilename")
            #expect(LingrovePreferencesMigration.migrate(defaults, domainName: domain) == 1)
            defaults.removeObject(forKey: "lingroveSelectedModelFilename")
            #expect(LingrovePreferencesMigration.migrate(defaults, domainName: domain) == 0)
            #expect(defaults.object(forKey: "lingroveSelectedModelFilename") == nil)
        }
    }

    @Test
    func ignoresRegisteredDefaultsAndKeepsArgumentAliasesVolatile() throws {
        try withDefaults { defaults, domain in
            defaults.register(defaults: ["cotabbyUserName": "registered"])
            defaults.setVolatileDomain(["cotabbyGloballyEnabled": false], forName: UserDefaults.argumentDomain)
            defer { defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
            LingroveCompatibility.installArgumentAliases(in: defaults)
            #expect(defaults.object(forKey: "lingroveGloballyEnabled") as? Bool == false)
            #expect(LingrovePreferencesMigration.migrate(defaults, domainName: domain) == 0)
            let saved = defaults.persistentDomain(forName: domain) ?? [:]
            #expect(saved["lingroveUserName"] == nil && saved["lingroveGloballyEnabled"] == nil)
        }
    }

    @Test
    func backupContainsTheOriginalDomainBeforeAnyNewKeysAreWritten() throws {
        try withDefaults { defaults, domain in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            defaults.set("original", forKey: "cotabbyUserName")
            LingrovePreferencesMigration.migrate(defaults, domainName: domain, backupDirectory: directory)
            let file = directory.appendingPathComponent("preferences-before-lingrove-namespace-v1.plist")
            let saved = try #require(try PropertyListSerialization.propertyList(
                from: Data(contentsOf: file), options: 0, format: nil) as? [String: Any])
            #expect(saved["cotabbyUserName"] as? String == "original")
            #expect(saved["lingroveUserName"] == nil)
        }
    }

    @Test
    func launchAndEnvironmentAliasesPreferExplicitNewNames() {
        #expect(LingroveCompatibility.arguments(["app", "-cotabby-debug", "-Cotabby-check-for-updates-on-launch"])
            == ["app", "-lingrove-debug", "-lingrove-check-for-updates-on-launch"])
        #expect(LingroveDebugOptions.shouldCaptureScreenshots(arguments: ["-cotabby-debug", "-cotabby-debug-screenshots"]))
        #expect(!LingroveDebugOptions.shouldCaptureScreenshots(arguments: ["-cotabby-debug-screenshots"]))
        let values = LingroveCompatibility.environment(["COTABBY_LOG_LEVEL": "trace", "LINGROVE_LOG_LEVEL": "info",
            "COTABBY_EVAL_MODEL_PATH": "model.gguf"])
        #expect(values["LINGROVE_LOG_LEVEL"] == "info")
        #expect(values["LINGROVE_EVAL_MODEL_PATH"] == "model.gguf")
        #expect(LingroveLogIdentity.category(for: "io.ichthyoplanktonzyh.lingrove.runtime") == "runtime")
        #expect(LingroveLogIdentity.category(for: "com.cotabby.runtime") == "runtime")
    }
}
