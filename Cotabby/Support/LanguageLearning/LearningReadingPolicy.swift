import Foundation

/// Pure input limits are independent of model limits. Oversized targets fail whole; they are
/// never shortened into a different selection before generation.
nonisolated enum LearningReadingPolicy {
    static func validate(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LearningFailure.message(String(localized: "Select text before translating.", table: "Learning"))
        }
        guard text.utf8.count <= ModelContextBudget.maximumTextBytes else { throw ModelContextBudget.oversizedTarget() }
    }
}
