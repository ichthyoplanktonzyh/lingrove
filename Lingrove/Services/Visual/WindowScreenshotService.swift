import AppKit
import CoreGraphics
import Foundation
import Logging
import ScreenCaptureKit

/// File overview:
/// Captures the focused window (local engines) or a field crop (endpoint) using ScreenCaptureKit.
/// This is the screenshot boundary for prompt augmentation: raw pixels enter here, and the rest
/// of the app never has to know about window discovery, crop math, or coordinate conversion APIs.
///
/// We use ScreenCaptureKit instead of deprecated Core Graphics screenshot APIs because the app
/// targets a modern macOS SDK where `CGWindowListCreateImage` is no longer available.

struct CapturedWindowScreenshot {
    let image: CGImage
    let windowTitle: String?
    var focusBounds: CGRect?
}

/// Test seam for screen capture.
///
/// ScreenCaptureKit is permissioned, asynchronous, and window-manager dependent. Keeping this
/// protocol narrow lets `ScreenshotContextGenerator` tests focus on context policy instead of
/// requiring a live macOS desktop capture.
protocol WindowScreenshotCapturing {
    func captureSnapshot(
        around context: FocusedInputSnapshot,
        snapshotDimension: Int,
        capturesEntireWindow: Bool
    ) async throws -> CapturedWindowScreenshot
}

enum WindowScreenshotError: LocalizedError {
    case screenRecordingPermissionMissing
    case noVisibleWindowForProcess(pid_t)
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionMissing:
            return String(localized: "Screen Recording permission is required to capture screenshot context.")
        case let .noVisibleWindowForProcess(processIdentifier):
            return String(localized: "No visible frontmost window was found for process \(processIdentifier).")
        case let .captureFailed(message):
            return String(localized: "Unable to capture the frontmost window screenshot: \(message)")
        }
    }
}

struct WindowScreenshotService: WindowScreenshotCapturing {
    /// Explicit reading capture is a display crop, independent of editable focus and completion's
    /// visual-context preference. Excluding our process keeps picker/card pixels out of OCR.
    @MainActor
    func captureRegion(_ cocoaRect: CGRect, deadline: TimeInterval? = nil) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw LearningFailure.message(String(
                localized: "Allow Screen Recording for Lingrove in System Settings to translate screen text.",
                table: "Learning"))
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoaRect) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw LearningFailure.message(String(localized: "Select a region within one display.", table: "Learning"))
        }
        let content = try await currentShareableContent(deadline: deadline)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { throw CancellationError() }
        let rect = LearningReadingTextPolicy.displayCrop(cocoaRect, in: screen.frame)
        // SCDisplay.width and frame are both in logical points (their ratio is always one).
        // Output dimensions need the matched NSScreen's backing scale to retain Retina glyphs.
        let scale = screen.backingScaleFactor
        guard rect.width >= 4, rect.height >= 4, rect.width * rect.height * scale * scale <= 20_000_000 else {
            throw LearningFailure.message(String(localized: "Select a smaller screen region.", table: "Learning"))
        }
        let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = max(1, Int((rect.width * scale).rounded(.up)))
        configuration.height = max(1, Int((rect.height * scale).rounded(.up)))
        configuration.showsCursor = false
        let image = try await captureImage(filter: filter, configuration: configuration, deadline: deadline)
        try Task.checkCancellation()
        return image
    }

    /// This receipt keeps Window Server identity even when the app exposes no AX window. It
    /// outlives the screenshot only as geometry, allowing a moved/replaced window to retire OCR.
    struct ReadingRegion: Sendable {
        let windowID: CGWindowID
        let windowFrame: CGRect
        let bounds: CGRect
        let point: CGPoint
        let pid: Int32
    }

    /// Resolve the actual topmost non-Lingrove window first. An uncapturable covering window
    /// must not be skipped in favour of text underneath it. Only the matched window may expand.
    @MainActor
    func pointerCaptureRegion(at point: CGPoint, pid: Int32, deadline: TimeInterval) async throws -> ReadingRegion {
        let content = try await currentShareableContent(deadline: deadline)
        try Task.checkCancellation()
        let window = try windowAtPoint(point, pid: pid)
        guard content.windows.contains(where: { $0.windowID == window.id && $0.owningApplication?.processID == pid }),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let bounds = LearningReadingVisualPolicy.snapshotBounds(at: point, screen: screen.frame,
                window: window.frame, scale: screen.backingScaleFactor)
        else { throw WindowScreenshotError.noVisibleWindowForProcess(pid) }
        return ReadingRegion(windowID: window.id, windowFrame: window.frame, bounds: bounds, point: point, pid: pid)
    }

    @MainActor
    func isCurrent(_ region: ReadingRegion) -> Bool {
        guard let window = try? windowAtPoint(region.point, pid: region.pid) else { return false }
        return window.id == region.windowID && window.frame == region.windowFrame
    }

    @MainActor
    private func windowAtPoint(_ point: CGPoint, pid: Int32) throws -> (id: CGWindowID, frame: CGRect) {
        guard let ordered = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { throw CancellationError() }
        for info in ordered {
            // Cursor surfaces and Dock animation shields can report full-display alpha=1
            // frames while their pixels are transparent. They are compositor overlays, not
            // reading windows. Ordinary application panels still participate in occlusion.
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner != ProcessInfo.processInfo.processIdentifier,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer < Int(CGWindowLevelForKey(.screenSaverWindow)),
                  NSRunningApplication(processIdentifier: owner)?.bundleIdentifier != "com.apple.dock",
                  let identifier = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let rawFrame = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  AXHelper.rectHasFiniteComponents(rawFrame),
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0 else { continue }
            let frame = AXHelper.cocoaRect(fromAccessibilityRect: rawFrame)
            guard frame.contains(point) else { continue }
            guard owner == pid else { throw CancellationError() }
            return (identifier, frame)
        }
        throw WindowScreenshotError.noVisibleWindowForProcess(pid)
    }

    private enum CaptureMetrics {
        /// Extra horizontal context captured around the focused field. ScreenCaptureKit works in
        /// display points here, which map to physical pixels later through `backingScaleFactor`.
        static let horizontalPadding: CGFloat = 160

        /// Capture a taller band above the input so OCR can see nearby labels, messages, and
        /// surrounding page content instead of only the field chrome.
        static let verticalContextHeight: CGFloat = 800
    }

    /// Finds the most relevant visible window for the focused process and captures an expanded
    /// region above the focused input. The crop is expressed in global display points so the
    /// caller does not need to know anything about ScreenCaptureKit's capture coordinate system.
    func captureSnapshot(
        around context: FocusedInputSnapshot,
        snapshotDimension: Int,
        capturesEntireWindow: Bool = false
    ) async throws -> CapturedWindowScreenshot {
        let processIdentifier = pid_t(context.processIdentifier)

        guard CGPreflightScreenCaptureAccess() else {
            LingroveLogger.app.warning("Screenshot blocked: Screen Recording permission missing")
            throw WindowScreenshotError.screenRecordingPermissionMissing
        }

        let shareableContent = try await currentShareableContent()
        try Task.checkCancellation()
        let caretCG = convertBetweenAppKitAndCG(rect: context.caretRect)
        let focusedWindow = capturesEntireWindow ? shareableContent.windows.first(where: {
            $0.owningApplication?.processID == processIdentifier && $0.isOnScreen
                && $0.frame.contains(CGPoint(x: caretCG.midX, y: caretCG.midY)) && $0.isActive
        }) : nil
        let matchingWindow =
            focusedWindow ?? shareableContent.windows.first(where: {
                $0.owningApplication?.processID == processIdentifier && $0.isActive && $0.isOnScreen
            })
            ?? shareableContent.windows.first(where: {
                $0.owningApplication?.processID == processIdentifier && $0.isOnScreen
            })

        guard let matchingWindow else {
            LingroveLogger.app.debug("No visible window for pid \(processIdentifier)")
            throw WindowScreenshotError.noVisibleWindowForProcess(processIdentifier)
        }
        let windowTitle = matchingWindow.title ?? "untitled"
        let windowWidth = Int(matchingWindow.frame.width)
        let windowHeight = Int(matchingWindow.frame.height)
        LingroveLogger.app.trace("Capturing window: \(windowTitle) (\(windowWidth)x\(windowHeight))")

        let sourceRect = capturesEntireWindow ? matchingWindow.frame : snapshotRect(
            around: context,
            windowFrame: matchingWindow.frame,
            snapshotDimension: CGFloat(snapshotDimension)
        )
        guard !sourceRect.isEmpty, !sourceRect.isInfinite, !sourceRect.isNull else {
            throw WindowScreenshotError.captureFailed("The focused window has no captureable bounds.")
        }
        let outputScale = backingScaleFactor(for: sourceRect)

        let filter = SCContentFilter(desktopIndependentWindow: matchingWindow)
        let configuration = SCStreamConfiguration()

        let localSourceRect = CGRect(
            x: sourceRect.minX - matchingWindow.frame.minX,
            y: sourceRect.minY - matchingWindow.frame.minY,
            width: sourceRect.width,
            height: sourceRect.height
        )

        configuration.sourceRect = localSourceRect
        configuration.width = max(Int((localSourceRect.width * outputScale).rounded(.up)), 1)
        configuration.height = max(Int((localSourceRect.height * outputScale).rounded(.up)), 1)
        configuration.showsCursor = false

        let image = try await captureImage(filter: filter, configuration: configuration)
        try Task.checkCancellation()
        // OCR exclusion needs the field's real column. inputFrameRect is widened for card layout
        // and can include a neighboring sidebar whose context must remain available.
        let field = convertBetweenAppKitAndCG(rect: context.elementFrameRect ?? context.inputFrameRect ?? context.caretRect)
        let caret = convertBetweenAppKitAndCG(rect: context.caretRect)
        // Vision uses bottom-left unit coordinates; AX/SCK use display points. Carry only this
        // small geometric value into selection, never the AX element or window itself.
        let focusBounds = CGRect(
            x: (field.minX - sourceRect.minX) / sourceRect.width,
            y: 1 - (caret.maxY - sourceRect.minY) / sourceRect.height,
            width: field.width / sourceRect.width,
            height: caret.height / sourceRect.height
        )
        return CapturedWindowScreenshot(image: image, windowTitle: matchingWindow.title, focusBounds: focusBounds)
    }

    private func snapshotRect(
        around context: FocusedInputSnapshot,
        windowFrame: CGRect,
        snapshotDimension: CGFloat
    ) -> CGRect {
        let targetHeight = min(CaptureMetrics.verticalContextHeight, windowFrame.height)
        let targetWidth: CGFloat
        let proposedX: CGFloat
        let proposedY: CGFloat

        if let inputFrameAppKit = context.inputFrameRect, !inputFrameAppKit.isEmpty {
            let inputFrameCG = convertBetweenAppKitAndCG(rect: inputFrameAppKit)
            targetWidth = min(
                inputFrameCG.width + (CaptureMetrics.horizontalPadding * 2),
                windowFrame.width
            )
            proposedX = inputFrameCG.minX - CaptureMetrics.horizontalPadding
            proposedY = inputFrameCG.minY - targetHeight
        } else {
            // Fall back to the caret if the input frame is completely unavailable.
            let caretRectCG = convertBetweenAppKitAndCG(rect: context.caretRect)
            targetWidth = min(
                snapshotDimension + (CaptureMetrics.horizontalPadding * 2),
                windowFrame.width
            )
            proposedX = caretRectCG.midX - (targetWidth / 2)
            proposedY = caretRectCG.minY - targetHeight
        }

        // Clamp within the window frame bounds so SCK does not fail or crop incorrectly.
        let clampedX = min(max(proposedX, windowFrame.minX), windowFrame.maxX - targetWidth)
        let clampedY = min(max(proposedY, windowFrame.minY), windowFrame.maxY - targetHeight)

        return CGRect(
            x: clampedX,
            y: clampedY,
            width: targetWidth,
            height: targetHeight
        ).integral
    }

    private func backingScaleFactor(for rect: CGRect) -> CGFloat {
        let appKitRect = convertBetweenAppKitAndCG(rect: rect)
        let midpoint = CGPoint(x: appKitRect.midX, y: appKitRect.midY)

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(midpoint) }) {
            return screen.backingScaleFactor
        }

        return NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private func convertBetweenAppKitAndCG(rect: CGRect) -> CGRect {
        let desktopBounds = NSScreen.screens.map(\.frame).reduce(into: CGRect.null) {
            $0 = $0.union($1)
        }
        guard !desktopBounds.isNull else { return rect }
        return CGRect(
            x: rect.origin.x,
            y: desktopBounds.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Wraps ScreenCaptureKit's callback API so the rest of the app can use structured concurrency.
    private func currentShareableContent(deadline: TimeInterval? = nil) async throws -> SCShareableContent {
        try await ScreenCaptureReply<SCShareableContent>().wait(deadline: deadline ?? ProcessInfo.processInfo.systemUptime + 12) { reply in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let error {
                    reply(.failure(WindowScreenshotError.captureFailed(error.localizedDescription)))
                    return
                }

                guard let content else {
                    reply(.failure(WindowScreenshotError.captureFailed("Shareable content was unavailable.")))
                    return
                }

                reply(.success(content))
            }
        }
    }

    /// Captures one CGImage for the chosen window filter.
    private func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        deadline: TimeInterval? = nil
    ) async throws -> CGImage {
        try await ScreenCaptureReply<CGImage>().wait(deadline: deadline ?? ProcessInfo.processInfo.systemUptime + 12) { reply in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    reply(.failure(WindowScreenshotError.captureFailed(error.localizedDescription)))
                    return
                }

                guard let image else {
                    reply(.failure(WindowScreenshotError.captureFailed("ScreenCaptureKit returned no image.")))
                    return
                }

                reply(.success(image))
            }
        }
    }
}
