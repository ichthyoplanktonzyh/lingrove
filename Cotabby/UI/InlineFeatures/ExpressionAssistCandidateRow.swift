import AppKit

/// A display-only candidate is still one native button, so clicking either its text or hint commits
/// the same choice. The panel owns selection and callbacks; this row owns only text layout.
@MainActor
final class ExpressionAssistCandidateRow: NSButton {
    private let main: NSTextField
    private let hint: NSTextField
    private let arrow: NSTextField
    private let showsHint: Bool
    override var isFlipped: Bool { true }

    init(candidate: ExpressionAssistCandidate, selected: Bool, expanded: Bool) {
        main = NSTextField(wrappingLabelWithString: candidate.text)
        hint = NSTextField(wrappingLabelWithString: candidate.hint)
        arrow = NSTextField(labelWithString: selected ? "↵" : "")
        showsHint = expanded && !candidate.hint.isEmpty
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        main.font = .systemFont(ofSize: 14)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        arrow.font = .systemFont(ofSize: 11)
        arrow.textColor = .secondaryLabelColor
        addSubview(main)
        addSubview(hint)
        addSubview(arrow)
        hint.isHidden = !showsHint
        wantsLayer = true
        layer?.cornerRadius = 5
        if expanded && selected { layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor }
        setAccessibilityLabel(candidate.text + ". " + candidate.hint)
    }

    required init?(coder: NSCoder) { nil }

    func height(for width: CGFloat) -> CGFloat {
        let available = max(40, width - 28)
        return 10 + textHeight(main, width: available) + (showsHint ? 4 + textHeight(hint, width: available) : 0)
    }

    override func layout() {
        super.layout()
        let width = max(40, bounds.width - 28)
        let mainHeight = textHeight(main, width: width)
        arrow.frame = CGRect(x: 3, y: 6, width: 14, height: 18)
        main.frame = CGRect(x: 21, y: 5, width: width, height: mainHeight)
        hint.frame = CGRect(x: 21, y: main.frame.maxY + 4, width: width, height: textHeight(hint, width: width))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

    private func textHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
        let font = field.font ?? .systemFont(ofSize: 14)
        return ceil((field.stringValue as NSString).boundingRect(with: CGSize(width: width, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height) + 2
    }
}
