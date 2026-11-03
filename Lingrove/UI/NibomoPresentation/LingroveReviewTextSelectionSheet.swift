// Native port of Nibomo ReviewCardTextSelectionSheet.swift; Copyright (c) 2026 Kirill Markin (MIT).
// License: Lingrove/Resources/NibomoUI-LICENSE.txt. See docs/MAC_REVIEW_ACCOUNT_UI_REUSE.md.
import AppKit
import SwiftUI

/// A selected face carries its original source into the sheet. The parent owns this transient
/// value; copying/selecting it never mutates a Card or changes the question being answered.
struct LingroveReviewTextSelection: Identifiable {
    let id = UUID()
    let title: String
    let sourceText: String
}

/// Complete-source selection borrows the selected face's immutable source. The native text
/// view inherits its sheet's appearance and retains standard selection and keyboard copying,
/// including Markdown source; it does not create another editable material draft.
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
                            .accessibilityIdentifier("builtinReview.textSelection.done")
                    }
                }
        }.frame(minWidth: 540, idealWidth: 620, minHeight: 360, idealHeight: 460)
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
