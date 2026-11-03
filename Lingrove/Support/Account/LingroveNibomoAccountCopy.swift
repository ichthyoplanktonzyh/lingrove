import Foundation

/// Only the selected upstream account copy is bundled, with the existing fifteen Mac locales.
/// This facade deliberately has no URL, telemetry or guest default; presentation reads strings
/// while the process-owned account service remains the sole owner of connection configuration.
enum LingroveNibomoAccountCopy {
    static func text(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "NibomoAccount") }
}
