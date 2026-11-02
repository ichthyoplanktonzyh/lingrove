import LingroveNotebookEngine

/// AppKit translates a window event into these values. This pure policy knows nothing about
/// global input monitoring, so numeric typing, Tab navigation and another app's keys stay local.
nonisolated enum BuiltInReviewKeyboardPolicy {
    enum Key: Equatable { case reveal, digit(Int), undo, other }
    enum Phase: Equatable { case question, answer, finished, other }
    enum Action: Equatable { case reveal, rate(ReviewRating), undo }

    /// AppKit captures these interaction conditions once for one event. A value keeps the
    /// gating inputs explicit without coupling the pure policy to a window or text responder.
    struct Interaction {
        let isKeyWindow: Bool
        let isEditingText: Bool
        let hasSheet: Bool
        let isBusy: Bool
        let canUndo: Bool
    }

    static func action(key: Key, phase: Phase, interaction: Interaction) -> Action? {
        guard interaction.isKeyWindow, !interaction.isEditingText, !interaction.hasSheet, !interaction.isBusy else { return nil }
        switch (key, phase) {
        case (.reveal, .question): return .reveal
        case let (.digit(number), .answer): return ReviewRating(rawValue: number - 1).map(Action.rate)
        case (.undo, .question), (.undo, .answer), (.undo, .finished): return interaction.canUndo ? .undo : nil
        default: return nil
        }
    }
}
