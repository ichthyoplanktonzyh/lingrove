import Foundation

/// Per-app overrides for one app: accept keys, suggestion behavior, and translation permissions. A `nil` action inherits its
/// global binding; the disabled-key sentinel remains an explicit override. The type keeps its
/// original name because its JSON is persisted under `lingrovePerAppShortcutOverrides`.
struct PerAppShortcutOverride: Codable, Equatable, Identifiable, Sendable {
    let bundleIdentifier: String
    var displayName: String
    var acceptance: SuggestionShortcutBindingSettings?
    var fullAcceptance: SuggestionShortcutBindingSettings?
    /// App-specific suggestion behavior (mid-line, autocorrect, instructions). Optional so records
    /// saved before this existed decode unchanged; nil means every behavior follows the global setting.
    var behavior: PerAppBehavior?
    /// An explicit allowlist for the new reading shortcut. Optional fields preserve old JSON.
    var selectionTranslationAllowed: Bool?
    var pointerTranslationAllowed: Bool?
    var screenshotTranslationAllowed: Bool?
    /// nil follows Language Learning's global selection-icon switch.
    var selectionIcon: PerAppToggle?
    /// Existing writing commands retain their previous default; a conflict can disable them here.
    var writingTranslationShortcutsAllowed: Bool?

    var id: String { bundleIdentifier }
}

extension PerAppShortcutOverride {
    /// Apps whose Accept Entire Suggestion binding replaces the global one. A recorded key and
    /// Disable (the disabled-key sentinel) both count; only `nil` inherits the global slot.
    static func bundleIdentifiersOverridingFullAcceptance(in overrides: [PerAppShortcutOverride]) -> Set<String> {
        Set(overrides.filter { $0.fullAcceptance != nil }.map(\.bundleIdentifier))
    }
}
