import Foundation
import Logging
import os

/// One namespace shared by Console and JSONL writers. Category extraction accepts old labels
/// during the transition, so a historical caller keeps its category without duplicating events.
nonisolated enum LingroveLogIdentity {
    static let subsystem = "io.ichthyoplanktonzyh.lingrove"

    static func category(for label: String) -> String {
        for prefix in [subsystem + ".", "com.cotabby."] where label.hasPrefix(prefix) {
            return String(label.dropFirst(prefix.count))
        }
        let parts = label.split(separator: ".", maxSplits: 2)
        return parts.count > 2 ? String(parts[2]) : label
    }
}

/// File overview:
/// Centralizes Lingrove's developer-only runtime switches.
///
/// Passing `-lingrove-debug` opts into local logs. Screenshot archives additionally require
/// `-lingrove-debug-screenshots`, so ordinary development does not encode or persist screen pixels.
nonisolated enum LingroveDebugOptions {
    static let launchArgument = "-lingrove-debug"
    static let screenshotLaunchArgument = "-lingrove-debug-screenshots"

    /// Compile-time availability prevents a saved preference from exposing developer panels in
    /// release builds. The settings model owns the user's separate, durable visibility choice.
    static var areOverlaysAvailable: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static var isEnabled: Bool {
        LingroveCompatibility.processArguments.contains(launchArgument)
    }

    static var isScreenshotCaptureEnabled: Bool {
        shouldCaptureScreenshots(arguments: LingroveCompatibility.processArguments)
    }

    /// The screenshot switch alone cannot opt a normal launch into privacy-sensitive artifacts.
    /// Keeping this decision pure also lets tests check all flag combinations without relaunching.
    static func shouldCaptureScreenshots(arguments: [String]) -> Bool {
        LingroveCompatibility.arguments(arguments).contains(launchArgument) &&
            LingroveCompatibility.arguments(arguments).contains(screenshotLaunchArgument)
    }

    /// The swift-log floor applied to the always-on `OSLogHandler` and the debug-only file sinks.
    ///
    /// swift-log only skips evaluating a log call's `@autoclosure` message (and building its
    /// metadata) when the handler's `logLevel` is strictly greater than the call's level. The
    /// handlers previously hardcoded `.trace`, so *every* `.debug`/`.trace` call on the hot path
    /// (one per keystroke: focus snapshots, routing, generation boundaries) still built its message
    /// string and metadata dictionary even in release builds where nothing consumed it. That is
    /// wasted CPU and energy, and it quietly inflates any on-device energy measurement. Defaulting
    /// the floor to `.info` makes those hot-path calls genuinely free unless verbose logging is
    /// explicitly requested.
    ///
    /// Precedence, highest first:
    /// 1. `LINGROVE_LOG_LEVEL=<trace|debug|info|notice|warning|error|critical>` — explicit override,
    ///    e.g. to get Console `.debug` output without the heavier `-lingrove-debug` file/screenshot
    ///    artifacts. An unrecognized value is ignored.
    /// 2. `-lingrove-debug` — full `.trace` capture to Console and the JSONL sinks.
    /// 3. Default — `.info`.
    static var minimumLogLevel: Logging.Logger.Level {
        if let raw = LingroveCompatibility.processEnvironment["LINGROVE_LOG_LEVEL"]?.lowercased(),
           let level = Logging.Logger.Level(rawValue: raw) {
            return level
        }
        return isEnabled ? .trace : .info
    }

    /// Writes a diagnostic line only when the explicit debug launch argument is present.
    ///
    /// Keep this for metadata, not raw user content. Full prompts, OCR text, and screenshots are
    /// sensitive enough that call sites should make an intentional artifact decision instead of
    /// accidentally leaking them through normal stdout.
    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else {
            return
        }

        LingroveLogger.debug.debug("\(message())")
    }
}

/// Provides subsystem-scoped loggers for the entire app.
///
/// All loggers route through `OSLogHandler` so messages appear in Console.app with the
/// subsystem as a filterable column. When the `-lingrove-debug` launch argument is set we
/// additionally fan out to `FileLogHandler`, which writes JSONL to
/// `~/Library/Logs/Lingrove/lingrove.jsonl` for AI-assisted debugging without copy-paste.
nonisolated enum LingroveLogger {
    /// Reserved label that routes only to the dedicated LLM I/O sink, never to OSLog or the main
    /// JSONL file. Kept out of OSLog because full prompts/completions can be many KB per request
    /// and would dominate Console.app; kept out of `lingrove.jsonl` because it would drown the
    /// orchestration signal an AI debugger wants to skim.
    static let llmIOLabel = "io.ichthyoplanktonzyh.lingrove.llm-io"

    private static let bootstrapOnce: Void = {
        // The debug-flag check happens once, at bootstrap time. Toggling it requires a relaunch,
        // which matches how every other launch-arg in the app behaves.
        let installFileHandler = LingroveDebugOptions.isEnabled
        LoggingSystem.bootstrap { label in
            if label == llmIOLabel {
                // LLM I/O records are debug-only by design — installing the handler unconditionally
                // would let release builds write full prompts to disk.
                guard installFileHandler else { return SwiftLogNoOpLogHandler() }
                return LLMIOFileHandler(label: label)
            }
            let osHandler = OSLogHandler(label: label)
            guard installFileHandler else { return osHandler }
            return MultiplexLogHandler([osHandler, FileLogHandler(label: label)])
        }
        announceConfiguration(fileSinksInstalled: installFileHandler)
    }()

    /// Call once at app startup (e.g. in AppDelegate.init) before any logger is used.
    static func bootstrap() {
        _ = bootstrapOnce
    }

    /// Emits a single startup line recording the active logging configuration: whether debug mode
    /// is on, the effective verbosity floor, and where the JSONL sinks live. Logged at `.info` so it
    /// survives even the default quiet configuration — it is the first thing a developer (or an AI
    /// debugging agent reading the logs) needs before interpreting anything else, and it makes a
    /// misconfigured verbosity obvious instead of looking like "nothing is being logged".
    private static func announceConfiguration(fileSinksInstalled: Bool) {
        var metadata: Logging.Logger.Metadata = [
            "debug_mode": .stringConvertible(LingroveDebugOptions.isEnabled),
            "min_log_level": .string(LingroveDebugOptions.minimumLogLevel.rawValue),
            "file_sinks": .stringConvertible(fileSinksInstalled)
        ]
        // Only touch the file writers when sinks are actually installed: referencing `.shared` opens
        // the on-disk handle, which must never happen in the default (no-sink) configuration.
        if fileSinksInstalled {
            if let path = FileLogWriter.shared.fileURL?.path {
                metadata["event_log"] = .string(path)
            }
            if let path = LLMIOFileWriter.shared.fileURL?.path {
                metadata["llm_io_log"] = .string(path)
            }
        }
        app.info("Logging initialized", metadata: metadata)
    }

    static let app = Logger(label: "io.ichthyoplanktonzyh.lingrove.app")
    static let debug = Logger(label: "io.ichthyoplanktonzyh.lingrove.debug")
    static let runtime = Logger(label: "io.ichthyoplanktonzyh.lingrove.runtime")
    static let focus = Logger(label: "io.ichthyoplanktonzyh.lingrove.focus")
    static let updates = Logger(label: "io.ichthyoplanktonzyh.lingrove.updates")
    static let models = Logger(label: "io.ichthyoplanktonzyh.lingrove.models")
    static let suggestion = Logger(label: "io.ichthyoplanktonzyh.lingrove.suggestion")
    static let learning = Logger(label: "io.ichthyoplanktonzyh.lingrove.learning")
    static let speech = Logger(label: "io.ichthyoplanktonzyh.lingrove.speech")
    /// Full prompts and completions, one structured JSON record per generation. Writes to
    /// `~/Library/Logs/Lingrove/llm-io.jsonl` only when `-lingrove-debug` is set.
    static let llmIO = Logger(label: llmIOLabel)
}

/// Bridges swift-log into Apple's Unified Logging so every log line appears in Console.app
/// with the correct subsystem, category, and native log level.
struct OSLogHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level

    private let osLogger: os.Logger

    /// Apple's convention: `subsystem` is the app-wide identifier (constant for all loggers),
    /// `category` is the per-component label. This way Console.app can filter all Lingrove output
    /// with one subsystem while still distinguishing components by category.
    private static let subsystem = LingroveLogIdentity.subsystem

    /// `logLevel` defaults to `LingroveDebugOptions.minimumLogLevel` so the always-on Console sink is
    /// quiet (`.info`) in normal runs and fully verbose (`.trace`) under `-lingrove-debug`. The floor
    /// is what lets swift-log skip per-keystroke `.debug`/`.trace` calls before they allocate.
    init(label: String, logLevel: Logging.Logger.Level = LingroveDebugOptions.minimumLogLevel) {
        self.logLevel = logLevel
        let category = LingroveLogIdentity.category(for: label)
        osLogger = os.Logger(subsystem: Self.subsystem, category: category)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: borrowing Logging.LogEvent) {
        let text = "\(event.message)"
        switch event.level {
        case .trace:
            osLogger.trace("\(text, privacy: .public)")
        case .debug:
            osLogger.debug("\(text, privacy: .public)")
        case .info, .notice:
            osLogger.info("\(text, privacy: .public)")
        case .warning:
            osLogger.warning("\(text, privacy: .public)")
        case .error:
            osLogger.error("\(text, privacy: .public)")
        case .critical:
            osLogger.critical("\(text, privacy: .public)")
        }
    }
}
