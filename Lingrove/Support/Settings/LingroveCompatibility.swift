import Foundation

/// Pure translations of the previous product's machine identifiers. Application code uses only
/// Lingrove names; this boundary accepts existing launch scripts without changing their values.
/// New names always win when a caller provides both. No instances or user data are retained.
nonisolated enum LingroveCompatibility {
    static var processArguments: [String] { arguments(ProcessInfo.processInfo.arguments) }
    static var processEnvironment: [String: String] { environment(ProcessInfo.processInfo.environment) }

    static func preferenceKey(forLegacy key: String) -> String? {
        if key.hasPrefix("cotabby") { return "lingrove" + key.dropFirst("cotabby".count) }
        let oldWindowPrefix = "NSWindow Frame Cotabby"
        if key.hasPrefix(oldWindowPrefix) { return "NSWindow Frame Lingrove" + key.dropFirst(oldWindowPrefix.count) }
        return nil
    }

    static func arguments(_ source: [String]) -> [String] {
        source.map { argument in
            let prefix = "-cotabby"
            guard argument.lowercased().hasPrefix(prefix) else { return argument }
            return "-lingrove" + argument.dropFirst(prefix.count)
        }
    }

    static func environment(_ source: [String: String]) -> [String: String] {
        var result = source
        for (key, value) in source where key.hasPrefix("COTABBY_") {
            let primary = "LINGROVE_" + key.dropFirst("COTABBY_".count)
            if result[primary] == nil { result[primary] = value }
        }
        return result
    }

    /// NSArgumentDomain is volatile. Mapping old `-cotabbySetting value` switches here preserves
    /// their precedence over saved settings without accidentally persisting a temporary override.
    static func installArgumentAliases(in defaults: UserDefaults) {
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var changed = false
        for (key, value) in arguments {
            if let primary = preferenceKey(forLegacy: key), arguments[primary] == nil {
                arguments[primary] = value
                changed = true
            }
        }
        if changed { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
    }
}
