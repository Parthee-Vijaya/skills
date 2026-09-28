import AppKit
import SwiftUI

/// Opens and keeps track of Bumlebee's regular windows.
@MainActor
enum Windows {
    private final class Entry {
        let window: NSWindow
        var observer: NSObjectProtocol?
        init(window: NSWindow) { self.window = window }
    }

    private static var entries: [String: Entry] = [:]

    @discardableResult
    static func present<Content: View>(
        id: String, title: String, size: NSSize, resizable: Bool = true, content: () -> Content
    ) -> NSWindow {
        if let existing = entries[id]?.window {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.setContentSize(size)
        window.center()

        let entry = Entry(window: window)
        entry.observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let observer = entries[id]?.observer { NotificationCenter.default.removeObserver(observer) }
                entries[id] = nil
            }
        }
        entries[id] = entry
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    static func close(id: String) {
        entries[id]?.window.close()
    }

    static func openEditor(for url: URL, mode: ImageEditorModel.Mode) {
        do {
            let model = try ImageEditorModel(url: url, mode: mode)
            let id = "editor." + url.path
            present(id: id, title: "Redigér – \(url.lastPathComponent)", size: NSSize(width: 1040, height: 700)) {
                ImageEditorView(model: model) { close(id: id) }
            }
        } catch {
            Alerts.error(title: "Kunne ikke åbne billedet", message: error.localizedDescription)
        }
    }

    static func openPlayer(for url: URL, startTrimming: Bool) {
        let id = "player." + url.path
        let model = PlayerModel(url: url, startTrimming: startTrimming)
        present(id: id, title: url.lastPathComponent, size: NSSize(width: 820, height: 560)) {
            PlayerView(model: model)
        }
    }

    static func openMetadata(for url: URL) {
        let id = "metadata." + url.path
        present(id: id, title: "Metadata – \(url.lastPathComponent)", size: NSSize(width: 620, height: 640)) {
            MetadataView(url: url)
        }
    }

    static func openOrganizer(for url: URL) {
        do {
            let model = try PDFOrganizerModel(url: url)
            let id = "organizer." + url.path
            present(id: id, title: "Organisér – \(url.lastPathComponent)", size: NSSize(width: 560, height: 680)) {
                PDFOrganizerView(model: model) { close(id: id) }
            }
        } catch {
            Alerts.error(title: "Kunne ikke åbne PDF'en", message: error.localizedDescription)
        }
    }

    static func openSettings() {
        present(id: "settings", title: "Bumlebee – Indstillinger", size: NSSize(width: 520, height: 560), resizable: false) {
            SettingsView()
        }
    }

    static func openWelcome() {
        present(id: "welcome", title: "Velkommen til Bumlebee", size: NSSize(width: 560, height: 600), resizable: false) {
            WelcomeView { close(id: "welcome") }
        }
    }
}
