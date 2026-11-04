import AppKit
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI
import Testing
@testable import Lingrove

/// A synthetic repository and private windows exercise the new note path without opening the
/// installed Dev application or borrowing its settings, corpus or account connection.
@Suite(.serialized) @MainActor
struct ReviewNoteNativeTests {
    @Test func corpusAdmissionKeepsReviewClosedAndPersistsANote() async throws {
        let fixture = try ReviewNativePresentationFixture()
        defer { fixture.cleanUp() }
        #expect(await fixture.session.enrollFromCorpus(fixture.selection) == nil)
        #expect(fixture.session.content == nil && fixture.session.practice == nil)
        let stored = try fixture.review()
        #expect(stored.noteCards.count == 1 && stored.statistics.exercises == 1)
        #expect(stored.noteCards.values.first?.note.senseID == fixture.selection.senseID)
        #expect(await fixture.session.enrollFromCorpus(fixture.selection) == nil)
        #expect(try fixture.review().statistics.exercises == 1)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func noteRendererEditorAndRating(_ appearance: NSAppearance.Name) async throws {
        let fixture = try ReviewNativePresentationFixture()
        defer { fixture.cleanUp() }
        let session = fixture.session
        #expect(await session.enrollFromCorpus(fixture.selection) == nil)
        session.open(selection: nil)
        await session.waitForIdle()
        let host = ReviewNativePresentationHost(BuiltInReviewWindowView(session: session),
            appearance: appearance, size: .init(width: 1040, height: 760))
        defer { host.close() }
        session.start()
        await session.waitForIdle()
        try await host.settle()
        try await Task.sleep(for: .milliseconds(700))
        try host.capture("note-question")
        session.reveal()
        try await host.settle()
        try await Task.sleep(for: .milliseconds(400))
        try host.capture("note-answer")
        session.editNoteType()
        try await host.settle()
        let sheet = try #require(host.window.sheets.first)
        try host.capture("note-type-editor", window: sheet)
        var draft = try #require(session.noteTypeDraft)
        draft.type.css += "\n.expression{font-size:44px}"
        session.saveNoteType(draft)
        await session.waitForIdle()
        #expect(session.noteTypeDraft == nil)
        #expect(session.practice?.answered == 0)
        #expect(session.content?.noteCards.values.first?.noteType.css.contains("44px") == true)
        session.reveal()
        session.rate(.good)
        await session.waitForIdle()
        #expect(try fixture.review().statistics.ratingRecords == 1)
        #expect(session.practice?.answered == 1)
    }
}
