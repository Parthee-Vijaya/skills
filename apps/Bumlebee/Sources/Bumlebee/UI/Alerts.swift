import AppKit

/// Small modal dialogs. Bumlebee lives in the menu bar, so every dialog activates the app first.
@MainActor
enum Alerts {
    static func error(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        run(alert)
    }

    static func info(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        run(alert)
    }

    /// Shows text the user will likely want to copy, such as decoded QR codes.
    static func results(title: String, lines: [String]) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Kopiér")
        let firstLink = lines.lazy.compactMap { URL(string: $0) }.first { ["http", "https", "mailto", "tel"].contains($0.scheme?.lowercased() ?? "") }
        if firstLink != nil { alert.addButton(withTitle: "Åbn link") }
        alert.addButton(withTitle: "Luk")
        switch run(alert) {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        case .alertSecondButtonReturn:
            if let firstLink { NSWorkspace.shared.open(firstLink) }
        default:
            break
        }
    }

    @discardableResult
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        alert.window.level = .modalPanel
        return alert.runModal()
    }
}

/// Asks for the one number a tool needs before it runs.
@MainActor
enum Prompts {
    /// Returns bytes.
    static func targetSize(defaultValue: Double, defaultUnit: String, fileName: String) -> Int? {
        let field = NSTextField(string: formatNumber(defaultValue))
        field.frame = NSRect(x: 0, y: 0, width: 110, height: 24)
        let unit = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24), pullsDown: false)
        unit.addItems(withTitles: ["KB", "MB", "GB"])
        unit.selectItem(withTitle: defaultUnit)
        let stack = NSStackView(views: [field, unit])
        stack.orientation = .horizontal
        stack.frame = NSRect(x: 0, y: 0, width: 200, height: 26)

        let alert = NSAlert()
        alert.messageText = "Hvor stor må filen højst være?"
        alert.informativeText = "Bumlebee finder den bedste kvalitet for \(fileName), der holder sig under grænsen."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Komprimér")
        alert.addButton(withTitle: "Annullér")
        alert.window.initialFirstResponder = field
        guard Alerts.run(alert) == .alertFirstButtonReturn, let value = parseNumber(field.stringValue), value > 0 else { return nil }
        let multiplier: Double
        switch unit.titleOfSelectedItem {
        case "KB": multiplier = 1_000
        case "GB": multiplier = 1_000_000_000
        default: multiplier = 1_000_000
        }
        return Int(value * multiplier)
    }

    static func resize() -> ImageEngine.ResizeSpec? {
        let options: [(String, ImageEngine.ResizeSpec)] = [
            ("75 %", .percent(75)), ("50 %", .percent(50)), ("25 %", .percent(25)),
            ("Længste side 3840 px (4K)", .maxSide(3840)), ("Længste side 2048 px", .maxSide(2048)),
            ("Længste side 1920 px (Full HD)", .maxSide(1920)), ("Længste side 1280 px", .maxSide(1280)),
            ("Længste side 800 px", .maxSide(800)), ("Længste side 512 px", .maxSide(512)),
        ]
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.addItems(withTitles: options.map(\.0) + ["Egen længste side …"])
        popup.selectItem(at: 1)
        let field = NSTextField(string: "1600")
        field.placeholderString = "px"
        field.frame = NSRect(x: 0, y: 0, width: 80, height: 24)
        let stack = NSStackView(views: [popup, field])
        stack.orientation = .horizontal
        stack.frame = NSRect(x: 0, y: 0, width: 350, height: 26)

        let alert = NSAlert()
        alert.messageText = "Skalér billede"
        alert.informativeText = "Vælg en størrelse. Feltet til højre bruges, når du vælger \"Egen længste side\"."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Skalér")
        alert.addButton(withTitle: "Annullér")
        guard Alerts.run(alert) == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        if index < options.count { return options[index].1 }
        guard let pixels = parseNumber(field.stringValue), pixels >= 16 else { return nil }
        return .maxSide(Int(pixels))
    }

    static func speed() -> Double? {
        let factors: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        popup.addItems(withTitles: factors.map { formatNumber($0) + "×" + ($0 < 1 ? "  (langsommere)" : "  (hurtigere)") })
        popup.selectItem(at: 5)
        let alert = NSAlert()
        alert.messageText = "Skift hastighed"
        alert.informativeText = "Tonehøjden bevares."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Anvend")
        alert.addButton(withTitle: "Annullér")
        guard Alerts.run(alert) == .alertFirstButtonReturn else { return nil }
        return factors[popup.indexOfSelectedItem]
    }

    static func compressionLevel() -> VideoEngine.CompressionLevel? {
        let levels = VideoEngine.CompressionLevel.allCases
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.addItems(withTitles: levels.map(\.title))
        popup.selectItem(at: 1)
        let alert = NSAlert()
        alert.messageText = "Komprimér video"
        alert.informativeText = "Videoen gemmes som HEVC (H.265) i MP4."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Komprimér")
        alert.addButton(withTitle: "Annullér")
        guard Alerts.run(alert) == .alertFirstButtonReturn else { return nil }
        return levels[popup.indexOfSelectedItem]
    }

    static func subtitleShift() -> Double? {
        let field = NSTextField(string: "1,0")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        let alert = NSAlert()
        alert.messageText = "Forskyd undertekster"
        alert.informativeText = "Antal sekunder. Positive tal gør teksterne senere, negative gør dem tidligere."
        alert.accessoryView = field
        alert.addButton(withTitle: "Forskyd")
        alert.addButton(withTitle: "Annullér")
        alert.window.initialFirstResponder = field
        guard Alerts.run(alert) == .alertFirstButtonReturn else { return nil }
        return parseNumber(field.stringValue)
    }

    static func parseNumber(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: "."))
    }

    static func formatNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "da_DK")
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
