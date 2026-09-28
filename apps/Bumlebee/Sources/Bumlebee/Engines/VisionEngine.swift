import CoreImage
import Foundation
import PDFKit
import Vision

/// On-device image understanding: background removal and QR/barcode reading.
enum VisionEngine {
    static func removeBackground(_ url: URL, context: JobContext) async throws -> URL {
        let image = try ImageEngine.loadImage(url)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        try context.checkCancelled()
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw BumlebeeError.failed("Bumlebee kunne ikke finde et motiv i \(url.lastPathComponent).")
        }
        let buffer = try result.generateMaskedImage(
            ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false
        )
        let masked = CIImage(cvPixelBuffer: buffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cutout = CIContext().createCGImage(masked, from: masked.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw BumlebeeError.failed("Kunne ikke gemme udklippet.")
        }
        let output = Output.url(for: url, ext: "png", suffix: "uden baggrund")
        try ImageEngine.write(cutout, to: output, format: .png)
        context.progress(1)
        return output
    }

    /// Reads every QR code and barcode in the given images or PDFs.
    static func readCodes(in urls: [URL]) throws -> [String] {
        var payloads: [String] = []
        for url in urls {
            let images: [CGImage]
            if FileKind.of(url) == .pdf {
                guard let document = PDFDocument(url: url) else { continue }
                images = (0..<min(document.pageCount, 30)).compactMap { index in
                    document.page(at: index).flatMap { PDFEngine.render($0, scale: 2) }
                }
            } else {
                images = [try ImageEngine.loadImage(url)]
            }
            for image in images {
                let request = VNDetectBarcodesRequest()
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                for observation in request.results ?? [] {
                    if let payload = observation.payloadStringValue, !payloads.contains(payload) {
                        payloads.append(payload)
                    }
                }
            }
        }
        return payloads
    }
}
