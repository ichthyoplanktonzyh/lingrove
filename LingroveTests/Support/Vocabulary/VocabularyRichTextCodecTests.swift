import AppKit
import Foundation
import LingroveNotebook
import Testing
import SwiftUI
@testable import Lingrove

@Suite(.serialized)
@MainActor
struct VocabularyRichTextCodecTests {
    @Test func partialMarksUnicodeParagraphsAndImagesRoundTrip() throws {
        let text = "🐈 keep me posted"
        let range = (text as NSString).range(of: "keep")
        let value = VocabularyTextContent(text: text, runs: [.init(location: range.location, length: range.length, bold: true)])
        let image = VocabularyImageReference(digest: String(repeating: "a", count: 64), width: 2, height: 2, byteCount: 24)
        let blocks: [VocabularyContentBlock] = [
            .init(content: .text(value)),
            .init(content: .text(.init(text: "Use with a person", style: .bullet, italic: true))),
            .init(content: .image(image, caption: "Meaning illustration")),
            .init(content: .text(.init(text: "Another paragraph")))
        ]
        let decoded = VocabularyRichTextCodec.blocks(VocabularyRichTextCodec.attributed(blocks, images: [:]))
        #expect(decoded.map(\.id) == blocks.map(\.id))
        #expect(decoded.count == 4)
        guard case .text(let first) = decoded[0].content, case .text(let second) = decoded[1].content else {
            Issue.record("Text paragraphs must survive"); return
        }
        #expect(first == value)
        #expect(second.text == "Use with a person" && second.style == .bullet)
        let allItalic = second.segments.allSatisfy { $0.italic }
        #expect(allItalic)
        #expect(decoded[2].content == .image(image, caption: "Meaning illustration"))
        try VocabularyContentPolicy.validate(decoded)
    }

    @Test func selectionFormattingAndUndoOperateOnOneDocument() throws {
        let model = VocabularyRichTextEditorModel()
        let view = VocabularyRichTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.allowsUndo = true; view.editor = model; model.view = view
        let coordinator = VocabularyRichTextEditor.Coordinator(model: model)
        view.delegate = coordinator
        defer { view.delegate = nil; _ = coordinator }
        let blocks = [VocabularyContentBlock(content: .text(.init(text: "first paragraph"))),
                      VocabularyContentBlock(content: .text(.init(text: "second paragraph")))]
        view.textStorage?.setAttributedString(VocabularyRichTextCodec.attributed(blocks, images: [:]))
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 0, length: 5)); model.selectionChanged()
        let undo = try #require(view.undoManager)
        undo.groupsByEvent = false; undo.beginUndoGrouping()
        model.toggle(.boldFontMask)
        undo.endUndoGrouping()
        #expect(view.string == "first paragraph\nsecond paragraph")
        guard case .text(let formatted) = VocabularyRichTextCodec.blocks(view.attributedString())[0].content else { return }
        #expect(formatted.runs?.first == .init(location: 0, length: 5, bold: true))
        undo.undo()
        guard case .text(let restored) = VocabularyRichTextCodec.blocks(view.attributedString())[0].content else { return }
        #expect(restored.runs == nil)
        #expect(view.string == "first paragraph\nsecond paragraph")
        undo.redo()
        guard case .text(let redone) = VocabularyRichTextCodec.blocks(view.attributedString())[0].content else { return }
        #expect(redone.runs?.first?.bold == true)
    }

    @Test func paragraphFormattingPreservesTheCaretAndAnEmptyBulletCanEnd() {
        let model = VocabularyRichTextEditorModel()
        let view = VocabularyRichTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        model.view = view; view.editor = model
        view.textStorage?.setAttributedString(NSAttributedString(string: "hello", attributes: VocabularyRichTextCodec.defaults()))
        view.setSelectedRange(NSRange(location: 3, length: 0))
        model.setStyle(.bullet)
        #expect(view.string == "• hello")
        #expect(view.selectedRange() == NSRange(location: 5, length: 0))
        model.setStyle(.paragraph)
        #expect(view.string == "hello")
        #expect(view.selectedRange() == NSRange(location: 3, length: 0))
        view.string = ""; view.setSelectedRange(NSRange(location: 0, length: 0))
        model.setStyle(.bullet)
        #expect(view.string == "• ")
        view.insertNewline(nil)
        #expect(view.string.isEmpty && model.style == .paragraph)
    }

    @Test func markedTextPublishesOnlyWhenCompositionCommits() {
        let model = VocabularyRichTextEditorModel()
        let view = VocabularyRichTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        model.view = view; view.editor = model
        view.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        model.changed()
        #expect(model.document.isEmpty)
        view.unmarkText()
        guard case .text(let text) = model.document.first?.content else { Issue.record("Committed composition missing"); return }
        #expect(text.text == "拼音")
    }

    @Test func savedInlineMarksReopenWithTheSameSenseIdentity() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let archive = VocabularyArchive(url: url)
        let original = try await archive.save(.init(expression: "bank", dictionaryForm: "bank", language: .english,
            kind: .word, meaning: "Financial institution")).document.entries[0]
        var draft = original
        draft.senses[0].content = [.init(content: .text(.init(text: "financial institution",
            runs: [.init(location: 0, length: 9, bold: true), .init(location: 10, length: 11, italic: true)])))]
        _ = try await archive.update(draft, basedOn: original)
        let reopened = VocabularyArchive(url: url)
        let saved = try await reopened.load().document.entries[0]
        #expect(saved.id == original.id && saved.senses[0].id == original.senses[0].id)
        #expect(saved.senses[0].content == draft.senses[0].content)
        #expect(saved.senses[0].meaning == original.senses[0].meaning)
    }
    @Test func imageDeletionCanBeUndoneBeforeTheDraftIsSaved() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let prepared = try await store.prepareImage(VocabularyImageTestFixture.png())
        let draft = ImageDraft(blocks: [.init(content: .image(prepared.reference, caption: "Caption"))],
            images: [prepared.reference.filename: prepared.data])
        let host = NSHostingView(rootView: VocabularyContentEditor(
            blocks: Binding(get: { draft.blocks }, set: { draft.blocks = $0 }),
            importedImages: Binding(get: { draft.images }, set: { draft.images = $0 }), store: store,
            importing: Binding(get: { draft.importing }, set: { draft.importing = $0 })))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.orderFrontRegardless()
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
        let view = try #require(textView(in: host))
        window.makeFirstResponder(view)
        let undo = try #require(view.undoManager)
        undo.groupsByEvent = false; undo.beginUndoGrouping()
        view.replace(NSRange(location: 0, length: 1), with: NSAttributedString(string: ""), selection: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(40))
        #expect(draft.blocks.isEmpty)
        #expect(draft.images[prepared.reference.filename] == prepared.data)
        undo.undo()
        #expect(VocabularyContentPolicy.images(draft.blocks) == [prepared.reference])
        #expect(draft.images[prepared.reference.filename] == prepared.data)
    }

    @Test func nativeRichPasteKeepsPartialFormattingInTheValueDraft() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let draft = ImageDraft(blocks: [], images: [:])
        let host = NSHostingView(rootView: VocabularyContentEditor(
            blocks: Binding(get: { draft.blocks }, set: { draft.blocks = $0 }),
            importedImages: Binding(get: { draft.images }, set: { draft.images = $0 }), store: store,
            importing: Binding(get: { draft.importing }, set: { draft.importing = $0 })))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.orderFrontRegardless()
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
        let view = try #require(textView(in: host))
        let text = NSMutableAttributedString(string: "one two", attributes: [.font: VocabularyRichTextCodec.bodyFont])
        text.addAttribute(.font, value: VocabularyRichTextCodec.font(bold: true, italic: true), range: NSRange(location: 4, length: 3))
        let pasteboard = NSPasteboard.withUniqueName()
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        pasteboard.declareTypes([.rtf], owner: nil)
        let published = pasteboard.setData(data, forType: .rtf)
        #expect(published)
        view.importPasteboard(pasteboard)
        for _ in 0..<20 where draft.importing { try await Task.sleep(for: .milliseconds(20)) }
        guard case .text(let value) = draft.blocks.first?.content else { Issue.record("Paste did not publish the draft"); return }
        #expect(value.text == "one two")
        #expect(value.runs == [.init(location: 4, length: 3, bold: true, italic: true)])
        #expect(store.entries.isEmpty)
    }

    private func textView(in view: NSView) -> VocabularyRichTextView? {
        if let value = view as? VocabularyRichTextView { return value }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
    private final class ImageDraft {
        var blocks: [VocabularyContentBlock]
        var images: [String: Data]
        var importing = false
        init(blocks: [VocabularyContentBlock], images: [String: Data]) {
            self.blocks = blocks; self.images = images
        }
    }

}
