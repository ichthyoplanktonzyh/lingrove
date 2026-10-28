import Foundation

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
            let boolean: Set<String> = ["--dry-run", "--no-launch", "--stdin"]
            let valued: Set<String> = ["--app", "--timeout", "--query", "--language", "--limit", "--offset", "--file",
                                       "--related", "--status"]
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
      vocab get ENTRY_UUID                       Portable entry and current revision
      vocab apply (--file PATH | --stdin) [--dry-run]
      vocab capture (--file PATH | --stdin) [--dry-run]  Task-shaped material and meaning organization
      data list RESOURCE [--query TEXT] [--related UUID] [--status STATUS] [--limit N] [--offset N]
      data get RESOURCE UUID                     Full record and current revision
      schema [capture]                           Batch or capture-task JSON Schema
      --version | --help

    Capture generates IDs, locates unique example spans and collects senses atomically.
    Model organization is active by default; explicit proposed claims remain suggestions.
    Images use explicit local paths, relative to the input file (stdin: current directory).
    Writes are atomic. Retry an uncertain write with the SAME idempotencyKey and content.
    New meanings create distinct senses; append uses exact IDs; update needs expectedRevision.
    Resources: entries, senses, sources, occurrences, interpretations, collections,
      nodes, patterns, mappings, relations, cues, cueTargets.
    Resource put/delete use batch version 2 and expectedRevision. Put merges fields;
    arrays replace, null clears optional fields. UUIDs are caller supplied (collections: senseID).
    --status filters interpretations: candidate, accepted, rejected. --related matches UUID fields.
    Resource timestamps are Unix seconds. Catalog/graph writes do not implicitly collect material.
    Successful requests and errors use JSON on stdout. Exit codes: 0 success, 2 input,
    3 missing ID, 4 conflict, 5 busy, 6 app unavailable, 7 IO, 8 timeout.
    """
}
