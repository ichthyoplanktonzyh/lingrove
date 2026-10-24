import SwiftUI

/// Presentation-only action identities let an embedded walkthrough point at the same controls
/// used by live cards. No highlight or gesture exists unless a host explicitly supplies it.
enum LearningCardAction: Hashable { case explanation, favorite, speech, replace, expand, dismiss, dictionarySources }

private struct LearningInteractionKey: EnvironmentKey { static let defaultValue: () -> Void = {} }

private struct LearningActionEmphasisKey: EnvironmentKey {
    static let defaultValue: LearningCardAction? = nil
}
private struct LearningFavoriteMenuKey: EnvironmentKey { static let defaultValue: Binding<Bool>? = nil }
private struct LearningDictionaryMenuKey: EnvironmentKey { static let defaultValue: Binding<Bool>? = nil }

extension EnvironmentValues {
    /// Controls report intent from their action/binding, including keyboard and AX activation.
    /// An embedded host can pause a walkthrough; live cards keep their ordinary no-op default.
    var learningInteraction: () -> Void {
        get { self[LearningInteractionKey.self] }
        set { self[LearningInteractionKey.self] = newValue }
    }
    /// Optional presentation bindings let an embedded host coordinate its own popovers.
    /// Live cards leave these nil and continue owning their existing local state.
    var learningFavoriteMenu: Binding<Bool>? {
        get { self[LearningFavoriteMenuKey.self] }
        set { self[LearningFavoriteMenuKey.self] = newValue }
    }
    var learningDictionaryMenu: Binding<Bool>? {
        get { self[LearningDictionaryMenuKey.self] }
        set { self[LearningDictionaryMenuKey.self] = newValue }
    }
    var learningActionEmphasis: LearningCardAction? {
        get { self[LearningActionEmphasisKey.self] }
        set { self[LearningActionEmphasisKey.self] = newValue }
    }
}

extension View {
    func learningAction(_ action: LearningCardAction) -> some View { modifier(LearningActionEmphasisModifier(action: action)) }
}

/// The ring draws outside the existing hit area, so demonstrations neither resize the header
/// nor change the AppKit/SwiftUI event behavior that production popovers depend on.
private struct LearningActionEmphasisModifier: ViewModifier {
    let action: LearningCardAction
    @Environment(\.learningActionEmphasis) private var emphasized
    func body(content: Content) -> some View {
        content.overlay {
            if emphasized == action {
                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-3).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}
