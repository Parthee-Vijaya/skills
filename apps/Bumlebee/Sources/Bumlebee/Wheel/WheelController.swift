import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Owns the floating wheel window. The wheel accepts drops (drag mode) and clicks (menu mode).
@MainActor
final class WheelController {
    let model = WheelModel()
    var onAction: ((WheelAction, [URL]) -> Void)?
    private var panel: WheelPanel?
    private var thumbnailRequest: QLThumbnailGenerator.Request?

    var isVisible: Bool { panel?.isVisible == true }

    func show(urls: [URL], mode: WheelMode, at point: NSPoint, clickMode: Bool) {
        guard !urls.isEmpty else { return }
        model.urls = urls
        model.clickMode = clickMode
        model.count = urls.count
        model.fileName = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) filer"
        model.sizeText = ByteCountFormatter.string(fromByteCount: Int64(urls.reduce(0) { $0 + Self.size(of: $1) }), countStyle: .file)
        setMode(mode, force: true)
        loadThumbnail(for: urls[0])

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrameOrigin(origin(centeredAt: point))
        model.appeared = false
        panel.orderFrontRegardless()
        if clickMode {
            NSApp.activate()
            panel.makeKey()
            panel.makeFirstResponder(panel.interactionView)
        }
        Task { @MainActor in
            self.model.appeared = true
        }
    }

    func setMode(_ mode: WheelMode, force: Bool = false) {
        guard force || mode != model.mode else { return }
        model.mode = mode
        model.items = Catalog.items(for: model.urls, mode: mode)
        model.highlighted = nil
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        model.highlighted = nil
        model.appeared = false
        panel.orderOut(nil)
    }

    func hover(at point: CGPoint?) {
        let index = point.flatMap { WheelGeometry.index(at: $0, count: model.items.count) }
        if index != model.highlighted { model.highlighted = index }
    }

    func activate(index: Int, urls: [URL]? = nil) {
        guard model.items.indices.contains(index) else { return }
        let item = model.items[index]
        let files = urls ?? model.urls
        hide()
        if let reason = item.disabledReason {
            Alerts.info(title: "\(item.title) er ikke tilgængelig", message: reason)
            return
        }
        onAction?(item.action, files)
    }

    // MARK: Private

    private func makePanel() -> WheelPanel {
        let panel = WheelPanel(controller: self)
        let container = NSView(frame: NSRect(origin: .zero, size: WheelGeometry.windowSize))
        let hosting = NSHostingView(rootView: WheelView(model: model))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.interactionView.frame = container.bounds
        panel.interactionView.autoresizingMask = [.width, .height]
        container.addSubview(panel.interactionView)
        panel.contentView = container
        return panel
    }

    /// Puts the disc's centre under the pointer, nudged to stay on screen.
    private func origin(centeredAt point: NSPoint) -> NSPoint {
        let size = WheelGeometry.windowSize
        var origin = NSPoint(x: point.x - WheelGeometry.center.x, y: point.y - (size.height - WheelGeometry.center.y))
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.frame
            origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
            origin.y = min(max(origin.y, frame.minY), frame.maxY - size.height)
        }
        return origin
    }

    private func loadThumbnail(for url: URL) {
        model.thumbnail = nil
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 110, height: 110), scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        thumbnailRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage
            Task { @MainActor in
                guard let self, self.thumbnailRequest === request else { return }
                self.model.thumbnail = image
            }
        }
    }

    private static func size(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            var total = 0
            var visited = 0
            while let item = enumerator?.nextObject() as? URL, visited < 5_000 {
                total += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                visited += 1
            }
            return total
        }
        return values?.fileSize ?? 0
    }
}

/// Borderless, transparent, non-activating panel that floats above everything, including full-screen apps.
final class WheelPanel: NSPanel {
    let interactionView: WheelInteractionView

    init(controller: WheelController) {
        interactionView = WheelInteractionView(controller: controller)
        super.init(
            contentRect: NSRect(origin: .zero, size: WheelGeometry.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        // In click mode, clicking elsewhere dismisses the wheel.
        if interactionView.controller?.model.clickMode == true {
            interactionView.controller?.hide()
        }
    }
}

/// Transparent overlay that turns drags and clicks into wheel choices.
final class WheelInteractionView: NSView {
    weak var controller: WheelController?

    init(controller: WheelController) {
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: WheelGeometry.windowSize))
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    // MARK: Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hover(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hover(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.hover(at: nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        guard let controller, let index = WheelGeometry.index(at: point, count: controller.model.items.count) else {
            // Dropped on the centre: nothing happens and the file springs back.
            controller?.hide()
            return false
        }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        controller.activate(index: index, urls: (urls?.isEmpty == false) ? urls : nil)
        return true
    }

    private func hover(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        controller?.hover(at: point)
        return WheelGeometry.index(at: point, count: controller?.model.items.count ?? 0) == nil ? [] : .copy
    }

    // MARK: Mouse and keyboard (menu mode)

    override func mouseMoved(with event: NSEvent) {
        controller?.hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        controller?.hover(at: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        if WheelGeometry.isInCenter(point) {
            controller.setMode(controller.model.mode.toggled)
        } else if let index = WheelGeometry.index(at: point, count: controller.model.items.count) {
            controller.activate(index: index)
        } else {
            controller.hide()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return }
        switch event.keyCode {
        case 53: controller.hide() // Escape
        case 48: controller.setMode(controller.model.mode.toggled) // Tab
        default: super.keyDown(with: event)
        }
    }
}
