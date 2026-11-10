import Foundation
import LingroveNotebook

/// A small deterministic parser is shared with app-hosted tests. It rejects duplicate/irrelevant
/// flags instead of accepting a write that differs from an agent's intent; IO belongs to the CLI.
nonisolated struct CLIArguments {
    enum Mode { case help, version, schema, captureSchema, request }
    var mode: Mode
    var request = CLIRequest(command: .status)
    var appPath: String?
    var inputPath: String?
    var captureInput = false
    var launch = true
    var timeout: TimeInterval = 30

    init(_ arguments: [String]) throws {
        if let informationalMode = Self.informationalMode(arguments) {
            mode = informationalMode
            return
        }
        mode = .request
        var parsed = try ParsedArguments(arguments)
        appPath = parsed.options.removeValue(forKey: "--app")
        launch = !parsed.flags.contains("--no-launch")
        timeout = try Self.parsedTimeout(parsed.options.removeValue(forKey: "--timeout"))
        try configureRequest(from: &parsed)
        guard parsed.options.isEmpty,
              !parsed.flags.contains("--summary") || request.summary == true,
              request.command == .apply || (!parsed.flags.contains("--dry-run") && !parsed.flags.contains("--stdin")) else {
            throw CLIError.invalid("An option is not valid for this command.")
        }
    }

    private static func informationalMode(_ arguments: [String]) -> Mode? {
        switch arguments {
        case [], ["--help"], ["help"]: .help
        case ["--version"]: .version
        case ["schema"]: .schema
        case ["schema", "capture"]: .captureSchema
        default: nil
        }
    }

    private static func parsedTimeout(_ value: String?) throws -> TimeInterval {
        guard let value else { return 30 }
        guard let seconds = Double(value), seconds.isFinite, (1...120).contains(seconds) else {
            throw CLIError.invalid("Timeout must be 1–120 seconds.")
        }
        return seconds
    }

    /// Each command consumes only its own options; leftovers retain the original irrelevant-option error.
    private mutating func configureRequest(from parsed: inout ParsedArguments) throws {
        switch parsed.words {
        case ["status"]:
            request.command = .status
        case ["vocab", "list"]:
            request.command = .list
            request.query = parsed.options.removeValue(forKey: "--query")
            request.language = parsed.options.removeValue(forKey: "--language")
            request.limit = try parsed.integerOption("--limit")
            request.offset = try parsed.integerOption("--offset")
        case ["vocab", "read"]:
            try configureBatchRead(from: &parsed)
        case let words where words.count == 3 && words[0] == "vocab" && words[1] == "sense":
            guard let id = UUID(uuidString: words[2]) else { throw CLIError.invalid("Sense requires a UUID.") }
            request.command = .sense; request.senseID = id
            try configureReadScope(from: &parsed)
        case let words where words.count == 4 && words[0] == "vocab" && words[1] == "image":
            try configureImageRequest(words, from: &parsed)
        case ["vocab", "apply"], ["vocab", "capture"]:
            captureInput = parsed.words[1] == "capture"
            try configureApplyRequest(from: &parsed)
        default:
            if parsed.words.first == "data" {
                try configureResourceRequest(from: &parsed)
                return
            }
            guard parsed.words.count == 3, Array(parsed.words.prefix(2)) == ["vocab", "get"],
                  let identifier = UUID(uuidString: parsed.words[2]) else {
                throw CLIError.invalid("Unknown command. Run 'lingrove --help'.")
            }
            request.command = .get
            request.entryID = identifier
            try configureReadScope(from: &parsed)
        }
    }

    private mutating func configureBatchRead(from parsed: inout ParsedArguments) throws {
        let entries = parsed.options.removeValue(forKey: "--entry-ids")
        let senses = parsed.options.removeValue(forKey: "--sense-ids")
        guard (entries != nil) != (senses != nil), let text = entries ?? senses, text.utf8.count <= 4_096 else {
            throw CLIError.invalid("Use vocab read with exactly one of --entry-ids or --sense-ids (comma-separated UUIDs).")
        }
        let ids = try text.split(separator: ",", omittingEmptySubsequences: false).map { value in
            guard let id = UUID(uuidString: String(value)) else { throw CLIError.invalid("Each batch read ID must be a UUID.") }
            return id
        }
        let selection = CLIReadSelection(kind: entries != nil ? .entries : .senses, ids: ids)
        try selection.validate()
        request.command = .readMany; request.readSelection = selection
        try configureReadScope(from: &parsed)
    }

    /// Unlike text reads, a delayed image fetch must retain the notebook identity of its reference.
    private mutating func configureImageRequest(_ words: [String], from parsed: inout ParsedArguments) throws {
        guard let id = UUID(uuidString: words[2]), words[3].count == 64,
              words[3].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CLIError.invalid("Image requires SENSE_UUID and the imageID returned by a sense read.")
        }
        request.command = .image; request.senseID = id; request.imageID = words[3]
        try configureReadScope(from: &parsed)
        guard request.readScope != nil else { throw CLIError.invalid("Image reads require --scope from the original sense read.") }
    }

    private mutating func configureReadScope(from parsed: inout ParsedArguments) throws {
        if let scope = parsed.options.removeValue(forKey: "--scope") {
            guard scope.utf8.count <= 4_096 else { throw CLIError.invalid("Read scope is too large.") }
            do {
                let value = try JSONDecoder().decode(CLIJSON.self, from: Data(scope.utf8))
                let checked = try CLINotebookScope.shape.normalized(value)
                request.readScope = try JSONDecoder().decode(CLINotebookScope.self, from: JSONEncoder().encode(checked))
            } catch { throw CLIError.invalid("--scope must be the notebookScope JSON returned by the original read.") }
        }
    }

    private mutating func configureResourceRequest(from parsed: inout ParsedArguments) throws {
        guard (3...4).contains(parsed.words.count), CLIResourceContract.names.contains(parsed.words[2]) else {
            throw CLIError.invalid("Use 'data list RESOURCE' or 'data get RESOURCE UUID'. Run 'lingrove --help'.")
        }
        request.resource = parsed.words[2]
        if parsed.words[1] == "list", parsed.words.count == 3 {
            request.command = .resourceList
            request.query = parsed.options.removeValue(forKey: "--query")
            request.limit = try parsed.integerOption("--limit")
            request.offset = try parsed.integerOption("--offset")
            request.claimStatus = parsed.options.removeValue(forKey: "--status")
            if parsed.flags.contains("--summary") {
                guard ["categories", "nodes"].contains(parsed.words[2]) else {
                    throw CLIError.invalid("--summary is supported by data list categories/nodes.")
                }
                request.summary = true
            }
            if let related = parsed.options.removeValue(forKey: "--related") {
                guard let id = UUID(uuidString: related) else { throw CLIError.invalid("--related requires a UUID.") }
                request.relatedID = id
            }
        } else if parsed.words[1] == "get", parsed.words.count == 4, let id = UUID(uuidString: parsed.words[3]) {
            request.command = .resourceGet; request.resourceID = id
        } else { throw CLIError.invalid("Invalid data command.") }
    }

    private mutating func configureApplyRequest(from parsed: inout ParsedArguments) throws {
        request.command = .apply
        request.dryRun = parsed.flags.contains("--dry-run")
        inputPath = parsed.options.removeValue(forKey: "--file")
        if parsed.flags.contains("--stdin") {
            guard inputPath == nil else { throw CLIError.invalid("Choose --file or --stdin.") }
            inputPath = "-"
        }
        guard inputPath != nil else { throw CLIError.invalid("Apply requires --file PATH or --stdin.") }
    }

    /// One initializer owns this temporary tokenization result. Keeping it separate from command
    /// interpretation preserves duplicate/missing-value validation before any command consumes options.
    private struct ParsedArguments {
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var words: [String] = []

        init(_ arguments: [String]) throws {
            let boolean: Set<String> = ["--dry-run", "--no-launch", "--stdin", "--summary"]
            let valued: Set<String> = ["--app", "--timeout", "--query", "--language", "--limit", "--offset", "--file",
                                       "--related", "--status", "--scope", "--entry-ids", "--sense-ids"]
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if boolean.contains(argument) {
                    guard flags.insert(argument).inserted else { throw CLIError.invalid("Duplicate flag: " + argument) }
                } else if valued.contains(argument) {
                    guard options[argument] == nil, index + 1 < arguments.count,
                          !arguments[index + 1].hasPrefix("--") else {
                        throw CLIError.invalid("Missing value or duplicate option: " + argument)
                    }
                    index += 1
                    options[argument] = arguments[index]
                } else if argument.hasPrefix("--") {
                    throw CLIError.invalid("Unknown option: " + argument)
                } else {
                    words.append(argument)
                }
                index += 1
            }
        }

        mutating func integerOption(_ key: String) throws -> Int? {
            guard let value = options.removeValue(forKey: key) else { return nil }
            guard let number = Int(value) else { throw CLIError.invalid("Invalid integer: " + key) }
            return number
        }
    }

    static let help = """
    Usage: lingrove [--app APP_PATH] [--no-launch] [--timeout SECONDS] COMMAND
      status                                     Storage status and revision
      vocab list [--query TEXT] [--language CODE] [--limit N] [--offset N]
      vocab get ENTRY_UUID [--scope JSON]        Current entry, plain explanation text and image references
      vocab sense SENSE_UUID [--scope JSON]      Complete current sense, examples and semantic links
      vocab read (--entry-ids UUID,UUID | --sense-ids UUID,UUID) [--scope JSON]
                                                Up to 100 full records in request order, from one snapshot
      vocab image SENSE_UUID IMAGE_ID --scope JSON  PNG bytes as JSON/base64
      vocab apply (--file PATH | --stdin) [--dry-run]
      vocab capture (--file PATH | --stdin) [--dry-run]  Task-shaped material and meaning organization
      data list RESOURCE [--query TEXT] [--related UUID] [--status STATUS] [--limit N] [--offset N] [--summary]
      data get RESOURCE UUID                     Full record and current revision
      schema [capture]                           Batch or capture-task JSON Schema
      --version | --help

    Capture generates IDs, locates unique example spans and collects senses atomically.
    Capture also creates meaning nodes and category memberships in the same write.
    Use schema capture for capture tasks; schema is the complete resource-batch contract.
    Each request checks the selected app path, server instance and protocol capabilities.
    --version reports the local helper's contract, containing app version/build and path.
    Model organization is active by default; explicit proposed claims remain suggestions.
    Images use explicit local paths, relative to the input file (stdin: current directory).
    Writes are atomic. Retry an uncertain write with the SAME idempotencyKey and content.
    New meanings create distinct senses; append uses exact IDs; update needs expectedRevision.
    Resources: entries, senses, sources, occurrences, interpretations,
      nodes, patterns, mappings, relations, cues, cueTargets,
      frameworks, categories, categoryParents, categoryMemberships, categoryOverrides.
    --summary returns compact category/node candidates; data get returns their full guidance.
    --query uses substring matching; whitespace-separated terms must all match, without ranking.
    Resource put/delete use batch version 2 and expectedRevision. Put merges fields;
    arrays replace, null clears optional fields. UUIDs are caller supplied.
    --status filters interpretations: candidate, accepted, rejected. --related matches UUID fields.
    Resource timestamps are Unix seconds. Catalog/graph writes do not implicitly collect material.
    Successful requests and errors use JSON on stdout. Exit codes: 0 success, 2 input,
    3 missing ID, 4 conflict, 5 busy, 6 app unavailable, 7 IO, 8 timeout.
    """
}
