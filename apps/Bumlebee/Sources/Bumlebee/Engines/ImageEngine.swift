import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Image conversion and processing on top of ImageIO and Core Graphics.
enum ImageEngine {
    enum ResizeSpec {
        case percent(Double)
        case maxSide(Int)
    }

    // MARK: Capabilities

    private static let writableTypes: Set<String> = {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return Set(identifiers)
    }()

    static func canWrite(_ format: Format) -> Bool {
        guard let type = format.utType else { return false }
        return writableTypes.contains(type.identifier)
    }

    static func supportsAlpha(_ format: Format) -> Bool {
        ![.jpg, .bmp].contains(format)
    }

    // MARK: Reading

    static func metadata(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }
        return properties
    }

    static func frameCount(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    /// Decodes an image upright (EXIF orientation applied), optionally downscaled to `maxPixelSize`.
    static func loadImage(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0 {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let longest = max(width, height)
            let target = min(maxPixelSize ?? longest, longest > 0 ? longest : Int.max)
            if target > 0 {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: target,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    return image
                }
            }
            if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return image
            }
        }
        return try loadWithAppKit(url, maxPixelSize: maxPixelSize)
    }

    /// Fallback for formats only AppKit understands, such as SVG.
    private static func loadWithAppKit(_ url: URL, maxPixelSize: Int?) throws -> CGImage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw BumlebeeError.unsupported("\(url.lastPathComponent) kunne ikke læses som billede.")
        }
        // Vector images have no pixel size, so render them crisp at 2×.
        var scale: CGFloat = url.pathExtension.lowercased() == "svg" ? 2 : 1
        if let maxPixelSize {
            scale = min(scale, CGFloat(maxPixelSize) / max(image.size.width, image.size.height))
        }
        let width = max(Int(image.size.width * scale), 1)
        let height = max(Int(image.size.height * scale), 1)
        guard let context = makeContext(width: width, height: height) else {
            throw BumlebeeError.failed("Kunne ikke tegne billedet.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else { throw BumlebeeError.failed("Kunne ikke tegne billedet.") }
        return result
    }

    // MARK: Writing

    static func write(_ image: CGImage, to url: URL, format: Format, quality: Double? = nil, metadata: [CFString: Any]? = nil) throws {
        guard let type = format.utType, canWrite(format) else {
            throw BumlebeeError.unsupported("macOS kan ikke skrive \(format.label).")
        }
        var output = image
        if !supportsAlpha(format), hasAlpha(image) { output = flattened(image) }
        if format == .ico, max(output.width, output.height) > 256 { output = scaled(output, maxSide: 256) }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw BumlebeeError.failed("Kunne ikke oprette \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(destination, output, properties(for: format, quality: quality, metadata: metadata) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw BumlebeeError.failed("Kunne ikke gemme \(url.lastPathComponent).")
        }
    }

    static func encode(_ image: CGImage, format: Format, quality: Double) -> Data? {
        guard let type = format.utType else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        let source = !supportsAlpha(format) && hasAlpha(image) ? flattened(image) : image
        CGImageDestinationAddImage(destination, source, properties(for: format, quality: quality, metadata: nil) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func properties(for format: Format, quality: Double?, metadata: [CFString: Any]?) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        if let metadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
                if let value = metadata[key] { properties[key] = value }
            }
            // Pixels are already upright, so the orientation tag must say so.
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        properties[kCGImagePropertyOrientation] = 1
        if format.isLossyImage {
            properties[kCGImageDestinationLossyCompressionQuality] = quality ?? Prefs.imageQuality
        }
        return properties
    }

    // MARK: Conversion

    static func convert(_ url: URL, to format: Format, context: JobContext) async throws -> URL {
        let output = Output.url(for: url, ext: format.fileExtension)
        if format == .pdf {
            try PDFEngine.makePDF(fromImages: [url], to: output)
            return output
        }
        let image = try loadImage(url)
        try context.checkCancelled()
        try write(image, to: output, format: format, metadata: metadata(url))
        context.progress(1)
        return output
    }

    /// For formats ImageIO cannot write: decode natively (so HEIC, RAW and SVG work), then let ffmpeg encode.
    static func convertViaFFmpeg(_ url: URL, to format: Format, context: JobContext) async throws -> URL {
        let temp = try Output.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let png = temp.appendingPathComponent("frame.png")
        try write(try loadImage(url), to: png, format: .png)
        let output = Output.url(for: url, ext: format.fileExtension)
        try await FFmpeg.convert(png, to: output, arguments: FFmpeg.arguments(for: format, from: .image), context: context)
        return output
    }

    // MARK: Tools

    /// Re-encodes lossy images at lower quality. Lossless images become JPEG (or HEIC when they have transparency).
    static func compress(_ url: URL, context: JobContext) async throws -> URL {
        let image = try loadImage(url)
        let format = compressedFormat(for: url, image: image)
        let output = Output.url(for: url, ext: format.fileExtension, suffix: "komprimeret")
        try write(image, to: output, format: format, quality: min(Prefs.imageQuality, 0.6), metadata: metadata(url))
        context.progress(1)
        return output
    }

    /// Finds the highest quality (and, if needed, the largest size) that fits under `bytes`.
    static func fit(_ url: URL, toBytes bytes: Int, context: JobContext) async throws -> URL {
        var image = try loadImage(url)
        let format = compressedFormat(for: url, image: image)
        var best: Data?
        let maxAttempts = 10
        for attempt in 0..<maxAttempts {
            try context.checkCancelled()
            var low = 0.02, high = 0.95
            var found: Data?
            for _ in 0..<7 {
                let quality = (low + high) / 2
                guard let data = encode(image, format: format, quality: quality) else {
                    throw BumlebeeError.failed("Kunne ikke komprimere \(url.lastPathComponent).")
                }
                if data.count <= bytes { found = data; low = quality } else { high = quality }
            }
            if let found { best = found; break }
            image = scaled(image, factor: 0.75)
            context.progress(Double(attempt + 1) / Double(maxAttempts))
        }
        guard let best else {
            throw BumlebeeError.failed("\(url.lastPathComponent) kunne ikke gøres så lille.")
        }
        let output = Output.url(for: url, ext: format.fileExtension, suffix: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        try best.write(to: output)
        return output
    }

    static func resize(_ url: URL, spec: ResizeSpec, context: JobContext) async throws -> URL {
        let original = try loadImage(url)
        let longest = max(original.width, original.height)
        let target: Int
        switch spec {
        case .percent(let percent): target = max(Int(Double(longest) * percent / 100), 1)
        case .maxSide(let side): target = side
        }
        let image = target <= longest ? try loadImage(url, maxPixelSize: target) : scaled(original, factor: Double(target) / Double(longest))
        let format = writableFormat(sameAs: url)
        let output = Output.url(for: url, ext: format.fileExtension, suffix: "\(image.width)×\(image.height)")
        try write(image, to: output, format: format, metadata: metadata(url))
        context.progress(1)
        return output
    }

    static func rotate(_ url: URL, context: JobContext) async throws -> URL {
        let image = rotatedClockwise(try loadImage(url))
        let format = writableFormat(sameAs: url)
        let output = Output.url(for: url, ext: format.fileExtension, suffix: "roteret")
        try write(image, to: output, format: format, quality: max(Prefs.imageQuality, 0.92), metadata: metadata(url))
        context.progress(1)
        return output
    }

    /// Removes EXIF, GPS, IPTC and XMP without recompressing when ImageIO allows it.
    static func stripMetadata(_ url: URL, onlyLocation: Bool = false) throws -> URL {
        let output = Output.url(for: url, ext: url.pathExtension.lowercased(), suffix: onlyLocation ? "uden lokation" : "uden metadata")
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let type = CGImageSourceGetType(source),
           let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            var options: [CFString: Any] = [
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageDestinationOrientation: orientation,
            ]
            if !onlyLocation {
                options[kCGImageDestinationMetadata] = CGImageMetadataCreateMutable()
                options[kCGImageDestinationMergeMetadata] = false
                options[kCGImageMetadataShouldExcludeXMP] = true
            }
            if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) {
                return output
            }
        }
        // Fall back to re-encoding the pixels without any metadata.
        try? FileManager.default.removeItem(at: output)
        let format = writableFormat(sameAs: url)
        let fallback = output.pathExtension == format.fileExtension ? output : output.deletingPathExtension().appendingPathExtension(format.fileExtension)
        try write(try loadImage(url), to: fallback, format: format, quality: 0.95)
        return fallback
    }

    static func makeGIF(from urls: [URL], frameDelay: Double = 0.5, context: JobContext) async throws -> URL {
        guard let first = urls.first else { throw BumlebeeError.failed("Ingen billeder.") }
        let frames = try urls.map { try loadImage($0, maxPixelSize: 800) }
        let canvas = CGSize(width: frames[0].width, height: frames[0].height)
        let output = Output.url(named: "\(first.baseName) (animation)", beside: first, ext: "gif")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw BumlebeeError.failed("Kunne ikke oprette GIF.")
        }
        let fileProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDelay]]
        for (index, frame) in frames.enumerated() {
            try context.checkCancelled()
            CGImageDestinationAddImage(destination, fitted(frame, in: canvas), frameProperties as CFDictionary)
            context.progress(Double(index + 1) / Double(frames.count))
        }
        guard CGImageDestinationFinalize(destination) else { throw BumlebeeError.failed("Kunne ikke gemme GIF.") }
        return output
    }

    static func collage(from urls: [URL], context: JobContext) async throws -> URL {
        guard let first = urls.first else { throw BumlebeeError.failed("Ingen billeder.") }
        let columns = Int(ceil(sqrt(Double(urls.count))))
        let rows = Int(ceil(Double(urls.count) / Double(columns)))
        let cell = 900, gap = 16
        let width = columns * cell + (columns + 1) * gap
        let height = rows * cell + (rows + 1) * gap
        guard let canvas = makeContext(width: width, height: height) else { throw BumlebeeError.failed("Kunne ikke lave collage.") }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.interpolationQuality = .high
        for (index, url) in urls.enumerated() {
            try context.checkCancelled()
            let image = try loadImage(url, maxPixelSize: cell * 2)
            let column = index % columns
            let row = index / columns
            let frame = CGRect(
                x: gap + column * (cell + gap),
                y: height - (row + 1) * (cell + gap),
                width: cell, height: cell
            )
            // Aspect-fill each image into its square cell.
            let scale = max(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
            let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            canvas.saveGState()
            canvas.clip(to: frame)
            canvas.draw(image, in: CGRect(x: frame.midX - drawSize.width / 2, y: frame.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height))
            canvas.restoreGState()
            context.progress(Double(index + 1) / Double(urls.count))
        }
        guard let image = canvas.makeImage() else { throw BumlebeeError.failed("Kunne ikke lave collage.") }
        let output = Output.url(named: "\(first.baseName) (collage)", beside: first, ext: "jpg")
        try write(image, to: output, format: .jpg, quality: 0.9)
        return output
    }

    // MARK: Helpers

    static func writableFormat(sameAs url: URL) -> Format {
        if let format = Format(fileExtension: url.normalizedExtension), canWrite(format) { return format }
        return .png
    }

    private static func compressedFormat(for url: URL, image: CGImage) -> Format {
        if let format = Format(fileExtension: url.normalizedExtension), format.isLossyImage, canWrite(format) {
            return format
        }
        if hasAlpha(image) { return canWrite(.heic) ? .heic : .png }
        return .jpg
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace? = nil) -> CGContext? {
        let space = colorSpace?.model == .rgb ? colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    static func flattened(_ image: CGImage, background: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage {
        guard let context = makeContext(width: image.width, height: image.height, colorSpace: image.colorSpace) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(background)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    static func scaled(_ image: CGImage, factor: Double) -> CGImage {
        let width = max(Int(Double(image.width) * factor), 1)
        let height = max(Int(Double(image.height) * factor), 1)
        return scaled(image, to: CGSize(width: width, height: height))
    }

    static func scaled(_ image: CGImage, maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        return scaled(image, factor: Double(maxSide) / Double(longest))
    }

    static func scaled(_ image: CGImage, to size: CGSize) -> CGImage {
        guard let context = makeContext(width: Int(size.width), height: Int(size.height), colorSpace: image.colorSpace) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage() ?? image
    }

    /// Letterboxes `image` into a canvas of `size` on white.
    static func fitted(_ image: CGImage, in size: CGSize) -> CGImage {
        if CGFloat(image.width) == size.width, CGFloat(image.height) == size.height { return image }
        guard let context = makeContext(width: Int(size.width), height: Int(size.height), colorSpace: image.colorSpace) else { return image }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
        return context.makeImage() ?? image
    }

    static func rotatedClockwise(_ image: CGImage) -> CGImage {
        guard let context = makeContext(width: image.height, height: image.width, colorSpace: image.colorSpace) else { return image }
        context.translateBy(x: 0, y: CGFloat(image.width))
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
