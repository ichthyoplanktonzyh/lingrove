import AppKit
import LingroveCloud
import LingroveNotebookEngine
import SwiftUI
import Testing
@testable import Lingrove

/// These native component checks render the extracted screens with real app facades and
/// disposable state. These are content/layout artifacts, not mouse-interaction evidence; the
/// separate review journey executes AppKit keyboard routing through the real SQLite writer.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct LingroveReusedPresentationTests {
    @Test func extractedAnswerBarArtifactsAtMinimumWidth() async throws {
        let reveal = NativeReuseHost(LingroveReviewAnswerControls(options: nil,
            onReveal: {}, onRate: { _ in }), width: 760, height: 180)
        defer { reveal.close() }
        try await reveal.settle(); try reveal.capture("extracted-reveal-minimum")
        let options = ReviewRating.allCases.map { LingroveReviewAnswerOption(rating: $0, intervalDescription: "in 1 day") }
        let answer = NativeReuseHost(LingroveReviewAnswerControls(options: options,
            onReveal: {}, onRate: { _ in }), width: 760, height: 180)
        defer { answer.close() }
        try await answer.settle(); try answer.capture("extracted-rating-minimum")
    }

    @Test func upstreamAccountScreensReopenOneChallengeAndVisibleDraftCannotSend() async throws {
        let fixture = try AccountTestFixture(); defer { fixture.cleanup() }
        fixture.configure()
        let server = NativeReuseHost(LingroveAccountServerView(account: fixture.service,
            api: .constant("https://draft.example.invalid/v1"), auth: .constant("https://draft.example.invalid/auth")),
            width: 720, height: 650)
        defer { server.close() }
        try await server.settle(); try server.capture("extracted-server-draft")
        #expect(fixture.client.sends == 0 && fixture.client.identities == 0)
        let blocked = NativeReuseHost(LingroveAccountSignInSheet(account: fixture.service, connectionIsSaved: false),
            width: 560, height: 480)
        defer { blocked.close() }
        try await blocked.settle(); try blocked.capture("extracted-email-blocked")
        #expect(fixture.client.sends == 0)
        fixture.service.requestCode(email: "synthetic@example.invalid")
        try await accountEventually { fixture.service.state == .awaitingCode }
        let first = NativeReuseHost(LingroveAccountSignInSheet(account: fixture.service, connectionIsSaved: true),
            width: 560, height: 480)
        try await first.settle(); try first.capture("extracted-otp")
        first.close()
        let reopened = NativeReuseHost(LingroveAccountSignInSheet(account: fixture.service, connectionIsSaved: true),
            width: 560, height: 480)
        defer { reopened.close() }
        try await reopened.settle(); try reopened.capture("extracted-otp-reopened")
        #expect(fixture.client.sends == 1 && fixture.client.refreshes == 0 && fixture.service.codePrompt != nil)
    }

    @Test func workspaceChooserAndLaneFormUseTheSameLiveController() async throws {
        let fixture = try MacNotebookSyncFixture(); defer { fixture.cleanup() }
        try fixture.saveLocal()
        fixture.start(); try await fixture.signIn()
        let chooser = NativeReuseHost(LingroveAccountWorkspaceSelectionSheet(controller: fixture.sync), width: 560, height: 440)
        defer { chooser.close() }
        try await chooser.settle(); try chooser.capture("extracted-workspace-chooser")
        #expect(fixture.sync.selectedWorkspace == nil && !fixture.sync.enabled)
        try await fixture.connect()
        let form = NativeReuseHost(Form { AccountNotebookSyncSection(controller: fixture.sync) }.formStyle(.grouped),
            width: 720, height: 760)
        defer { form.close() }
        try await form.settle(); try form.capture("extracted-sync-ownership")
        #expect(fixture.sync.ownershipProposal?.status == "pending" && !fixture.sync.enabled)
        fixture.sync.resolveLocalCorpus(accept: false, expected: fixture.sync.ownershipProposal)
        try await form.settle(); try form.capture("extracted-sync-ready")
        #expect(!fixture.sync.enabled)
    }
}

/// One test owns an ordinary offscreen AppKit host and captures only its own rendered bounds.
/// Glass uses the window compositor, so cached images do not establish its onscreen appearance.
@MainActor
private final class NativeReuseHost<Content: View> {
    let view: NSHostingView<AnyView>
    let window: NSWindow

    init(_ content: Content, width: CGFloat, height: CGFloat) {
        view = NSHostingView(rootView: AnyView(content.preferredColorScheme(.dark).tint(.orange)))
        window = NSWindow(contentRect: .init(x: -3000, y: -3000, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFrontRegardless()
    }
    func close() { window.contentView = nil; window.close() }
    func settle() async throws {
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
    }
    func capture(_ name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["LINGROVE_REVIEW_EVIDENCE_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1_000)
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
