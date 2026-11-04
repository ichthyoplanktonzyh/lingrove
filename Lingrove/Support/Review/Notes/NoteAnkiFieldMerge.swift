import Foundation

/// A note's local projection and remote receipt are separate baselines. Unchanged source fields
/// retain remote edits; simultaneous changes need an explicit per-field decision. Recording the
/// chosen override prevents the next source refresh from silently discarding that decision.
nonisolated enum NoteAnkiFieldMerge {
    struct Result {
        var fields: [String: String]
        var overrides: [String: String]
        var conflicts: [String]
    }
    static func resolve(
        desired: [String: String], remote: [String: String], receipt: NoteAnkiJournal.Note?,
        choices: [String: Bool]
    ) -> Result {
        var result = Result(fields: desired, overrides: receipt?.overrides ?? [:], conflicts: [])
        for (name, local) in desired where name != "LingroveNoteID" {
            let savedLocal = receipt?.localFields[name]
            let savedRemote = receipt?.remoteFields[name]
            let value = remote[name] ?? ""
            if let keepRemote = choices[name] {
                if keepRemote {
                    result.fields[name] = value
                    result.overrides[name] = value
                } else {
                    result.overrides[name] = nil
                }
            } else if value == local {
                result.overrides[name] = nil
            } else if receipt != nil && savedLocal == nil && savedRemote == nil && !value.isEmpty {
                // A newly appended field has no acknowledged baseline. Nonempty remote text
                // is authored content, not the empty value Anki initially supplied.
                if local.isEmpty {
                    result.fields[name] = value
                    result.overrides[name] = value
                } else {
                    result.conflicts.append(name)
                }
            } else if result.overrides[name] != nil || (savedRemote != nil && value != savedRemote) {
                if savedLocal == local {
                    result.fields[name] = value
                    result.overrides[name] = value
                } else {
                    result.conflicts.append(name)
                }
            } else if receipt == nil && value != local {
                result.conflicts.append(name)
            }
        }
        return result
    }
}
