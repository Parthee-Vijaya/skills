import AppKit
import PDFKit
import UniformTypeIdentifiers

/// PDF conversion and page tools on top of PDFKit and Quartz.
enum PDFEngine {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw BumlebeeError.failed("\(url.lastPathComponent) kunne ikke åbnes som PDF.")
        }
        if document.isLocked {
            throw BumlebeeError.failed("\(url.lastPathComponent) er beskyttet med adgangskode.")
        }
        return document
    }

    static func save(_ document: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        let ok = options.isEmpty ? document.write(to: url) : document.write(to: url, withOptions: options)
        guard ok else { throw BumlebeeError.failed("Kunne ikke gemme \(url.lastPathComponent).") }
    }

    /// Renders a page to a bitmap on white. `scale` 1 is 72 dpi.
    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        var size = bounds.size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let pixelSize = CGSize(width: max(size.width * scale, 1), height: max(size.height * scale, 1))
        let thumbnail = page.thumbnail(of: pixelSize, for: .mediaBox)
        var rect = CGRect(origin: .zero, size: thumbnail.size)
        guard let image = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return ImageEngine.flattened(image)
    }

    // MARK: Conversion

    static func convert(_ url: URL, to format: Format, context: JobContext) async throws -> [URL] {
        let document = try open(url)
        switch format {
        case .png, .jpg, .tiff:
            return [try exportImages(document, source: url, format: format, context: context)]
        case .txt:
            let output = Output.url(for: url, ext: "txt")
            try (document.string ?? "").write(to: output, atomically: true, encoding: .utf8)
            return [output]
        case .docx, .rtf, .html:
            let text = document.selectionForEntireDocument?.attributedString ?? NSAttributedString(string: document.string ?? "")
            let output = Output.url(for: url, ext: format.fileExtension)
            try DocumentEngine.write(text, to: output, format: format)
            return [output]
        default:
            throw BumlebeeError.unsupported("PDF kan ikke konverteres til \(format.label).")
        }
    }

    private static func exportImages(_ document: PDFDocument, source: URL, format: Format, context: JobContext) throws -> URL {
        let count = document.pageCount
        guard count > 0 else { throw BumlebeeError.failed("PDF'en har ingen sider.") }
        if count == 1, let page = document.page(at: 0), let image = render(page, scale: 2) {
            let output = Output.url(for: source, ext: format.fileExtension)
            try ImageEngine.write(image, to: output, format: format)
            return output
        }
        let folder = try Output.folder(for: source, suffix: "sider")
        let digits = String(count).count
        for index in 0..<count {
            try context.checkCancelled()
            guard let page = document.page(at: index), let image = render(page, scale: 2) else { continue }
            let number = String(format: "%0\(digits)d", index + 1)
            let output = folder.appendingPathComponent("Side \(number).\(format.fileExtension)")
            try ImageEngine.write(image, to: output, format: format)
            context.progress(Double(index + 1) / Double(count))
        }
        return folder
    }

    static func makePDF(fromImages urls: [URL], to output: URL) throws {
        let document = PDFDocument()
        for url in urls {
            let image = try ImageEngine.loadImage(url)
            // Keep full resolution, but give the page a sensible physical size (longest side ≈ A4).
            let longest = CGFloat(max(image.width, image.height))
            let scale = min(1, 842 / longest)
            let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            guard let page = PDFPage(image: NSImage(cgImage: image, size: size)) else { continue }
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount > 0 else { throw BumlebeeError.failed("Ingen billeder kunne læses.") }
        try save(document, to: output)
    }

    // MARK: Tools

    static func compress(_ url: URL, context: JobContext) async throws -> URL {
        let document = try open(url)
        let output = Output.url(for: url, ext: "pdf", suffix: "komprimeret")
        try save(document, to: output, options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        context.progress(0.5)
        // Scanned PDFs rarely shrink that way; rasterising them does.
        if fileSize(output) >= fileSize(url) {
            let temp = try Output.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let rasterized = temp.appendingPathComponent("r.pdf")
            try rasterize(document, to: rasterized, scale: 1.5, quality: 0.6, context: context)
            if fileSize(rasterized) < fileSize(output) {
                try FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: rasterized, to: output)
            }
        }
        context.progress(1)
        return output
    }

    static func fit(_ url: URL, toBytes bytes: Int, context: JobContext) async throws -> URL {
        let document = try open(url)
        let output = Output.url(for: url, ext: "pdf", suffix: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        let temp = try Output.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let optimized = temp.appendingPathComponent("o.pdf")
        try save(document, to: optimized, options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        if fileSize(optimized) <= bytes {
            try FileManager.default.moveItem(at: optimized, to: output)
            return output
        }
        let attempts: [(CGFloat, Double)] = [(2, 0.7), (1.5, 0.6), (1.25, 0.45), (1, 0.35), (0.8, 0.25), (0.6, 0.2)]
        for (index, attempt) in attempts.enumerated() {
            try context.checkCancelled()
            let candidate = temp.appendingPathComponent("r\(index).pdf")
            try rasterize(document, to: candidate, scale: attempt.0, quality: attempt.1, context: context.step(index, of: attempts.count))
            if fileSize(candidate) <= bytes {
                try FileManager.default.moveItem(at: candidate, to: output)
                return output
            }
        }
        throw BumlebeeError.failed("\(url.lastPathComponent) kunne ikke gøres så lille uden at blive ulæselig.")
    }

    /// Redraws every page as a JPEG. Quartz embeds JPEG data as-is, which keeps the file small.
    static func rasterize(_ document: PDFDocument, to output: URL, scale: CGFloat, quality: Double, context: JobContext) throws {
        guard let pdf = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw BumlebeeError.failed("Kunne ikke oprette PDF.")
        }
        for index in 0..<document.pageCount {
            try context.checkCancelled()
            guard let page = document.page(at: index), let image = render(page, scale: scale),
                  let data = ImageEngine.encode(image, format: .jpg, quality: quality),
                  let provider = CGDataProvider(data: data as CFData),
                  let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { continue }
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            pdf.beginPage(mediaBox: &box)
            pdf.draw(jpeg, in: box)
            pdf.endPage()
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        pdf.closePDF()
    }

    static func merge(_ urls: [URL], context: JobContext) async throws -> URL {
        guard let first = urls.first else { throw BumlebeeError.failed("Ingen filer.") }
        let result = PDFDocument()
        for (index, url) in urls.enumerated() {
            try context.checkCancelled()
            if FileKind.of(url) == .image {
                let image = try ImageEngine.loadImage(url)
                if let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) {
                    result.insert(page, at: result.pageCount)
                }
            } else {
                let document = try open(url)
                for pageIndex in 0..<document.pageCount {
                    if let page = document.page(at: pageIndex)?.copy() as? PDFPage {
                        result.insert(page, at: result.pageCount)
                    }
                }
            }
            context.progress(Double(index + 1) / Double(urls.count))
        }
        let output = Output.url(named: "\(first.baseName) (samlet)", beside: first, ext: "pdf")
        try save(result, to: output)
        return output
    }

    static func split(_ url: URL, context: JobContext) async throws -> URL {
        let document = try open(url)
        let folder = try Output.folder(for: url, suffix: "opdelt")
        let digits = String(document.pageCount).count
        for index in 0..<document.pageCount {
            try context.checkCancelled()
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let number = String(format: "%0\(digits)d", index + 1)
            try save(single, to: folder.appendingPathComponent("\(url.baseName) – side \(number).pdf"))
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        return folder
    }

    static func rotate(_ url: URL, context: JobContext) async throws -> URL {
        let document = try open(url)
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) { page.rotation = (page.rotation + 90) % 360 }
        }
        let output = Output.url(for: url, ext: "pdf", suffix: "roteret")
        try save(document, to: output)
        context.progress(1)
        return output
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let document = try open(url)
        document.documentAttributes = [:]
        let output = Output.url(for: url, ext: "pdf", suffix: "uden metadata")
        try save(document, to: output)
        return output
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
