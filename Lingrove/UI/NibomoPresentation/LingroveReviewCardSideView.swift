// Adapted from Nibomo (kirill-markin/flashcards-open-source-app), Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W3_UI_REUSE_MAP.md.
import SwiftUI
import AppKit

private let reviewCardsStringsTableName: String = "ReviewCards"
let lingroveReviewContentSurfaceCornerRadius: CGFloat = 24

/// Extracted Nibomo card surface. The review view owns it for one pinned face and injects
/// local image bytes and speech actions. AppKit replaces only UIKit copying; no remote loader
/// or AI companion is imported to render the source-owned material.
struct LingroveReviewCardSideView: View {
    let label: String
    let content: [BuiltInReviewSavedImage]
    let sourceText: String
    let onSelectText: () -> Void
    let isSpeechPlaying: Bool
    let onToggleSpeech: () -> Void
    let showsSpeechButton: Bool
    let surfaceStyle: LingroveReviewCardSurfaceStyle

    @State private var hasCopied: Bool = false
    @State private var copyError: String?

    init(
        label: String,
        content: [BuiltInReviewSavedImage],
        sourceText: String,
        onSelectText: @escaping () -> Void,
        isSpeechPlaying: Bool,
        onToggleSpeech: @escaping () -> Void,
        showsSpeechButton: Bool,
        surfaceStyle: LingroveReviewCardSurfaceStyle
    ) {
        self.label = label
        self.content = content
        self.sourceText = sourceText
        self.onSelectText = onSelectText
        self.isSpeechPlaying = isSpeechPlaying
        self.onToggleSpeech = onToggleSpeech
        self.showsSpeechButton = showsSpeechButton
        self.surfaceStyle = surfaceStyle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: self.onSelectText) {
                Text(self.label)
                    .font(.caption)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(self.surfaceStyle == .front
                ? "builtinReview.front.select"
                : "builtinReview.back.select")
            .accessibilityLabel(
                Text(self.label) + Text(", ") + Text(String(
                    localized: "review.text_selection.action",
                    defaultValue: "Select text",
                    table: reviewCardsStringsTableName,
                    comment: "Accessibility action appended to the Front or Back card caption button"
                ))
            )
            .accessibilityHint(String(
                localized: "review.text_selection.hint",
                defaultValue: "Opens the complete source text for selection and copying.",
                table: reviewCardsStringsTableName,
                comment: "Accessibility hint for opening a card side in the native text selection sheet"
            ))

            BuiltInReviewFace(text: self.sourceText, images: self.content)
                .accessibilityIdentifier(self.surfaceStyle == .front
                    ? "builtinReview.question" : "builtinReview.answer")
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button {
                    do {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        guard pasteboard.setString(self.sourceText, forType: .string) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        self.hasCopied = true
                    } catch {
                        self.hasCopied = false
                        self.copyError = error.localizedDescription
                    }
                } label: {
                    Image(systemName: self.hasCopied ? "checkmark" : "square.on.square")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .frame(minWidth: 32, minHeight: 32)
                        .background(.thinMaterial, in: Capsule())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(self.surfaceStyle == .front
                    ? "builtinReview.front.copy" : "builtinReview.back.copy")
                .accessibilityLabel(Text(self.copyActionLabel) + Text(", ") + Text(self.label))
                .help(self.copyActionLabel)

                if self.showsSpeechButton {
                    Button(action: self.onToggleSpeech) {
                        Image(systemName: self.isSpeechPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .frame(minWidth: 32, minHeight: 32)
                            .background(.thinMaterial, in: Capsule())
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        self.isSpeechPlaying
                            ? String(
                                format: String(localized: "Stop %@ speech", table: reviewCardsStringsTableName),
                                locale: Locale.current,
                                self.label
                            )
                            : String(
                                format: String(localized: "Speak %@", table: reviewCardsStringsTableName),
                                locale: Locale.current,
                                self.label
                            )
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .onChange(of: self.sourceText) {
            self.hasCopied = false
        }
        .background(backgroundStyle, in: RoundedRectangle(cornerRadius: lingroveReviewContentSurfaceCornerRadius, style: .continuous))
        .alert(
            String(localized: "Copy", table: reviewCardsStringsTableName),
            isPresented: Binding(
                get: { self.copyError != nil },
                set: { if $0 == false { self.copyError = nil } }
            )
        ) {
            Button(String(localized: "OK", table: reviewCardsStringsTableName), role: .cancel) {
                self.copyError = nil
            }
        } message: {
            Text(self.copyError ?? "")
        }
    }

    private var copyActionLabel: String {
        self.hasCopied
            ? String(localized: "Copied", table: reviewCardsStringsTableName)
            : String(localized: "Copy", table: reviewCardsStringsTableName)
    }

    private var backgroundStyle: AnyShapeStyle {
        switch surfaceStyle {
        case .front:
            return AnyShapeStyle(.thinMaterial)
        case .back:
            return AnyShapeStyle(.regularMaterial)
        }
    }
}

/// The surface role chooses Nibomo’s original material contrast, not a separate Card model.
enum LingroveReviewCardSurfaceStyle { case front, back }
