import SwiftUI

/// File overview:
/// A live sample that shows how an inline suggestion will look with the user's chosen
/// ghost-text color, opacity, size, fade-in speed, and key-hint badge. It is deliberately
/// self-contained — there is no text field or model behind it — so a user can judge their
/// Appearance choices at a glance without switching to another app and triggering a real suggestion.
///
/// Fidelity: the typed prefix renders in the primary label color (like text the user already typed)
/// and the trailing run renders in the resolved ghost color at the chosen opacity (like a live
/// suggestion), matching how `GhostSuggestionView` splits already-typed text from the ghost.
///
/// Motion: style changes (color, opacity, size, bold/italic) interpolate via `SettingsMotion.interaction`.
/// Toggling `fadeInSuggestions` or dragging `Fade Speed` replays the actual entrance ramp over
/// `fadeInDurationSeconds` so the user feels the timing immediately.
struct GhostTextPreview: View {
    /// The resolved base ghost color, WITHOUT opacity applied — the view fades the ghost run itself so
    /// the typed prefix stays at full strength, exactly like the overlay.
    let ghostColor: Color
    /// Ghost-run fade in `[0.3, 1.0]`, applied only to the suggestion half.
    let opacity: Double
    /// Final preview point size (the representative base already scaled by the user's multiplier).
    let fontSize: CGFloat
    /// The user's suggestion style, applied to the ghost half only: the typed half shows the host's
    /// own text, which the setting never changes.
    var isBold: Bool = false
    var isItalic: Bool = false
    /// Whether the inline accept-key badge is shown beside the ghost text.
    var showAcceptanceHint: Bool = false
    /// Display label for the accept-key badge (e.g. "Tab").
    var acceptanceKeyLabel: String = "Tab"
    /// Whether new suggestions fade in smoothly.
    var fadeInSuggestions: Bool = false
    /// Duration of the fade-in ramp in seconds when `fadeInSuggestions` is enabled.
    var fadeInDurationSeconds: Double = 0.18

    /// Representative base size the multiplier scales in the preview. Sits near the lower end of
    /// the overlay's real `[14, 24]` caret-derived band, matching typical small-to-medium text
    /// fields where most users encounter ghost text in practice.
    static let baseFontSize: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fadeMultiplier: Double = 1.0
    @State private var replayTask: Task<Void, Never>?

    /// The whole sentence reads naturally with the ghost half completing the typed half, and labels
    /// itself as a sample so the user understands this is a preview rather than a real input.
    private let preview = CompletionPreviewText(
        resolvedSentence: String(
            localized: "This is how your¦ suggestions will look",
            comment: """
            Appearance settings preview. Keep exactly one ¦ to mark where typed text ends and ghost text begins; move it to fit the \
            translated sentence naturally.
            """
        )
    )

    var body: some View {
        let effectiveGhostOpacity = opacity * fadeMultiplier
        let sample = Text(preview.typedText).foregroundStyle(.primary)
            + Text(preview.ghostText)
                .fontWeight(isBold ? .bold : .regular)
                .italic(isItalic)
                .foregroundStyle(ghostColor.opacity(effectiveGhostOpacity))

        return HStack(alignment: .center, spacing: 8) {
            sample
                .font(.system(size: fontSize))
                .fixedSize(horizontal: false, vertical: true)
                .animation(SettingsMotion.resolved(SettingsMotion.interaction, reduceMotion: reduceMotion), value: fontSize)
                .animation(SettingsMotion.resolved(SettingsMotion.interaction, reduceMotion: reduceMotion), value: opacity)
                .animation(SettingsMotion.resolved(SettingsMotion.interaction, reduceMotion: reduceMotion), value: isBold)
                .animation(SettingsMotion.resolved(SettingsMotion.interaction, reduceMotion: reduceMotion), value: isItalic)

            if showAcceptanceHint && !acceptanceKeyLabel.isEmpty {
                Text(acceptanceKeyLabel)
                    .font(.system(size: max(10, fontSize * 0.68), weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.quaternary)
                    )
                    .opacity(fadeMultiplier)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .animation(SettingsMotion.resolved(SettingsMotion.interaction, reduceMotion: reduceMotion), value: showAcceptanceHint)
        .onChange(of: fadeInSuggestions) { _, enabled in
            if enabled {
                triggerFadeReplay()
            } else {
                replayTask?.cancel()
                fadeMultiplier = 1.0
            }
        }
        .onChange(of: fadeInDurationSeconds) { _, _ in
            if fadeInSuggestions {
                triggerFadeReplay()
            }
        }
        .onDisappear {
            replayTask?.cancel()
        }
        // One decorative element: the configured values are what the user reads off the controls,
        // so the sample text itself carries no extra information for VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of how suggestions will appear")
    }

    private func triggerFadeReplay() {
        guard !reduceMotion, fadeInSuggestions else {
            fadeMultiplier = 1.0
            return
        }
        replayTask?.cancel()
        let duration = max(0.05, fadeInDurationSeconds)
        replayTask = Task { @MainActor in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                fadeMultiplier = 0.0
            }
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: duration)) {
                fadeMultiplier = 1.0
            }
        }
    }
}
