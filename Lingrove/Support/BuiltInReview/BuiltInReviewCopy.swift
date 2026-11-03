import Foundation
import LingroveNotebookEngine

/// Review owns its small catalog so new Mac wording stays independent of optional Anki copy.
/// The host's ordinary bundle localization chooses the same fifteen supported UI languages.
nonisolated enum BuiltInReviewCopy {
    static func text(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), table: "BuiltInReview")
    }

    static func status(_ status: LingroveNotebookReviewStatus) -> String {
        switch status {
        case .active: text("status.active")
        case .paused: text("status.paused")
        case .withdrawn: text("status.withdrawn")
        }
    }

    static func rating(_ rating: ReviewRating) -> String {
        switch rating {
        case .again: text("rating.again")
        case .hard: text("rating.hard")
        case .good: text("rating.good")
        case .easy: text("rating.easy")
        }
    }
}
