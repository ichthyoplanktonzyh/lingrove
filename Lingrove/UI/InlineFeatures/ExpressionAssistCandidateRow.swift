import AppKit

/// A candidate row is one native button for insertion, with optional trailing icon buttons for
/// read-aloud and vocabulary collection. The panel owns selection and callbacks; this row owns
/// text measurement, visual hierarchy, and hit-testing between the row body and its action icons.
///
/// Visual hierarchy, top to bottom:
/// 1. The insertable target expression (primary, 14pt medium) with its selection indicator (`↵` or
///    1-based index) on the leading edge and optional speech/favorite icons on the trailing edge.
/// 2. The reusable dictionary base form when it differs from the inflected surface text.
/// 3. The concise meaning or usage hint in the user's explanation language, always visible so the
///    writer can choose confidently without an extra expand keystroke.
@MainActor
final class ExpressionAssistCandidateRow: NSButton {
    private typealias Metrics = ExpressionAssistLayout.Metrics

    private let main: NSTextField
    private let form: NSTextField
    private let hint: NSTextField
    private let arrow: NSTextField
    private var speakButton: NSButton?
    private var favoriteButton: NSButton?
    private let showsHint: Bool
    private let showsForm: Bool
    private let showsSelection: Bool
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var onSpeak: (() -> Void)?
    private var onToggleFavorite: (() -> Void)?
    override var isFlipped: Bool { true }

    init(
        candidate: ExpressionAssistCandidate,
        index: Int = 0,
        selected: Bool,
        expanded: Bool = true,
        isSpeaking: Bool = false,
        onSpeak: (() -> Void)? = nil,
        isSaved: Bool = false,
        isSaving: Bool = false,
        onToggleFavorite: (() -> Void)? = nil
    ) {
        main = NSTextField(wrappingLabelWithString: candidate.text)
        let dictionaryForm = candidate.dictionaryForm?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        showsForm = !dictionaryForm.isEmpty &&
            dictionaryForm.caseInsensitiveCompare(candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
        form = NSTextField(wrappingLabelWithString: showsForm
            ? String(localized: "Base form: \(dictionaryForm)", table: "Learning") : "")
        let trimmedHint = candidate.hint.trimmingCharacters(in: .whitespacesAndNewlines)
        hint = NSTextField(wrappingLabelWithString: trimmedHint)
        arrow = NSTextField(labelWithString: selected ? "↵" : "\(index + 1)")
        showsHint = !trimmedHint.isEmpty
        showsSelection = selected
        self.onSpeak = onSpeak
        self.onToggleFavorite = onToggleFavorite
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        main.font = .systemFont(ofSize: 14, weight: .medium)
        form.font = .systemFont(ofSize: 11, weight: .medium)
        hint.font = .systemFont(ofSize: 12)
        arrow.font = .monospacedDigitSystemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        arrow.alignment = .center
        // Selected rows invert every label so contrast holds on any accent color (incl. graphite).
        main.textColor = showsSelection ? .alternateSelectedControlTextColor : .labelColor
        form.textColor = showsSelection ? .alternateSelectedControlTextColor.withAlphaComponent(0.88) : .secondaryLabelColor
        hint.textColor = showsSelection ? .alternateSelectedControlTextColor.withAlphaComponent(0.85) : .secondaryLabelColor
        arrow.textColor = showsSelection ? .alternateSelectedControlTextColor : .tertiaryLabelColor
        [main, form, hint, arrow].forEach(addSubview)
        form.isHidden = !showsForm
        hint.isHidden = !showsHint

        if onSpeak != nil {
            let button = makeActionButton(
                symbol: isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2",
                assetName: nil,
                active: isSpeaking,
                selected: showsSelection,
                tooltip: isSpeaking
                    ? String(localized: "Stop speaking expression", table: "Learning")
                    : String(localized: "Play expression aloud", table: "Learning"),
                action: #selector(handleSpeak)
            )
            addSubview(button)
            speakButton = button
        }

        if onToggleFavorite != nil {
            let button = makeActionButton(
                symbol: isSaving ? "ellipsis" : nil,
                assetName: isSaving ? nil : (isSaved ? "FavoriteFishFilled" : "FavoriteFishOutline"),
                active: isSaved,
                selected: showsSelection,
                tooltip: isSaved
                    ? String(localized: "Remove this saved usage", table: "Vocabulary")
                    : String(localized: "Save to vocabulary", table: "Vocabulary"),
                action: #selector(handleFavorite)
            )
            button.isEnabled = !isSaving
            addSubview(button)
            favoriteButton = button
        }

        wantsLayer = true
        layer?.cornerRadius = Metrics.rowCornerRadius
        layer?.cornerCurve = .continuous
        updateBackground()
        // VoiceOver reads only parts that exist, so an empty hint no longer produces a dangling ". ".
        let spoken = [candidate.text, showsForm ? form.stringValue : "", trimmedHint]
            .filter { !$0.isEmpty }.joined(separator: ". ")
        setAccessibilityLabel(spoken)
    }

    required init?(coder: NSCoder) { nil }

    func height(for width: CGFloat) -> CGFloat {
        let mainAvailable = mainTextWidth(for: width)
        let subAvailable = bodyTextWidth(for: width)
        var height = Metrics.rowVerticalPadding * 2 + textHeight(main, width: mainAvailable)
        if showsForm { height += 2 + textHeight(form, width: subAvailable) }
        if showsHint { height += 3 + textHeight(hint, width: subAvailable) }
        return max(height, Metrics.rowVerticalPadding * 2 + Metrics.rowActionSize)
    }

    override func layout() {
        super.layout()
        let mainWidth = mainTextWidth(for: bounds.width)
        let subWidth = bodyTextWidth(for: bounds.width)
        let left = Metrics.rowLeading
        arrow.frame = CGRect(x: 4, y: Metrics.rowVerticalPadding + 1, width: 15, height: 18)
        main.frame = CGRect(x: left, y: Metrics.rowVerticalPadding, width: mainWidth, height: textHeight(main, width: mainWidth))

        var actionRight = bounds.width - Metrics.rowTrailing
        let actionSize = Metrics.rowActionSize
        if let favoriteButton {
            favoriteButton.frame = CGRect(
                x: actionRight - actionSize,
                y: Metrics.rowVerticalPadding - 1,
                width: actionSize,
                height: actionSize
            )
            actionRight = favoriteButton.frame.minX - Metrics.rowActionSpacing
        }
        if let speakButton {
            speakButton.frame = CGRect(
                x: actionRight - actionSize,
                y: Metrics.rowVerticalPadding - 1,
                width: actionSize,
                height: actionSize
            )
        }

        var next = main.frame.maxY
        if showsForm {
            form.frame = CGRect(x: left, y: next + 2, width: subWidth, height: textHeight(form, width: subWidth))
            next = form.frame.maxY
        }
        if showsHint {
            hint.frame = CGRect(x: left, y: next + 3, width: subWidth, height: textHeight(hint, width: subWidth))
        }
    }

    // MARK: Hover & Actions

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
            : (hovering ? .labelColor.withAlphaComponent(0.065) : nil)
        layer?.backgroundColor = color?.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let favoriteButton, !favoriteButton.isHidden, favoriteButton.frame.contains(local) {
            return favoriteButton
        }
        if let speakButton, !speakButton.isHidden, speakButton.frame.contains(local) {
            return speakButton
        }
        return self
    }

    @objc private func handleSpeak() { onSpeak?() }
    @objc private func handleFavorite() { onToggleFavorite?() }

    private func makeActionButton(
        symbol: String?,
        assetName: String?,
        active: Bool,
        selected: Bool,
        tooltip: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.title = ""
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        if let symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.image = image
            button.symbolConfiguration = .init(pointSize: 11.5, weight: .medium)
        } else if let assetName, let image = NSImage(named: assetName) {
            image.isTemplate = true
            image.size = NSSize(width: 13, height: 13)
            button.image = image
        }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        if selected {
            button.contentTintColor = .alternateSelectedControlTextColor.withAlphaComponent(active ? 1.0 : 0.82)
        } else {
            button.contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
        }
        return button
    }

    private var actionClusterWidth: CGFloat {
        let count = (speakButton != nil ? 1 : 0) + (favoriteButton != nil ? 1 : 0)
        guard count > 0 else { return 0 }
        return CGFloat(count) * Metrics.rowActionSize + CGFloat(count - 1) * Metrics.rowActionSpacing + 6
    }

    private func mainTextWidth(for width: CGFloat) -> CGFloat {
        max(40, width - Metrics.rowLeading - Metrics.rowTrailing - actionClusterWidth)
    }

    private func bodyTextWidth(for width: CGFloat) -> CGFloat {
        max(40, width - Metrics.rowLeading - Metrics.rowTrailing)
    }

    private func textHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
        let font = field.font ?? .systemFont(ofSize: 14)
        return ceil((field.stringValue as NSString).boundingRect(with: CGSize(width: width, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height) + 2
    }
}
