import Darwin
import Foundation
import Testing
@testable import Lingrove

struct SystemDictionaryArticleServiceTests {
    @Test func languageArgumentsAndSuccessfulMissRemainDistinctFromHelperFailure() async throws {
        let file = try helper("printf '{\"html\":\"\",\"text\":\"%s/%s\",\"sourceName\":\"Fixture\",' \"$2\" \"$3\"\nprintf '\"entryLanguage\":\"%s\",\"definitionLanguage\":\"%s\"}' \"$2\" \"$3\"\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let article = try #require(try await SystemDictionaryArticleService(executable: file)
            .lookup("bonjour", language: .french, definitionLanguage: .chinese))
        #expect(article.text == "fr/zh-Hans")
        #expect(article.languages == .init(entry: .french, definition: .chinese))
        let miss = try helper("printf '{\"html\":\"\",\"text\":\"\",\"sourceName\":\"\"}'\n")
        defer { try? FileManager.default.removeItem(at: miss) }
        let result = try #require(try await SystemDictionaryArticleService(executable: miss).lookup("chat", language: .french))
        #expect(result.text.isEmpty && result.html.isEmpty)
    }

    private func helper(_ body: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(("#!/bin/sh\n" + body).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    @Test func hardTimeoutStopsAHelperIgnoringSIGTERM() async throws {
        // A shell builtin loop creates no descendants that could outlive this test.
        let file = try helper("printf '%s' $$ > \"$1\"\ntrap '' TERM\nwhile :; do :; done\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let pidFile = file.appendingPathExtension("pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let service = SystemDictionaryArticleService(executable: file)
        let start = ContinuousClock.now
        #expect(try await service.lookup(pidFile.path) == nil)
        #expect(start.duration(to: .now) < .seconds(4))
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "Timed-out helper must have exited")
    }

    @Test func cancellationAndOversizeOutputReturnPromptly() async throws {
        let file = try helper("printf '%s' $$ > \"$1\"\ntrap '' TERM\nwhile :; do :; done\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let cancelPIDFile = file.appendingPathExtension("pid")
        defer { try? FileManager.default.removeItem(at: cancelPIDFile) }
        let service = SystemDictionaryArticleService(executable: file)
        let work = Task { try await service.lookup(cancelPIDFile.path) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: cancelPIDFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancelPID = try #require(Int32(String(contentsOf: cancelPIDFile, encoding: .utf8)))
        let start = ContinuousClock.now
        work.cancel()
        do { _ = try await work.value; Issue.record("Cancellation must be propagated") } catch is CancellationError {} catch { Issue.record(error) }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(kill(cancelPID, 0) == -1 && errno == ESRCH)
        let output = try helper("printf '%s' $$ > \"$1\"\nwhile :; do printf '0123456789012345678901234567890123456789012345678901234567890123456789'; done\n")
        defer { try? FileManager.default.removeItem(at: output) }
        let pidFile = output.appendingPathExtension("pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        #expect(try await SystemDictionaryArticleService(executable: output).lookup(pidFile.path) == nil)
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "Oversized-output helper must have exited")
    }
}
