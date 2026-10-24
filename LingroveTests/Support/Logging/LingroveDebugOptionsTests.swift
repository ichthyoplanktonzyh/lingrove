import Foundation
import XCTest
@testable import Lingrove

/// Locks the developer-diagnostics gate and the logging verbosity floor: the launch-argument
/// contract, the documented `LINGROVE_LOG_LEVEL` precedence, and the swift-log-to-OSLog bridge.
///
/// Environment-variable tests mutate the process environment through `setenv`/`unsetenv` and
/// restore the prior value before returning; XCTest runs the methods in this bundle serially, so
/// no other test can observe the temporary value.
final class LingroveDebugOptionsTests: XCTestCase {
    private static let levelKey = "LINGROVE_LOG_LEVEL"

    /// Runs `body` with the environment variable forced to `value` (or removed when nil), then
    /// restores whatever was there before, even if `body` throws or skips.
    private func withEnvironmentValue(
        _ key: String,
        _ value: String?,
        perform body: () throws -> Void
    ) rethrows {
        let previous = LingroveCompatibility.processEnvironment[key]
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        try body()
    }

    // MARK: - Debug gate

    func test_launchArgument_matchesDocumentedFlag() {
        XCTAssertEqual(LingroveDebugOptions.launchArgument, "-lingrove-debug")
    }

    func test_areOverlaysAvailable_isCompiledInOnlyForDebugBuilds() {
        // The test bundle is compiled in the same configuration as its host app.
        #if DEBUG
        XCTAssertTrue(LingroveDebugOptions.areOverlaysAvailable)
        #else
        XCTAssertFalse(LingroveDebugOptions.areOverlaysAvailable)
        #endif
    }

    func test_log_staysQuietWhenDebugModeIsOff() throws {
        try XCTSkipIf(LingroveDebugOptions.isEnabled, "Runner was launched with -lingrove-debug")

        // The guard is the privacy gate: without the explicit launch argument this must be a
        // no-op rather than writing diagnostics anywhere.
        LingroveDebugOptions.log("coverage probe, should never be emitted")
    }

    // MARK: - Verbosity floor precedence

    func test_minimumLogLevel_honorsEveryRecognizedOverrideCaseInsensitively() {
        let cases: [(raw: String, expected: String)] = [
            ("trace", "trace"),
            ("debug", "debug"),
            ("info", "info"),
            ("notice", "notice"),
            ("warning", "warning"),
            ("error", "error"),
            ("critical", "critical"),
            ("WARNING", "warning"),
            ("Debug", "debug")
        ]
        for testCase in cases {
            withEnvironmentValue(Self.levelKey, testCase.raw) {
                XCTAssertEqual(
                    LingroveDebugOptions.minimumLogLevel.rawValue,
                    testCase.expected,
                    "LINGROVE_LOG_LEVEL=\(testCase.raw)"
                )
            }
        }
    }

    func test_minimumLogLevel_ignoresUnrecognizedOverride() {
        // A bogus override must fall back to the launch-argument default, not crash or stick.
        // Whitespace is not trimmed, so a padded value is also unrecognized.
        let fallback = LingroveDebugOptions.isEnabled ? "trace" : "info"
        for raw in ["chatty", "", " warning", "warn"] {
            withEnvironmentValue(Self.levelKey, raw) {
                XCTAssertEqual(
                    LingroveDebugOptions.minimumLogLevel.rawValue,
                    fallback,
                    "LINGROVE_LOG_LEVEL=\"\(raw)\""
                )
            }
        }
    }

    func test_minimumLogLevel_defaultsToInfo() throws {
        try withEnvironmentValue(Self.levelKey, nil) {
            try XCTSkipIf(LingroveDebugOptions.isEnabled, "Runner was launched with -lingrove-debug")
            XCTAssertEqual(LingroveDebugOptions.minimumLogLevel.rawValue, "info")
        }
    }

    // MARK: - Logger plumbing

    func test_llmIOLabel_isTheReservedRoutingContract() {
        // FileLogHandler routing and the jq-based debugging workflow both key off this label.
        XCTAssertEqual(LingroveLogger.llmIOLabel, "io.ichthyoplanktonzyh.lingrove.llm-io")
    }

    func test_bootstrap_isIdempotent() {
        // The host app already bootstrapped logging at launch; repeated calls must be safe no-ops
        // (LoggingSystem traps on a second real bootstrap, so this locks the once-only guard).
        LingroveLogger.bootstrap()
        LingroveLogger.bootstrap()
    }

    // MARK: - OSLogHandler

    func test_osLogHandler_defaultFloorTracksGlobalConfiguration() {
        let handler = OSLogHandler(label: "io.ichthyoplanktonzyh.lingrove.test-floor")

        XCTAssertEqual(handler.logLevel.rawValue, LingroveDebugOptions.minimumLogLevel.rawValue)
    }

    func test_osLogHandler_acceptsExplicitFloor() {
        let handler = OSLogHandler(label: "io.ichthyoplanktonzyh.lingrove.test-floor", logLevel: .critical)

        XCTAssertEqual(handler.logLevel.rawValue, "critical")
    }

    func test_osLogHandler_metadataSubscriptReadsAndWrites() {
        var handler = OSLogHandler(label: "io.ichthyoplanktonzyh.lingrove.test-metadata")

        XCTAssertNil(handler[metadataKey: "request_id"])

        handler[metadataKey: "request_id"] = .string("req_test1234")
        XCTAssertEqual(handler[metadataKey: "request_id"], .string("req_test1234"))

        handler[metadataKey: "request_id"] = nil
        XCTAssertNil(handler[metadataKey: "request_id"])
    }

    func test_loggerCopy_canLowerItsOwnFloorWithoutLeakingGlobally() {
        // Logger is a value type: a call site may locally drop the floor to trace and emit at
        // every level (exercising the full OSLog bridge switch) without mutating the shared
        // logger's configuration.
        var logger = LingroveLogger.debug
        logger.logLevel = .trace

        logger.trace("bridge probe: trace")
        logger.debug("bridge probe: debug")
        logger.info("bridge probe: info")
        logger.notice("bridge probe: notice")
        logger.warning("bridge probe: warning")
        logger.error("bridge probe: error")
        logger.critical("bridge probe: critical")

        XCTAssertEqual(logger.logLevel.rawValue, "trace")
        XCTAssertEqual(
            LingroveLogger.debug.logLevel.rawValue,
            LingroveDebugOptions.minimumLogLevel.rawValue,
            "Mutating a copied logger must not change the shared instance's floor"
        )
    }
}
