import AppKit

/// Menu bar app: owns the status item, the drag monitor and the wheel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private let wheel = WheelController()
    private let monitor = DragMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        setUpStatusItem()

        wheel.onAction = { action, urls in
            Actions.perform(action, on: urls)
        }
        monitor.onShow = { [weak self] urls, mode, location in
            self?.wheel.show(urls: urls, mode: mode, at: location, clickMode: false)
        }
        monitor.onModeChange = { [weak self] mode in
            self?.wheel.setMode(mode)
        }
        monitor.onDragEnded = { [weak self] in
            // Give a drop on the wheel a moment to arrive before tidying up.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let self, !self.wheel.model.clickMode else { return }
                self.wheel.hide()
            }
        }
        monitor.start()

        if !Prefs.hasSeenOnboarding {
            Windows.openWelcome()
        }
    }

    /// Files opened with "Open With → Bumlebee" or dropped on the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        showWheel(for: urls, mode: .convert, at: screenCenter())
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Windows.openSettings()
        return false
    }

    // MARK: Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.make()
        item.button?.toolTip = "Bumlebee – hold ⇧ mens du trækker en fil"
        // Files can also be dropped straight on the menu bar icon.
        item.button?.window?.registerForDraggedTypes([.fileURL])
        item.button?.window?.delegate = self

        let menu = NSMenu()
        menu.delegate = self
        let header = NSMenuItem(title: "Bumlebee", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(menuItem("Konvertér filer …", #selector(chooseFilesToConvert), key: "o"))
        menu.addItem(menuItem("Værktøjer til filer …", #selector(chooseFilesForTools), key: "O"))
        menu.addItem(.separator())
        let pause = menuItem("Sæt på pause", #selector(togglePause), key: "")
        menu.addItem(pause)
        pauseItem = pause
        menu.addItem(menuItem("Sådan virker det", #selector(showWelcome), key: ""))
        menu.addItem(menuItem("Indstillinger …", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Afslut Bumlebee", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        updateStatus()
    }

    private func menuItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateStatus() {
        pauseItem?.title = Prefs.isPaused ? "Genoptag Bumlebee" : "Sæt på pause"
        statusItem?.button?.appearsDisabled = Prefs.isPaused
    }

    @objc private func chooseFilesToConvert() { chooseFiles(mode: .convert) }
    @objc private func chooseFilesForTools() { chooseFiles(mode: .tools) }

    @objc private func togglePause() {
        Prefs.isPaused.toggle()
        updateStatus()
    }

    @objc private func showWelcome() { Windows.openWelcome() }
    @objc private func showSettings() { Windows.openSettings() }

    private func chooseFiles(mode: WheelMode) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Vælg"
        panel.message = "Vælg de filer, Bumlebee skal arbejde med."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        showWheel(for: panel.urls, mode: mode, at: screenCenter())
    }

    private func showWheel(for urls: [URL], mode: WheelMode, at point: NSPoint) {
        wheel.show(urls: urls, mode: mode, at: point, clickMode: true)
    }

    private func screenCenter() -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    /// Just below the menu bar icon.
    private func belowStatusItem() -> NSPoint {
        guard let frame = statusItem?.button?.window?.frame else { return screenCenter() }
        return NSPoint(x: frame.midX, y: frame.minY - WheelGeometry.center.y - 8)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateStatus()
    }
}

extension AppDelegate: NSWindowDelegate, NSDraggingDestination {
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return false }
        let mode: WheelMode = NSEvent.modifierFlags.contains(.option) ? .tools : .convert
        let point = belowStatusItem()
        Task { @MainActor in
            self.showWheel(for: urls, mode: mode, at: point)
        }
        return true
    }
}
