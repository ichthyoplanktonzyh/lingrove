import Foundation

/// A small deterministic parser is shared with app-hosted tests. It rejects duplicate/irrelevant
/// flags instead of accepting a write that differs from an agent's intent; IO belongs to the CLI.
nonisolated struct CLIArguments {
    enum Mode { case help, version, schema, request }
    var mode: Mode
    var request = CLIRequest(command: .status)
    var appPath: String?
    var inputPath: String?
    var launch = true
    var timeout: TimeInterval = 30

    init(_ arguments: [String]) throws {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] { mode = .help; return }
        if arguments == ["--version"] { mode = .version; return }
        if arguments == ["schema"] { mode = .schema; return }
        mode = .request
        var options: [String: String] = [:], flags = Set<String>(), words: [String] = [], index = 0
        let boolean: Set<String> = ["--dry-run", "--no-launch", "--stdin"]
        let valued: Set<String> = ["--app", "--timeout", "--query", "--language", "--limit", "--offset", "--file"]
        while index < arguments.count {
            let argument = arguments[index]
            if boolean.contains(argument) {
                guard flags.insert(argument).inserted else { throw CLIError.invalid("Duplicate flag: " + argument) }
            } else if valued.contains(argument) {
                guard options[argument] == nil, index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw CLIError.invalid("Missing value or duplicate option: " + argument)
                }
                index += 1; options[argument] = arguments[index]
            } else if argument.hasPrefix("--") { throw CLIError.invalid("Unknown option: " + argument) }
            else { words.append(argument) }
            index += 1
        }
        appPath = options.removeValue(forKey: "--app"); launch = !flags.contains("--no-launch")
        if let value = options.removeValue(forKey: "--timeout") {
            guard let seconds = Double(value), seconds.isFinite, (1...120).contains(seconds) else { throw CLIError.invalid("Timeout must be 1–120 seconds.") }
            timeout = seconds
        }
        if words == ["status"] { request.command = .status }
        else if words == ["vocab", "list"] {
            request.command = .list; request.query = options.removeValue(forKey: "--query"); request.language = options.removeValue(forKey: "--language")
            for key in ["--limit", "--offset"] {
                if let value = options.removeValue(forKey: key) {
                    guard let number = Int(value) else { throw CLIError.invalid("Invalid integer: " + key) }
                    if key == "--limit" { request.limit = number } else { request.offset = number }
                }
            }
        } else if words.count == 3, Array(words.prefix(2)) == ["vocab", "get"], let id = UUID(uuidString: words[2]) {
            request.command = .get; request.entryID = id
        } else if words == ["vocab", "apply"] {
            request.command = .apply; request.dryRun = flags.contains("--dry-run")
            inputPath = options.removeValue(forKey: "--file")
            if flags.contains("--stdin") {
                guard inputPath == nil else { throw CLIError.invalid("Choose --file or --stdin.") }; inputPath = "-"
            }
            guard inputPath != nil else { throw CLIError.invalid("Apply requires --file PATH or --stdin.") }
        } else { throw CLIError.invalid("Unknown command. Run 'lingrove --help'.") }
        guard options.isEmpty, request.command == .apply || (!flags.contains("--dry-run") && !flags.contains("--stdin")) else {
            throw CLIError.invalid("An option is not valid for this command.")
        }
    }

    static let help = """
    Usage: lingrove [--app APP_PATH] [--no-launch] [--timeout SECONDS] COMMAND
      status                                     Storage status and revision
      vocab list [--query TEXT] [--language CODE] [--limit N] [--offset N]
      vocab get ENTRY_UUID                       Portable entry and current revision
      vocab apply (--file PATH | --stdin) [--dry-run]
      schema                                     Batch JSON Schema (version 1)
      --version | --help

    Images use explicit local paths, relative to the input file (stdin: current directory).
    Writes are atomic. Retry an uncertain write with the SAME idempotencyKey and content.
    New meanings create distinct senses; append uses exact IDs; update needs expectedRevision.
    Successful requests and errors use JSON on stdout. Exit codes: 0 success, 2 input,
    3 missing ID, 4 conflict, 5 busy, 6 app unavailable, 7 IO, 8 timeout.
    """
}
