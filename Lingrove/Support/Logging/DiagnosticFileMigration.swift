import Foundation

/// File-name compatibility for the event log. The writer calls this before opening its handle,
/// so a rename cannot race its own rotation. Existing log bytes are moved, never rewritten; a
/// legacy symlink keeps old `tail` commands reading the current file. Other histories stay intact.
nonisolated enum DiagnosticFileMigration {
    static func eventLogURL(in directory: URL, manager: FileManager = .default) -> URL {
        let primary = directory.appendingPathComponent("lingrove.jsonl")
        let legacy = directory.appendingPathComponent("cotabby.jsonl")
        if !manager.fileExists(atPath: primary.path), manager.fileExists(atPath: legacy.path) {
            try? manager.moveItem(at: legacy, to: primary)
            let oldRotation = directory.appendingPathComponent("cotabby.jsonl.1")
            let newRotation = directory.appendingPathComponent("lingrove.jsonl.1")
            if !manager.fileExists(atPath: newRotation.path), manager.fileExists(atPath: oldRotation.path) {
                try? manager.moveItem(at: oldRotation, to: newRotation)
            }
        }
        // A dangling legacy symlink is still an existing directory entry. Do not replace a
        // user-owned file or a link that another process may be following.
        for (oldName, newName) in [("cotabby.jsonl", "lingrove.jsonl"), ("cotabby.jsonl.1", "lingrove.jsonl.1")] {
            let alias = directory.appendingPathComponent(oldName)
            if (try? manager.attributesOfItem(atPath: alias.path)) == nil {
                try? manager.createSymbolicLink(atPath: alias.path, withDestinationPath: newName)
            }
        }
        return primary
    }
}
