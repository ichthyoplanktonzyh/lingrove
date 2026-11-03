// Adapted from Nibomo ReviewView.swift, Copyright (c) 2026 Kirill Markin.
// MIT license: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W3_UI_REUSE_MAP.md.
import LingroveNotebookEngine
import SwiftUI

/// The extracted reveal/rating bottom bar receives forecasts and closures from the pinned
/// review question. It has no scheduler or task ownership. Keeping it outside the scrolling
/// card preserves Nibomo’s always-reachable answer interaction at native window sizes.
struct LingroveReviewAnswerControls: View {
    let options: [LingroveReviewAnswerOption]?
    let onReveal: () -> Void
    let onRate: (ReviewRating) -> Void

    var body: some View {
        LingroveReadableContentLayout(maxWidth: lingroveReadableContentMaxWidth, horizontalPadding: 20) {
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
                            .frame(maxWidth: .infinity).frame(minHeight: 56)
                    }
                    .lingroveNativeProminentActionButtonStyle()
                    .help(String(localized: "Space / Enter", table: "ReviewCards"))
                    .accessibilityIdentifier("builtinReview.reveal")
                }
            }
            .padding(.top, 8).padding(.bottom, 16)
        }
    }

    private func answerButton(_ option: LingroveReviewAnswerOption) -> some View {
        Button { onRate(option.rating) } label: {
            VStack(alignment: .center, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: option.rating.symbolName).font(.headline)
                    Text(lingroveLocalizedReviewRatingTitle(rating: option.rating))
                        .fontWeight(.semibold).multilineTextAlignment(.center)
                }
                Text(option.intervalDescription).font(.caption2).opacity(0.8)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        }
        .lingroveNativeProminentActionButtonStyle()
        .help(String(option.rating.rawValue + 1))
        .accessibilityIdentifier("builtinReview.rate." + String(option.rating.rawValue + 1))
    }
}
