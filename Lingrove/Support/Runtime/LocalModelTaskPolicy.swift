import Foundation

/// Pure task admission, shared by settings and execution. Unknown files require a separately
/// recorded user choice; renaming a well-known base/specialist family cannot grant another task.
nonisolated enum LocalModelTaskPolicy {
    static func supports(_ filename: String, task: LocalModelTask) -> Bool {
        guard !filename.isEmpty else { return false }
        if let entry = LocalModelCatalog.descriptor(for: filename) {
            return entry.task == task && !entry.isResource
        }
        let name = filename.lowercased().filter { $0.isLetter || $0.isNumber }
        if filename.lowercased().hasPrefix("mmproj-") || name.contains("mmproj") { return false }
        if name.contains("qwen3tts") { return task == .speech }
        if name.contains("translategemma") || name.contains("hymt") || name.contains("hunyuanmt") {
            return task == .translation
        }
        if RuntimeModelCatalog.isKnownBaseModel(filename) { return task == .completion }
        return true
    }

    static func isCandidate(_ filename: String, task: LocalModelTask, assignedTasks: Set<LocalModelTask>) -> Bool {
        supports(filename, task: task) && (LocalModelCatalog.descriptor(for: filename) != nil || assignedTasks.contains(task))
    }

    static func permitsTemplate(_ template: LearningChatTemplate, task: LocalModelTask) -> Bool {
        let specialist = [LearningChatTemplate.hyMT, .hyMT7, .translateGemma].contains(template)
        switch task {
        // Explicit custom translation setups retain their manual framing. Curated model task
        // identity is checked independently, so a tutor/base catalog entry still cannot cross over.
        case .translation: return true
        case .explanation: return !specialist
        case .completion, .speech: return true
        }
    }
}
