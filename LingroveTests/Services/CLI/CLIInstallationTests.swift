import Foundation
import LingroveNotebook
import Testing
@testable import Lingrove

/// Synthetic bundles and PATH entries exercise updates without touching the installed app,
/// the user's command directory, or a notebook. The installer alone owns these link changes.
struct CLIInstallationTests {
    private func helper(in root: URL, name: String, identifier: String) throws -> URL {
        let app = root.appendingPathComponent(name + ".app")
        let tool = app.appendingPathComponent("Contents/Helpers/lingrove")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    @Test func updatesPreviousProductLinkAndSupportsRelativeTargets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = "io.ichthyoplanktonzyh.lingrove.dev"
        _ = try helper(in: root, name: "Old", identifier: identifier)
        let next = try helper(in: root, name: "New", identifier: identifier)
        let link = root.appendingPathComponent("lingrove-dev")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Old.app/Contents/Helpers/lingrove")
        let installer = CLIInstallation(executable: next, destination: link)
        #expect(await installer.isInstalled() == false)
        try await installer.install()
        #expect(await installer.isInstalled())
        try await installer.install()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == next.path)
    }

    @Test(arguments: ["file", "unrelated", "production", "broken"])
    func preservesOtherCommands(_ kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let next = try helper(in: root, name: "Dev", identifier: "io.ichthyoplanktonzyh.lingrove.dev")
        let link = root.appendingPathComponent("lingrove-dev")
        if kind == "file" {
            try Data("user script".utf8).write(to: link)
        } else {
            let target: String
            if kind == "broken" { target = "missing/lingrove" } else {
                let identifier = kind == "production" ? "io.ichthyoplanktonzyh.lingrove" : "org.unrelated.tool"
                target = try helper(in: root, name: "Other", identifier: identifier).path
            }
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
        let before = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        let installer = CLIInstallation(executable: next, destination: link)
        await #expect(throws: CLIError.self) { try await installer.install() }
        if kind == "file" { #expect(try String(contentsOf: link, encoding: .utf8) == "user script") }
        else { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == before) }
    }
}
