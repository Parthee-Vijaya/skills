import AppKit

/// Text document conversion via AppKit's attributed-string importers and exporters.
enum DocumentEngine {
    @MainActor
    static func convert(_ url: URL, to format: Format) async throws -> URL {
        let text = try read(url)
        let output = Output.url(for: url, ext: format.fileExtension)
        if format == .pdf {
            try renderPDF(text, to: output)
        } else {
            try write(text, to: output, format: format)
        }
        return output
    }

    /// Reads any document AppKit understands. HTML import uses WebKit, so this must run on the main thread.
    @MainActor
    static func read(_ url: URL) throws -> NSAttributedString {
        switch url.normalizedExtension {
        case "md":
            let markdown = try String(contentsOf: url, encoding: .utf8)
            let html = Markdown.html(from: markdown)
            guard let data = html.data(using: .utf8),
                  let text = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            else { return NSAttributedString(string: markdown) }
            return text
        case "txt", "text", "srt", "vtt":
            let string = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .isoLatin1)
            return NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        default:
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }
    }

    static func write(_ text: NSAttributedString, to url: URL, format: Format) throws {
        let range = NSRange(location: 0, length: text.length)
        switch format {
        case .txt:
            try text.string.write(to: url, atomically: true, encoding: .utf8)
        case .md:
            try Markdown.markdown(from: text).write(to: url, atomically: true, encoding: .utf8)
        case .rtf:
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)
        case .docx:
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: url)
        case .odt:
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument]).write(to: url)
        case .html:
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]).write(to: url)
        default:
            throw BumlebeeError.unsupported("Dokumenter kan ikke gemmes som \(format.label).")
        }
    }

    /// Paginates the text onto A4 pages with AppKit's text system, which also handles tables and images.
    @MainActor
    static func renderPDF(_ text: NSAttributedString, to url: URL) throws {
        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 595, height: 842)
        printInfo.topMargin = 56
        printInfo.bottomMargin = 56
        printInfo.leftMargin = 56
        printInfo.rightMargin = 56
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.textStorage?.setAttributedString(text)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
            let used = textView.layoutManager?.usedRect(for: container).height ?? 100
            textView.setFrameSize(NSSize(width: width, height: max(used + 20, 100)))
        }

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw BumlebeeError.failed("Kunne ikke lave PDF.") }
    }

    struct Stats {
        let characters: Int
        let charactersWithoutSpaces: Int
        let words: Int
        let lines: Int
        let paragraphs: Int

        var readingMinutes: Int { max(1, Int((Double(words) / 230).rounded())) }
    }

    static func stats(for string: String) -> Stats {
        var words = 0
        string.enumerateSubstrings(in: string.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        let lines = string.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        let paragraphs = string.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        return Stats(
            characters: string.count,
            charactersWithoutSpaces: string.filter { !$0.isWhitespace }.count,
            words: words,
            lines: lines,
            paragraphs: paragraphs
        )
    }
}
