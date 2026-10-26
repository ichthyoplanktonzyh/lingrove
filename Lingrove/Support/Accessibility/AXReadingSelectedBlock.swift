import ApplicationServices
import Foundation

/// A bounded fallback for selecting an entire heading/cell when host range APIs are absent.
/// The selection reader owns the receipt and rechecks it afterwards. This adapter borrows only
/// nearby ancestors and small child lists; it never reads a web-area value or searches a page.
@MainActor
enum AXReadingSelectedBlock {
    static func read(on element: AXUIElement, expected: String,
                     deadline: ContinuousClock.Instant) -> LearningReadingWindow? {
        guard ContinuousClock.now < deadline else { return nil }
        var current: AXUIElement? = AXReadingContext.selectedElement(on: element) ?? element
        var remaining = 32
        for _ in 0..<7 {
            guard ContinuousClock.now < deadline, let node = current else { break }
            let role = string(kAXRoleAttribute, on: node, deadline: deadline) ?? ""
            if role == "AXWebArea" || role == "AXWindow" || role == "AXApplication" { break }
            if ["AXHeading", "AXCell", "AXParagraph", "AXListItem", "AXTextArea", "AXTextField"].contains(role),
               let fragments = text(node, depth: 0, remaining: &remaining, deadline: deadline),
               let window = LearningReadingTargetPolicy.selectedBlock(fragments, expected: expected, role: role) {
                LearningReadingLog.emit(.axBlock, "whole-block", details: ["role": role])
                return window
            }
            guard ContinuousClock.now < deadline else { break }
            current = AXHelper.elementValue(for: kAXParentAttribute as CFString, on: node)
        }
        LearningReadingLog.emit(.axBlock, ContinuousClock.now >= deadline ? "deadline-exhausted" : "block-unverified")
        return nil
    }

    /// Preserve the small leaves; the pure policy tests their literal/space-separated forms.
    /// A failed child invalidates the whole block: partial content must never prove whole coverage.
    private static func text(_ node: AXUIElement, depth: Int, remaining: inout Int,
                             deadline: ContinuousClock.Instant) -> [String]? {
        guard remaining > 0, depth <= 3, ContinuousClock.now < deadline else { return nil }
        remaining -= 1
        let role = string(kAXRoleAttribute, on: node, deadline: deadline) ?? ""
        guard ["AXStaticText", "AXLink", "AXGroup", "AXHeading", "AXCell", "AXParagraph", "AXListItem",
               "AXTextArea", "AXTextField"].contains(role) else { return nil }
        guard !SecureFieldDetector.isSecure(role: role,
            subrole: string(kAXSubroleAttribute, on: node, deadline: deadline),
            roleDescription: string(kAXRoleDescriptionAttribute, on: node, deadline: deadline),
            title: string(kAXTitleAttribute, on: node, deadline: deadline),
            descriptionLabel: string(kAXDescriptionAttribute, on: node, deadline: deadline)),
            ContinuousClock.now < deadline else { return nil }
        if ["AXStaticText", "AXTextArea", "AXTextField"].contains(role) {
            return boundedValue(node, deadline: deadline).map { [$0] }
        }
        var count = 0
        let childStatus = AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count)
        if childStatus == .success && count == 0 {
            return boundedValue(node, deadline: deadline).map { [$0] }
        }
        guard childStatus == .success,
              count > 0, count <= remaining, count <= 16, ContinuousClock.now < deadline else { return nil }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, count, &values) == .success,
              let children = values as? [AXUIElement], children.count == count else { return nil }
        var parts: [String] = [], length = 0
        for child in children {
            guard let fragments = text(child, depth: depth + 1, remaining: &remaining, deadline: deadline) else { return nil }
            length += fragments.reduce(0) { $0 + $1.utf16.count + 1 }
            guard length <= LearningReadingContextPolicy.maximumSelectionUTF16 else { return nil }
            parts += fragments
        }
        return parts
    }

    /// Never retrieve an entire field before checking its size. If a host cannot bound the
    /// value, this optional fallback declines rather than pulling a potentially huge document.
    private static func boundedValue(_ node: AXUIElement, deadline: ContinuousClock.Instant) -> String? {
        guard ContinuousClock.now < deadline,
              let count = AXHelper.intValue(for: kAXNumberOfCharactersAttribute as CFString, on: node),
              count > 0, count <= LearningReadingContextPolicy.maximumSelectionUTF16 else {
            LearningReadingLog.emit(.axBlock, "value-size-unverified"); return nil
        }
        guard let value = string(kAXValueAttribute, on: node, deadline: deadline), value.utf16.count == count else { return nil }
        return value
    }

    private static func string(_ attribute: String, on node: AXUIElement, deadline: ContinuousClock.Instant) -> String? {
        guard ContinuousClock.now < deadline else { return nil }
        return AXHelper.stringValue(for: attribute as CFString, on: node)
    }
}
