import AppKit

/// A display-only candidate is still one native button, so clicking either its text or hint commits
/// the same choice. The panel owns selection and callbacks; this row owns only text layout and its
/// own visual states (selected, hovered).
///
/// Visual hierarchy, top to bottom: the insertable text (primary), the dictionary form when it
/// differs from the inflected text (the reusable expression worth learning), then the hint.
/// In the expanded list the selected row uses the system selection treatment (accent fill,
/// inverted text) so keyboard position is unmistakable; the quiet single-row mode keeps only the
/// ↵ marker to stay close to the host's own text.
@MainActor
final class ExpressionAssistCandidateRow: NSButton {
    private typealias Metrics = ExpressionAssistLayout.Metrics

    private let main: NSTextField
    private let form: NSTextField
    private let hint: NSTextField
    private let arrow: NSTextField
    private let showsHint: Bool
    private let showsForm: Bool
    /// Only the expanded list highlights; a quiet row has no background to avoid a "second field".
    private let showsSelection: Bool
    private let expanded: Bool
    private var hovering = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }

    init(candidate: ExpressionAssistCandidate, selected: Bool, expanded: Bool) {
        main = NSTextField(wrappingLabelWithString: candidate.text)
        let dictionaryForm = candidate.dictionaryForm?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        showsForm = expanded && !dictionaryForm.isEmpty &&
            dictionaryForm.caseInsensitiveCompare(candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
        form = NSTextField(wrappingLabelWithString: showsForm
            ? String(localized: "Base form: \(dictionaryForm)", table: "Learning") : "")
        hint = NSTextField(wrappingLabelWithString: candidate.hint)
        arrow = NSTextField(labelWithString: selected ? "↵" : "")
        showsHint = expanded && !candidate.hint.isEmpty
        showsSelection = expanded && selected
        self.expanded = expanded
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        main.font = .systemFont(ofSize: 14)
        form.font = .systemFont(ofSize: 11, weight: .medium)
        hint.font = .systemFont(ofSize: 12)
        arrow.font = .systemFont(ofSize: 11)
        // Selected rows invert every label so contrast holds on any accent color (incl. graphite).
        main.textColor = showsSelection ? .alternateSelectedControlTextColor : .labelColor
        form.textColor = showsSelection ? .alternateSelectedControlTextColor.withAlphaComponent(0.85) : .secondaryLabelColor
        hint.textColor = showsSelection ? .alternateSelectedControlTextColor.withAlphaComponent(0.85) : .secondaryLabelColor
        arrow.textColor = showsSelection ? .alternateSelectedControlTextColor : .secondaryLabelColor
        [main, form, hint, arrow].forEach(addSubview)
        form.isHidden = !showsForm
        hint.isHidden = !showsHint
        wantsLayer = true
        layer?.cornerRadius = Metrics.rowCornerRadius
        updateBackground()
        // VoiceOver reads only parts that exist, so an empty hint no longer produces a dangling ". ".
        let spoken = [candidate.text, showsForm ? form.stringValue : "", candidate.hint]
            .filter { !$0.isEmpty }.joined(separator: ". ")
        setAccessibilityLabel(spoken)
    }

    required init?(coder: NSCoder) { nil }

    func height(for width: CGFloat) -> CGFloat {
        let available = textWidth(for: width)
        var height = Metrics.rowVerticalPadding * 2 + textHeight(main, width: available)
        if showsForm { height += 2 + textHeight(form, width: available) }
        if showsHint { height += 4 + textHeight(hint, width: available) }
        return height
    }

    override func layout() {
        super.layout()
        let width = textWidth(for: bounds.width)
        let left = Metrics.rowLeading
        arrow.frame = CGRect(x: 3, y: Metrics.rowVerticalPadding + 1, width: 14, height: 18)
        main.frame = CGRect(x: left, y: Metrics.rowVerticalPadding, width: width, height: textHeight(main, width: width))
        var next = main.frame.maxY
        if showsForm {
            form.frame = CGRect(x: left, y: next + 2, width: width, height: textHeight(form, width: width))
            next = form.frame.maxY
        }
        hint.frame = CGRect(x: left, y: next + 4, width: width, height: textHeight(hint, width: width))
    }

    // MARK: Hover

    /// AppKit tracking areas are tied to the current bounds, so they are rebuilt whenever the row
    /// is resized. `.activeAlways` matters: the candidate panel is non-key and never becomes active.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateBackground() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateBackground() }

    private func updateBackground() {
        let color: NSColor? = showsSelection ? .controlAccentColor
            : (hovering && expanded ? .quaternaryLabelColor : nil)
        layer?.backgroundColor = color?.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

    private func textWidth(for width: CGFloat) -> CGFloat {
        max(40, width - Metrics.rowLeading - Metrics.rowTrailing)
    }

    private func textHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
        let font = field.font ?? .systemFont(ofSize: 14)
        return ceil((field.stringValue as NSString).boundingRect(with: CGSize(width: width, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height) + 2
    }
}
