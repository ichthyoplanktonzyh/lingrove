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
        Button { onRate(option.rating) } label: {
            VStack(alignment: .center, spacing: 4) {
                HStack(spacing: 8) {
                    // Native bordered buttons do not consistently paint their tint on macOS.
                    // Color the rating symbol explicitly, keeping the written label in the
                    // semantic primary foreground for legibility in either appearance.
                    Image(systemName: option.rating.symbolName).font(.headline)
                        .foregroundStyle(lingroveReviewRatingColor(option.rating))
                    Text(lingroveLocalizedReviewRatingTitle(rating: option.rating))
                        .fontWeight(.semibold).multilineTextAlignment(.center)
                }
                Text(option.intervalDescription).font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        }
        .buttonStyle(.bordered)
        .tint(lingroveReviewRatingColor(option.rating))
        .help(String(option.rating.rawValue + 1) + " · " + lingroveLocalizedReviewRatingTitle(rating: option.rating))
        .accessibilityIdentifier("builtinReview.rate." + String(option.rating.rawValue + 1))
    }
}
