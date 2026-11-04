// Adapted from Nibomo ReviewView.swift, Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_REVIEW_ACCOUNT_UI_REUSE.md.
import LingroveNotebookEngine
import SwiftUI

/// This fixed answer bar receives forecasts and closures from the pinned review question.
/// It owns neither scheduling nor keyboard monitoring: the exact-window controller scopes
/// shortcuts, while these native buttons remain reachable below the scrolling material.
struct LingroveReviewAnswerControls: View {
    let options: [LingroveReviewAnswerOption]?
    let onReveal: () -> Void
    let onRate: (ReviewRating) -> Void

    var body: some View {
        LingroveReadableContentLayout(maxWidth: lingroveReadableContentMaxWidth, horizontalPadding: 20) {
            VStack(spacing: 8) {
                answerActions
                Text(BuiltInReviewCopy.text("keyboard.hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12).padding(.bottom, 16)
        }
    }

    private var answerActions: some View {
        Group {
            if let options {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(options) { answerButton($0) }
                    }.frame(minWidth: 600)
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 10) {
                            ForEach(options.filter { $0.rating == .again || $0.rating == .good }) { answerButton($0) }
                        }
                        VStack(spacing: 10) {
                            ForEach(options.filter { $0.rating == .hard || $0.rating == .easy }) { answerButton($0) }
                        }
                    }
                }
            } else {
                Button(action: onReveal) {
                    Label(String(localized: "Show answer", table: "ReviewCards"), systemImage: "eye")
                        .frame(maxWidth: .infinity).frame(minHeight: 36)
                }
                .lingroveNativeProminentActionButtonStyle()
                .help(String(localized: "Space / Enter", table: "ReviewCards"))
                .accessibilityIdentifier("builtinReview.reveal")
            }
        }
    }

    private func answerButton(_ option: LingroveReviewAnswerOption) -> some View {
        let ratingColor = lingroveReviewRatingColor(option.rating)
        let keyNumber = String(option.rating.rawValue + 1)
        return Button { onRate(option.rating) } label: {
            VStack(alignment: .center, spacing: 5) {
                HStack(spacing: 6) {
                    Text(option.intervalDescription)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ratingColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(ratingColor.opacity(0.14))
                        )
                    Spacer(minLength: 4)
                    Text(keyNumber)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor))
                        )
                }

                HStack(spacing: 6) {
                    // Native bordered buttons do not consistently paint their tint on macOS.
                    // Color the rating symbol explicitly, keeping the written label in the
                    // semantic primary foreground for legibility in either appearance.
                    Image(systemName: option.rating.symbolName).font(.subheadline.weight(.semibold))
                        .foregroundStyle(ratingColor)
                    Text(lingroveLocalizedReviewRatingTitle(rating: option.rating))
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .center)
        }
        .buttonStyle(.bordered)
        .tint(ratingColor)
        .help(keyNumber + " · " + lingroveLocalizedReviewRatingTitle(rating: option.rating))
        .accessibilityIdentifier("builtinReview.rate." + keyNumber)
    }
}
