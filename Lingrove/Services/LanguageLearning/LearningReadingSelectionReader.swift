import AppKit
import ApplicationServices
import Foundation

/// AX read boundary for reading selections, deliberately separate from LearningSelectionReplacement.
/// It probes only focused/hit-tested ancestors, never walks a page. A receipt is kept only while
/// the app-owned reading coordinator owns that session; no text is persisted here.
@MainActor
final class LearningReadingSelectionReader: LearningReadingSelecting {
    /// Native handles stay at the AX boundary. Only this receipt's observer and focus/window
    /// evidence survive a model await; forget() ends their ownership with the reading session.
    private struct Evidence {
        let receipt: LearningReadingSelection
        let element: AXUIElement
        let window: AXUIElement?
        let range: NSRange?
        let focusedElement: AXUIElement?
    }
    private var evidence: Evidence?
    private var observer: AXObserver?
    private var invalidationHandler: (@MainActor () -> Void)?

    func setInvalidationHandler(_ handler: (@MainActor () -> Void)?) { invalidationHandler = handler }

    func forget() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        evidence = nil
    }

    func capture() async throws -> LearningReadingSelection {
        forget()
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
            let bundle = app.bundleIdentifier, app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            throw LearningFailure.message(String(localized: "Selection is unavailable in this app.", table: "Learning"))
        }
        let roots = [
            AXHelper.focusedElement(forApplicationPID: app.processIdentifier),
            AXHelper.element(atCocoaPoint: NSEvent.mouseLocation)
        ].compactMap { $0 }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        for root in roots {
            var candidate: AXUIElement? = root
            for _ in 0..<7 {
                guard ContinuousClock.now < deadline, let element = candidate,
                    AXHelper.owningApplication(of: element)?.processIdentifier == app.processIdentifier
                else { break }
                guard !sensitive(element) else {
                    throw LearningFailure.message(String(localized: "Sensitive fields cannot be translated.", table: "Learning"))
                }
                if let text = AXHelper.selectedReadingText(on: element), !text.isEmpty {
                    return try save(text, element: element, app: app, bundle: bundle)
                }
                candidate = AXHelper.elementValue(for: kAXParentAttribute as CFString, on: element)
            }
        }
        // No copy fallback: a fresh pasteboard count cannot prove ownership when the user or
        // another app copies concurrently. An unavailable AX selection remains unavailable.
        throw LearningFailure.message(String(localized: "This app did not provide selected text.", table: "Learning"))
    }

    func isCurrent(_ capture: LearningReadingSelection) -> Bool {
        guard let evidence, evidence.receipt.id == capture.id,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == capture.processIdentifier,
            !sensitive(evidence.element)
        else { return false }
        let focusedElement = AXHelper.focusedElement(forApplicationPID: capture.processIdentifier)
        if let previous = evidence.focusedElement {
            guard let focusedElement, CFEqual(previous, focusedElement) else { return false }
        } else if focusedElement != nil {
            return false
        }
        let window = AXHelper.elementValue(for: kAXWindowAttribute as CFString, on: evidence.element)
        if let previous = evidence.window {
            guard let window, CFEqual(previous, window),
                let focused = AXHelper.elementValue(
                    for: kAXFocusedWindowAttribute as CFString,
                    on: AXUIElementCreateApplication(capture.processIdentifier)),
                CFEqual(previous, focused)
            else { return false }
        }
        let range = AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: evidence.element)
        guard range == evidence.range else { return false }
        if let text = AXHelper.selectedReadingText(on: evidence.element) { return text == capture.text }
        return false
    }

    private func save(_ text: String, element: AXUIElement, app: NSRunningApplication, bundle: String) throws -> LearningReadingSelection {
        try LearningReadingPolicy.validate(text)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw CancellationError() }
        let window = AXHelper.elementValue(for: kAXWindowAttribute as CFString, on: element)
        if let window,
            let focused = AXHelper.elementValue(
                for: kAXFocusedWindowAttribute as CFString,
                on: AXUIElementCreateApplication(app.processIdentifier)),
            !CFEqual(window, focused) {
            throw CancellationError()
        }
        let range = AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element)
        let bounds = range.flatMap {
            AXHelper.parameterizedRectValue(for: kAXBoundsForRangeParameterizedAttribute as CFString, range: $0, on: element)
        }
        let rect =
            bounds.flatMap { value -> CGRect? in
                guard value.width.isFinite, value.height.isFinite, value.minX.isFinite, value.minY.isFinite,
                    value.height > 0, value.width > 0
                else { return nil }
                return AXHelper.cocoaRect(fromAccessibilityRect: value)
            } ?? CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 18))
        let context = LearningVocabularyContextReader.read(element: element, range: range, expected: text, app: bundle)
        let receipt = LearningReadingSelection(
            id: UUID(), text: text, processIdentifier: app.processIdentifier,
            bundleIdentifier: bundle, anchor: rect, vocabularyContext: context)
        evidence = Evidence(
            receipt: receipt, element: element, window: window,
            range: range, focusedElement: AXHelper.focusedElement(forApplicationPID: app.processIdentifier))
        observeSelection(element, pid: app.processIdentifier)
        return receipt
    }

    /// Notifications cover selection/value changes without polling an idle app. The run-loop
    /// source lives on the main thread; forget() removes it before the unretained context can die.
    /// Hosts may decline a notification, so key/mouse/app lifecycle guards remain necessary too.
    private func observeSelection(_ element: AXUIElement, pid: Int32) {
        var result: AXObserver?
        guard
            AXObserverCreate(
                pid,
                { _, _, _, context in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        let owner = Unmanaged<LearningReadingSelectionReader>.fromOpaque(context).takeUnretainedValue()
                        owner.invalidationHandler?()
                    }
                }, &result) == .success, let result
        else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(result, element, kAXSelectedTextChangedNotification as CFString, context)
        AXObserverAddNotification(result, element, kAXValueChangedNotification as CFString, context)
        AXObserverAddNotification(result, AXUIElementCreateApplication(pid), kAXFocusedUIElementChangedNotification as CFString, context)
        AXObserverAddNotification(result, AXUIElementCreateApplication(pid), kAXFocusedWindowChangedNotification as CFString, context)
        observer = result
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(result), .commonModes)
    }

    private func sensitive(_ element: AXUIElement) -> Bool {
        SecureFieldDetector.isSecure(
            role: AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element),
            subrole: AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element),
            roleDescription: AXHelper.stringValue(for: kAXRoleDescriptionAttribute as CFString, on: element),
            title: AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: element),
            descriptionLabel: AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element))
    }
}
