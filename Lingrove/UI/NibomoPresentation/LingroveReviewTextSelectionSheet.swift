// Native port of Nibomo ReviewCardTextSelectionSheet.swift; Copyright (c) 2026 Kirill Markin (MIT).
// License: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_W3_UI_REUSE_MAP.md.
import AppKit
import SwiftUI

/// A selected face carries its original source into the sheet. The parent owns this transient
/// value; copying/selecting it never mutates a Card or changes the question being answered.
struct LingroveReviewTextSelection: Identifiable {
    let id = UUID()
    let title: String
    let sourceText: String
}

/// Nibomo’s complete-source selection sheet with UITextView mechanically replaced by an
/// AppKit text view. Native text selection retains keyboard copy, including Markdown source.
struct LingroveReviewTextSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: LingroveReviewTextSelection

    var body: some View {
        NavigationStack {
            LingroveReviewSelectableSource(sourceText: selection.sourceText, title: selection.title)
                .navigationTitle(selection.title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done", table: "ReviewCards")) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }.frame(width: 620, height: 460)
    }
}

/// NSViewRepresentable owns only the platform widget. It receives immutable source and title;
/// SwiftUI owns its lifetime, while the shared session continues owning the actual review state.
private struct LingroveReviewSelectableSource: NSViewRepresentable {
    let sourceText: String
    let title: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.isSelectable = true
        text.font = .preferredFont(forTextStyle: .body)
        text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = CGSize(width: 20, height: 20)
        text.string = sourceText
        text.setAccessibilityLabel(title)
        text.setAccessibilityIdentifier("builtinReview.textSelection.source")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        if text.string != sourceText { text.string = sourceText }
        text.setAccessibilityLabel(title)
    }
}
