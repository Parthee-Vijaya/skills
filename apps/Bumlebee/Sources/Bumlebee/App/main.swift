import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let arguments = CommandLine.arguments

    // `Bumlebee --selftest [folder]` runs the engines headlessly (used by CI) and exits.
    if let flag = arguments.firstIndex(of: "--selftest") {
        let folder = flag + 1 < arguments.count
            ? URL(fileURLWithPath: arguments[flag + 1])
            : FileManager.default.temporaryDirectory.appendingPathComponent("bumlebee-selftest")
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            exit(await SelfTest.run(in: folder))
        }
        app.run()
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    // A menu bar app: no Dock icon, no main menu.
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
