import Foundation

/// Comparing text at shared document offsets distinguishes a real committed edit from moving the
/// caret through the same text. Snapshot windows are bounded, so their raw concatenations alone
/// are not comparable: a navigation can trim one edge and expose another without editing anything.
nonisolated enum LearningCommittedTextChangePolicy {
    static func hasMutation(from old: FocusedInputSnapshot, to new: FocusedInputSnapshot) -> Bool {
        guard old.sessionIdentity == new.sessionIdentity,
              new.documentSelection.length == 0 else { return false }
        if let marked = old.hostMarkedTextRange, marked.length > 0,
           marked.location < old.documentSelection.location, !new.hasHostMarkedText {
            // Cancellation can remove the entire preedit. A committed nonempty span must remain
            // before the new caret; equal text then proves an attribute-only commit, otherwise the
            // normal shared-offset comparison below must prove a real content change.
            guard new.documentSelection.location > marked.location else { return false }
            if old.documentSelection == new.documentSelection,
               old.precedingText == new.precedingText, old.trailingText == new.trailingText { return true }
        }
        // Real AX document lengths distinguish deletion from caret motion even when every
        // remaining character is the same prefix (or both bounded windows contain repeated text).
        // Only committed snapshots use this shortcut. Composition ending still needs the original
        // text/caret evidence above and below, since removing preedit can also shorten the value.
        // A collapsed selection after deleting selected text is also an edit when length proves it.
        if !old.hasHostMarkedText, let oldLength = old.documentLength,
           let newLength = new.documentLength, oldLength != newLength { return true }
        guard old.documentSelection.length == 0 else { return false }
        let oldText = (old.precedingText + old.trailingText) as NSString
        let newText = (new.precedingText + new.trailingText) as NSString
        let oldStart = old.documentSelection.location - old.precedingText.utf16.count
        let newStart = new.documentSelection.location - new.precedingText.utf16.count
        let start = max(oldStart, newStart)
        let end = min(oldStart + oldText.length, newStart + newText.length)
        guard start < end else { return false }
        return oldText.substring(with: NSRange(location: start - oldStart, length: end - start)) !=
            newText.substring(with: NSRange(location: start - newStart, length: end - start))
    }
}
