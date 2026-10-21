import AppKit

/// A window-local canvas draws compact dots and labels without constructing thousands of
/// SwiftUI views. Its only animation task asks the isolated worker for copied positions, then
/// ends when the solver cools. Hiding/closing the window also cancels that task immediately.
@MainActor
final class VocabularyGraphCanvasView: NSView {
    private let presentation: VocabularyGraphPresentation
    private var snapshot = VocabularyGraphSnapshot()
    private var selection: VocabularySelection?
    private var select: (VocabularySelection?) -> Void = { _ in }
    private var positions: [VocabularyGraphNodeID: CGPoint] = [:]
    private var animationTask: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var hovered: VocabularyGraphNodeID?
    private var pointer: PointerSession?
    private var pinned: VocabularyGraphNodeID?
    private var pinPosition: CGPoint?
    private var pinSerial: UInt64 = 0
    private var releasedPin: ReleasedPin?
    private var keyboardNode: VocabularyGraphNodeID?
    private var pendingSearchTarget: VocabularyGraphNodeID?

    private struct FrameInput {
        let node: VocabularyGraphNodeID?
        let position: CGPoint?
        let releaseSerial: UInt64?
    }

    private struct ReleasedPin {
        let node: VocabularyGraphNodeID
        let position: CGPoint
        let serial: UInt64
    }
    private var tracking: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []
    private var appliedSettings = VocabularyGraphSettings()
    private var commandSerial = 0
    private var accessibilityNodes: [VocabularyGraphAccessibilityNode] = []
    private var needsLayoutWake = true
    private(set) var renderedFrameCount = 0
    var isAnimating: Bool { animationTask != nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Pointer state separates a click from a drag after a small movement threshold. Releasing
    /// a dragged dot must not also activate its sense or collapse the word it just moved.
    private struct PointerSession {
        let node: VocabularyGraphNodeID?
        let start: CGPoint
        let offset: CGPoint
        let grabOffset: CGPoint
        var moved = false
    }

    init(presentation: VocabularyGraphPresentation) {
        self.presentation = presentation
        super.init(frame: .zero)
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Vocabulary graph", table: "Vocabulary"))
        setAccessibilityIdentifier("vocabularyGraph")
    }
    required init?(coder: NSCoder) { nil }

    func update(snapshot: VocabularyGraphSnapshot, selection: VocabularySelection?,
                select: @escaping (VocabularySelection?) -> Void) {
        self.select = select
        if self.selection != selection, let selection { pendingSearchTarget = .sense(selection) }
        self.selection = selection
        let oldMatches = self.snapshot.matches
        let oldQuery = self.snapshot.searchQuery
        let topologyChanged = self.snapshot != snapshot
        self.snapshot = snapshot
        if let pinned, !snapshot.nodes.contains(where: { $0.id == pinned }) {
            self.pinned = nil; pinPosition = nil; releasedPin = nil; pointer = nil
        }
        if let keyboardNode, !snapshot.nodes.contains(where: { $0.id == keyboardNode }) { self.keyboardNode = nil }
        let settings = presentation.settings.normalized
        let forceChanged = appliedSettings.center != settings.center || appliedSettings.repulsion != settings.repulsion
            || appliedSettings.linkStrength != settings.linkStrength || appliedSettings.linkDistance != settings.linkDistance
        appliedSettings = settings
        if topologyChanged {
            let heads = Dictionary(uniqueKeysWithValues: snapshot.nodes.filter { $0.id.selection == nil }
                .map { ($0.id.entryID, $0.label) })
            accessibilityNodes = snapshot.nodes.map { node in
                VocabularyGraphAccessibilityNode(node: node, headword: heads[node.id.entryID], owner: self)
            }
            needsLayoutWake = true
        }
        if topologyChanged || forceChanged { needsLayoutWake = true; wake() }
        if commandSerial != presentation.commandSerial {
            commandSerial = presentation.commandSerial
            execute(presentation.command)
        }
        if oldMatches != snapshot.matches || oldQuery != snapshot.searchQuery {
            pendingSearchTarget = snapshot.nodes.first(where: { snapshot.matches.contains($0.id) })?.id
            centerSearchResult()
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let window else { suspend(); return }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.window?.occlusionState.contains(.visible) == true { self.wake() } else { self.suspend() }
                }
            })
        wake()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        if let tracking { addTrackingArea(tracking) }
    }

    func suspend() {
        animationTask?.cancel()
        animationTask = nil
        epoch = presentation.nextEpoch()
        let finalNode = pinned ?? releasedPin?.node
        let finalPosition = pinPosition ?? releasedPin?.position
        pinned = nil; pinPosition = nil; pointer = nil; releasedPin = nil
        needsLayoutWake = true
        let worker = presentation.worker, ticket = epoch
        Task { await worker.suspend(epoch: ticket, finalNode: finalNode, finalPosition: finalPosition) }
    }

    private var canAnimate: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func wake() {
        guard canAnimate, !snapshot.nodes.isEmpty else {
            if snapshot.nodes.isEmpty { suspend(); positions = [:]; needsDisplay = true }
            return
        }
        if animationTask != nil {
            if !needsLayoutWake { return }
            animationTask?.cancel()
        }
        needsLayoutWake = false
        epoch = presentation.nextEpoch()
        let ticket = epoch, worker = presentation.worker, graph = snapshot, settings = appliedSettings
        animationTask = Task { [weak self] in
            guard let frame = await worker.configure(graph, settings: settings, epoch: ticket), !Task.isCancelled else { return }
            self?.apply(frame, epoch: ticket)
            var running = frame.isRunning
            while !Task.isCancelled {
                guard let input = self?.input(epoch: ticket), running || input.node != nil else { break }
                guard let next = await worker.advance(epoch: ticket, pinned: input.node, position: input.position),
                      !Task.isCancelled else { break }
                self?.apply(next, epoch: ticket)
                self?.acknowledgeRelease(input)
                running = next.isRunning
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
            if self?.epoch == ticket { self?.animationTask = nil }
        }
    }

    private func acknowledgeRelease(_ input: FrameInput) {
        if let serial = input.releaseSerial, releasedPin?.serial == serial { releasedPin = nil }
    }

    private func input(epoch: UInt64) -> FrameInput? {
        guard self.epoch == epoch, window?.isVisible == true else { return nil }
        if let pinned { return .init(node: pinned, position: pinPosition, releaseSerial: nil) }
        if let release = releasedPin { return .init(node: release.node, position: release.position, releaseSerial: release.serial) }
        return .init(node: nil, position: nil, releaseSerial: nil)
    }
    private func apply(_ frame: VocabularyGraphFrame, epoch: UInt64) {
        guard self.epoch == epoch else { return }
        positions = frame.positions
        // A worker reply can predate a newer pointer event. Preserve the immediate pointer
        // position until the final pin is acknowledged, including a drag shorter than a tick.
        if let pinned, let pinPosition { positions[pinned] = pinPosition } else if let release = releasedPin {
            positions[release.node] = release.position
        }
        renderedFrameCount += 1
        if presentation.fitsInitialLayout, bounds.width > 0, bounds.height > 0, !positions.isEmpty {
            presentation.camera.fit(Array(positions.values), in: bounds.size)
            presentation.hasCamera = true
            if !frame.isRunning { presentation.fitsInitialLayout = false }
        }
        centerSearchResult()
        needsDisplay = true
    }

    private func centerSearchResult() {
        if let pendingSearchTarget, let point = positions[pendingSearchTarget] {
            // Searching is explicit camera navigation even when focus stays in the toolbar.
            // The initial settling fit must not undo that navigation on the following tick.
            presentation.fitsInitialLayout = false
            center(on: point)
            self.pendingSearchTarget = nil
        }
    }

    override func layout() {
        super.layout()
        if !presentation.hasCamera, bounds.width > 0, !positions.isEmpty {
            presentation.camera.fit(Array(positions.values), in: bounds.size); presentation.hasCamera = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill(); bounds.fill()
        let focused = hovered?.entryID ?? presentation.focusedEntryID
        for edge in snapshot.edges {
            guard let start = positions[edge.source], let end = positions[edge.target] else { continue }
            let path = NSBezierPath()
            path.move(to: screen(start)); path.line(to: screen(end))
            let highlighted = edge.source.entryID == focused
            (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor)
                .withAlphaComponent(hovered != nil && !highlighted ? 0.2 : 1).setStroke()
            path.lineWidth = appliedSettings.linkWidth; path.stroke()
        }
        for node in snapshot.nodes {
            guard let world = positions[node.id] else { continue }
            let point = screen(world)
            guard bounds.insetBy(dx: -160, dy: -55).contains(point) else { continue }
            draw(node, at: point, focused: focused)
        }
    }

    private func draw(_ node: VocabularyGraphNode, at point: CGPoint, focused: UUID?) {
        let isSense = node.id.selection != nil
        let selected = node.id.selection.map { $0 == selection } ?? (node.id.entryID == presentation.focusedEntryID)
        let active = selected || snapshot.matches.contains(node.id)
        let related = node.id.entryID == focused
        let alpha: CGFloat = hovered != nil && !related ? 0.23 : 1
        let radius = max(3, min(20, appliedSettings.nodeSize * (isSense ? 0.29 : 0.5) * presentation.camera.scale))
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        if active || hovered == node.id || keyboardNode == node.id {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -5, dy: -5)).fill()
        }
        let color = (active || isSense ? NSColor.controlAccentColor : NSColor.secondaryLabelColor)
            .withAlphaComponent(alpha)
        color.setFill(); color.setStroke()
        let dot = NSBezierPath(ovalIn: rect)
        if isSense && !active { dot.lineWidth = 1.4; dot.stroke() } else { dot.fill() }
        let labels = appliedSettings.labels
        let showLabel = labels == .all || active || keyboardNode == node.id || related
            || (labels == .automatic && presentation.camera.scale >= 0.65)
        guard showLabel else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let textColor = active ? NSColor.controlAccentColor : (isSense ? NSColor.secondaryLabelColor : NSColor.labelColor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: isSense ? 12 : 13, weight: active ? .medium : .regular),
            .foregroundColor: textColor.withAlphaComponent(alpha), .paragraphStyle: paragraph
        ]
        (node.label as NSString).draw(with: CGRect(x: point.x - 76, y: point.y + radius + 6, width: 152, height: 36),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    private func screen(_ point: CGPoint) -> CGPoint { presentation.camera.screen(point, in: bounds.size) }
    private func hit(_ point: CGPoint) -> VocabularyGraphNodeID? {
        var nearest: (VocabularyGraphNodeID, CGFloat)?
        for node in snapshot.nodes {
            guard let position = positions[node.id] else { continue }
            let screen = screen(position), distance = hypot(point.x - screen.x, point.y - screen.y)
            if distance < 22, nearest == nil || distance < (nearest?.1 ?? .infinity) { nearest = (node.id, distance) }
        }
        return nearest?.0
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = hit(convert(event.locationInWindow, from: nil)); needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        presentation.fitsInitialLayout = false
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil), node = hit(point)
        let world = presentation.camera.world(point, in: bounds.size)
        let position = node.flatMap { positions[$0] } ?? world
        keyboardNode = node
        pointer = .init(node: node, start: point, offset: presentation.camera.offset,
                        grabOffset: CGPoint(x: position.x - world.x, y: position.y - world.y))
    }
    override func mouseDragged(with event: NSEvent) {
        guard var pointer else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - pointer.start.x, point.y - pointer.start.y) > 3 { pointer.moved = true }
        self.pointer = pointer
        guard pointer.moved else { return }
        if let node = pointer.node {
            pinSerial &+= 1
            releasedPin = nil
            pinned = node
            let world = presentation.camera.world(point, in: bounds.size)
            pinPosition = CGPoint(x: world.x + pointer.grabOffset.x, y: world.y + pointer.grabOffset.y)
            positions[node] = pinPosition
            wake()
        } else {
            presentation.camera.offset = CGPoint(x: pointer.offset.x + point.x - pointer.start.x,
                                                  y: pointer.offset.y + point.y - pointer.start.y)
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let pointer else { return }
        self.pointer = nil
        if pointer.moved {
            if let pinned, let pinPosition {
                releasedPin = .init(node: pinned, position: pinPosition, serial: pinSerial)
            }
            pinned = nil; pinPosition = nil
            // Deliver the final location even if no display tick ran during this gesture.
            wake()
        } else if let node = pointer.node { activate(node) } else { presentation.clearFocus(); select(nil); needsDisplay = true }
    }
    func activate(_ id: VocabularyGraphNodeID) {
        presentation.fitsInitialLayout = false
        if let target = id.selection { presentation.reveal(target); select(target) } else { presentation.toggle(id.entryID); select(nil) }
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        presentation.fitsInitialLayout = false
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) || !event.hasPreciseScrollingDeltas {
            presentation.camera.zoom(by: exp(-event.scrollingDeltaY * 0.025),
                at: convert(event.locationInWindow, from: nil), in: bounds.size)
        } else {
            presentation.camera.offset.x += event.scrollingDeltaX
            presentation.camera.offset.y += event.scrollingDeltaY
        }
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        presentation.fitsInitialLayout = false
        presentation.camera.zoom(by: max(0.2, 1 + event.magnification),
            at: convert(event.locationInWindow, from: nil), in: bounds.size)
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        presentation.fitsInitialLayout = false
        switch event.keyCode {
        case 48: moveKeyboard(backwards: event.modifierFlags.contains(.shift))
        case 36, 49:
            if let keyboardNode { activate(keyboardNode) }
        case 53: presentation.clearFocus(); select(nil)
        case 24: execute(.zoomIn)
        case 27: execute(.zoomOut)
        case 123...126: panArrow(event.keyCode)
        default: super.keyDown(with: event)
        }
        needsDisplay = true
    }
    private func panArrow(_ key: UInt16) {
        switch key {
        case 123: presentation.camera.offset.x += 30
        case 124: presentation.camera.offset.x -= 30
        case 125: presentation.camera.offset.y -= 30
        default: presentation.camera.offset.y += 30
        }
    }

    private func moveKeyboard(backwards: Bool) {
        let index = keyboardNode.flatMap { target in snapshot.nodes.firstIndex { $0.id == target } }
        let next = (index ?? (backwards ? snapshot.nodes.count : -1)) + (backwards ? -1 : 1)
        if snapshot.nodes.indices.contains(next) {
            keyboardNode = snapshot.nodes[next].id
            if let point = positions[snapshot.nodes[next].id] { center(on: point) }
        } else {
            keyboardNode = nil
            if backwards { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
        }
    }

    private func execute(_ command: VocabularyGraphPresentation.Command) {
        presentation.fitsInitialLayout = false
        let viewportCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        switch command {
        case .zoomIn: presentation.camera.zoom(by: 1.2, at: viewportCenter, in: bounds.size)
        case .zoomOut: presentation.camera.zoom(by: 1 / 1.2, at: viewportCenter, in: bounds.size)
        case .fit: presentation.camera.fit(Array(positions.values), in: bounds.size)
        case .locate:
            if let id = presentation.focusedEntryID, let point = positions[.headword(id)] {
                center(on: point)
            }
        }
        needsDisplay = true
    }

    private func center(on point: CGPoint) {
        presentation.camera.offset = CGPoint(x: -point.x * presentation.camera.scale, y: -point.y * presentation.camera.scale)
    }

    override func accessibilityChildren() -> [Any]? { accessibilityNodes }
    func accessibilityFrame(for id: VocabularyGraphNodeID) -> CGRect {
        guard let point = positions[id], let window else { return .zero }
        let center = screen(point)
        let rect = CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44)
        return window.convertToScreen(convert(rect, to: nil))
    }
}

/// Native accessibility elements keep dots keyboard/VoiceOver operable while frames are
/// calculated lazily, rather than rebuilding the accessibility tree on every physics tick.
@MainActor
private final class VocabularyGraphAccessibilityNode: NSAccessibilityElement {
    private let node: VocabularyGraphNode
    private weak var owner: VocabularyGraphCanvasView?
    init(node: VocabularyGraphNode, headword: String?, owner: VocabularyGraphCanvasView) {
        self.node = node; self.owner = owner
        super.init()
        let label = node.id.selection == nil ? node.label : (headword ?? "") + " · " +
            String(localized: "Core meaning", table: "Vocabulary") + ": " + node.label
        setAccessibilityRole(.button); setAccessibilityLabel(label); setAccessibilityParent(owner)
        setAccessibilityEnabled(true)
    }
    override func accessibilityFrame() -> NSRect { owner?.accessibilityFrame(for: node.id) ?? .zero }
    override func accessibilityPerformPress() -> Bool { owner?.activate(node.id); return owner != nil }
}
