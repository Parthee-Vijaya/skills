import AppKit

/// Watches for file drags anywhere on screen and asks for the wheel when Shift is held.
///
/// macOS has no "a drag started" notification, so this combines three signals that need no special permissions:
/// global mouse events (mouse-down and mouse-dragged), the shared drag pasteboard, whose change count
/// bumps whenever a new drag begins, and the current modifier keys. While the button is down a short timer
/// polls, so pressing Shift mid-drag works even if the pointer is standing still.
@MainActor
final class DragMonitor {
    var onShow: (@MainActor (_ urls: [URL], _ mode: WheelMode, _ location: NSPoint) -> Void)?
    var onModeChange: (@MainActor (WheelMode) -> Void)?
    var onDragEnded: (@MainActor () -> Void)?

    private var monitors: [Any] = []
    private var timer: Timer?
    private var changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    private var wheelShown = false
    private var currentMode: WheelMode = .convert

    func start() {
        guard monitors.isEmpty else { return }
        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) {
            monitors.append(down)
        }
        if let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }) {
            monitors.append(dragged)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        endTracking()
    }

    private func mouseDown() {
        changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    }

    private func mouseDragged() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        // Mouse released: the drag is over (dropped on the wheel or elsewhere).
        guard NSEvent.pressedMouseButtons & 1 == 1 else {
            endTracking()
            return
        }
        guard !Prefs.isPaused else { return }
        let flags = NSEvent.modifierFlags
        let mode: WheelMode = flags.contains(.option) ? .tools : .convert

        if wheelShown {
            if flags.contains(.shift), mode != currentMode {
                currentMode = mode
                onModeChange?(mode)
            }
            return
        }

        guard flags.contains(.shift) else { return }
        let pasteboard = NSPasteboard(name: .drag)
        // Only a drag that started during this mouse press counts; the pasteboard keeps old drags around.
        guard pasteboard.changeCount != changeCountAtMouseDown else { return }
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return }
        wheelShown = true
        currentMode = mode
        onShow?(urls, mode, NSEvent.mouseLocation)
    }

    private func endTracking() {
        timer?.invalidate()
        timer = nil
        changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        if wheelShown {
            wheelShown = false
            onDragEnded?()
        }
    }
}
