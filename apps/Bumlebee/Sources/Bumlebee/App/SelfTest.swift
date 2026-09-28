@preconcurrency import AVFoundation
import AppKit
import CoreImage
import PDFKit

/// `Bumlebee --selftest <folder>` generates sample files and runs every engine against them.
/// CI uses it to check conversions on a real Mac without clicking through the UI.
@MainActor
enum SelfTest {
    private static var failures: [String] = []
    private static var warnings: [String] = []
    private static let context = JobContext { @Sendable _, _ in }

    static func run(in directory: URL) async -> Int32 {
        Prefs.registerDefaults()
        UserDefaults.standard.set(OutputLocation.besideOriginal.rawValue, forKey: Prefs.Key.outputLocation)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("Bumlebee self-test in \(directory.path)")
        print("ffmpeg: \(FFmpeg.path ?? "not found")")
        print("ImageIO can write: \(Format.allCases.filter { ImageEngine.canWrite($0) }.map(\.label).joined(separator: ", "))")

        do {
            let samples = try await makeSamples(in: directory)
            await testImages(samples)
            await testAudio(samples)
            await testVideo(samples)
            await testDocuments(samples)
            await testPDF(samples)
            await testSubtitles(samples)
            await testArchives(samples)
            await testMetadata(samples)
            testCatalog(samples)
        } catch {
            failures.append("sample generation: \(error.localizedDescription)")
        }

        print("")
        warnings.forEach { print("⚠︎ \($0)") }
        if failures.isEmpty {
            print("✅ All checks passed (\(warnings.count) warnings)")
            return 0
        }
        failures.forEach { print("❌ \($0)") }
        print("\(failures.count) check(s) failed")
        return 1
    }

    // MARK: Checks

    private static func check(_ name: String, soft: Bool = false, _ body: () async throws -> [URL]) async {
        do {
            let outputs = try await body()
            guard !outputs.isEmpty else { throw BumlebeeError.failed("no output") }
            for output in outputs {
                let size = size(of: output)
                guard FileManager.default.fileExists(atPath: output.path), size > 0 else {
                    throw BumlebeeError.failed("missing or empty output \(output.lastPathComponent)")
                }
            }
            let summary = outputs.map { "\($0.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(size(of: $0)), countStyle: .file)))" }
            print("✓ \(name) → \(summary.joined(separator: ", "))")
        } catch {
            let message = "\(name): \(error.localizedDescription)"
            if soft {
                warnings.append(message)
                print("⚠︎ \(message)")
            } else {
                failures.append(message)
                print("✗ \(message)")
            }
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw BumlebeeError.failed(message) }
    }

    private static func size(of url: URL) -> Int {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            return (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
        }
        return PDFEngine.fileSize(url)
    }

    private static func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    private static func imageSize(_ url: URL) throws -> CGSize {
        let image = try ImageEngine.loadImage(url)
        return CGSize(width: image.width, height: image.height)
    }

    // MARK: Images

    private static func testImages(_ s: Samples) async {
        for format in [Format.jpg, .png, .heic, .tiff, .bmp, .gif, .pdf, .ico, .webp, .avif] {
            let availability = Converter.availability(of: format, for: s.png)
            if case .unavailable(let reason) = availability {
                warnings.append("PNG → \(format.label) unavailable: \(reason)")
                continue
            }
            await check("image PNG → \(format.label)", soft: format == .heic || format == .avif) {
                let outputs = try await Converter.convert(s.png, to: format, context: context)
                if format != .pdf, format != .ico {
                    let size = try imageSize(outputs[0])
                    try expect(size.width == 640 && size.height == 480, "unexpected size \(size)")
                }
                return outputs
            }
        }
        await check("image compress JPG") { [try await ImageEngine.compress(s.jpg, context: context)] }
        await check("image compress PNG (alpha)") { [try await ImageEngine.compress(s.png, context: context)] }
        await check("image fit 40 KB") {
            let output = try await ImageEngine.fit(s.jpg, toBytes: 40_000, context: context)
            try expect(size(of: output) <= 40_000, "too big: \(size(of: output))")
            return [output]
        }
        await check("image resize 50 %") {
            let output = try await ImageEngine.resize(s.jpg, spec: .percent(50), context: context)
            try expect(try imageSize(output).width == 320, "wrong width")
            return [output]
        }
        await check("image resize to 1000 px (upscale)") {
            let output = try await ImageEngine.resize(s.jpg, spec: .maxSide(1000), context: context)
            try expect(try imageSize(output).width == 1000, "wrong width")
            return [output]
        }
        await check("image rotate") {
            let output = try await ImageEngine.rotate(s.jpg, context: context)
            try expect(try imageSize(output) == CGSize(width: 480, height: 640), "not rotated")
            return [output]
        }
        await check("image strip metadata") {
            let output = try ImageEngine.stripMetadata(s.jpg)
            let exif = ImageEngine.metadata(output)[kCGImagePropertyExifDictionary] as? [String: Any]
            try expect(exif?[kCGImagePropertyExifUserComment as String] == nil, "EXIF comment survived")
            return [output]
        }
        await check("image collage") { [try await ImageEngine.collage(from: [s.jpg, s.png, s.qr], context: context)] }
        await check("image GIF from images") { [try await ImageEngine.makeGIF(from: [s.jpg, s.png], context: context)] }
        await check("images → one PDF") {
            let output = Output.url(named: "combined", beside: s.jpg, ext: "pdf")
            try PDFEngine.makePDF(fromImages: [s.jpg, s.png], to: output)
            try expect(PDFDocument(url: output)?.pageCount == 2, "wrong page count")
            return [output]
        }
        await check("QR read", soft: true) {
            let codes = try VisionEngine.readCodes(in: [s.qr])
            try expect(codes == ["https://bumlebee.example/honning"], "decoded \(codes)")
            return [s.qr]
        }
        await check("remove background", soft: true) { [try await VisionEngine.removeBackground(s.jpg, context: context)] }
    }

    // MARK: Audio

    private static func testAudio(_ s: Samples) async {
        for format in [Format.m4a, .flac, .aiff, .caf, .wav, .mp3, .ogg] {
            if case .unavailable(let reason) = Converter.availability(of: format, for: s.wav) {
                warnings.append("WAV → \(format.label) unavailable: \(reason)")
                continue
            }
            await check("audio WAV → \(format.label)") {
                let outputs = try await Converter.convert(s.wav, to: format, context: context)
                if MediaSupport.isNativelyReadable(outputs[0]) {
                    let seconds = try await duration(outputs[0])
                    try expect(abs(seconds - 3) < 0.2, "duration \(seconds)")
                }
                return outputs
            }
        }
        await check("audio compress") { [try await AudioEngine.compress(s.wav, context: context)] }
        await check("audio fit 60 KB") {
            let output = try await AudioEngine.fit(s.wav, toBytes: 60_000, context: context)
            try expect(size(of: output) <= 60_000, "too big: \(size(of: output))")
            return [output]
        }
        await check("audio normalize") {
            let output = try await AudioEngine.normalize(s.wav, context: context)
            let peak = try await AudioEngine.peakLevel(output, context: context)
            try expect(peak > 0.85 && peak < 0.95, "peak \(peak)")
            return [output]
        }
        await check("audio mono") {
            let output = try await AudioEngine.setChannels(s.wav, channels: 1, context: context)
            try expect(try await AudioEngine.audioInfo(output).channels == 1, "not mono")
            return [output]
        }
        await check("audio trim 1 s") {
            let range = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600), duration: CMTime(seconds: 1, preferredTimescale: 600))
            let output = try await AudioEngine.trim(s.wav, range: range, context: context)
            let seconds = try await duration(output)
            try expect(abs(seconds - 1) < 0.1, "duration \(seconds)")
            return [output]
        }
        await check("audio join") {
            let output = try await AudioEngine.join([s.wav, s.wav], context: context)
            let seconds = try await duration(output)
            try expect(abs(seconds - 6) < 0.2, "duration \(seconds)")
            return [output]
        }
        await check("audio speed 2×") { [try await VideoEngine.changeSpeed(s.wav, factor: 2, context: context)] }
    }

    // MARK: Video

    private static func testVideo(_ s: Samples) async {
        await check("video MOV → MP4") { try await Converter.convert(s.mov, to: .mp4, context: context) }
        await check("video → GIF") { try await Converter.convert(s.mp4, to: .gif, context: context) }
        await check("video → M4A") { try await Converter.convert(s.mp4, to: .m4a, context: context) }
        await check("video → WAV") { try await Converter.convert(s.mp4, to: .wav, context: context) }
        for format in [Format.mkv, .webm, .mp3] {
            if case .unavailable = Converter.availability(of: format, for: s.mp4) { continue }
            await check("video → \(format.label) (ffmpeg)") { try await Converter.convert(s.mp4, to: format, context: context) }
        }
        await check("video compress") { [try await VideoEngine.compress(s.mp4, level: .small, context: context)] }
        await check("video fit 300 KB") {
            let output = try await VideoEngine.fit(s.mp4, toBytes: 300_000, context: context)
            try expect(size(of: output) <= 330_000, "too big: \(size(of: output))")
            return [output]
        }
        await check("video trim") {
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
            return [try await VideoEngine.trim(s.mp4, range: range, context: context)]
        }
        await check("video split") { try await VideoEngine.split(s.mp4, at: CMTime(seconds: 1, preferredTimescale: 600), context: context) }
        await check("video snapshot") { [try await VideoEngine.snapshot(s.mp4, at: CMTime(seconds: 1, preferredTimescale: 600))] }
        await check("video speed 2×") {
            let output = try await VideoEngine.changeSpeed(s.mp4, factor: 2, context: context)
            let seconds = try await duration(output)
            try expect(abs(seconds - 1) < 0.2, "duration \(seconds)")
            return [output]
        }
        await check("video mute") {
            let output = try await VideoEngine.mute(s.mp4, context: context)
            try expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).isEmpty, "still has audio")
            return [output]
        }
        await check("video extract audio") { [try await VideoEngine.extractAudio(s.mp4, context: context)] }
        await check("video rotate") { [try await VideoEngine.rotate(s.mp4, context: context)] }
        await check("video join") {
            let output = try await VideoEngine.join([s.mp4, s.mp4], context: context)
            let seconds = try await duration(output)
            try expect(abs(seconds - 4) < 0.3, "duration \(seconds)")
            return [output]
        }
    }

    // MARK: Documents, PDF, subtitles, archives

    private static func testDocuments(_ s: Samples) async {
        for format in [Format.pdf, .docx, .rtf, .html, .odt, .txt] {
            await check("Markdown → \(format.label)") { try await Converter.convert(s.markdown, to: format, context: context) }
        }
        await check("TXT → DOCX → Markdown") {
            let docx = try await Converter.convert(s.text, to: .docx, context: context)[0]
            return try await Converter.convert(docx, to: .md, context: context)
        }
    }

    private static func testPDF(_ s: Samples) async {
        await check("PDF → PNG pages") { try await Converter.convert(s.pdf, to: .png, context: context) }
        await check("PDF → TXT") {
            let output = try await Converter.convert(s.pdf, to: .txt, context: context)[0]
            let text = try String(contentsOf: output, encoding: .utf8)
            try expect(text.contains("Bumlebee"), "text missing")
            return [output]
        }
        await check("PDF → DOCX") { try await Converter.convert(s.pdf, to: .docx, context: context) }
        await check("PDF compress") { [try await PDFEngine.compress(s.pdf, context: context)] }
        await check("PDF merge") {
            let output = try await PDFEngine.merge([s.pdf, s.pdf], context: context)
            try expect(PDFDocument(url: output)?.pageCount == 2 * (PDFDocument(url: s.pdf)?.pageCount ?? 0), "wrong pages")
            return [output]
        }
        await check("PDF split") { [try await PDFEngine.split(s.pdf, context: context)] }
        await check("PDF rotate") { [try await PDFEngine.rotate(s.pdf, context: context)] }
        await check("PDF fit 30 KB", soft: true) { [try await PDFEngine.fit(s.pdf, toBytes: 30_000, context: context)] }
        await check("PDF strip metadata") { [try PDFEngine.stripMetadata(s.pdf)] }
    }

    private static func testSubtitles(_ s: Samples) async {
        await check("SRT → VTT → SRT") {
            let vtt = try SubtitleEngine.convert(s.srt, to: .vtt)
            let back = try SubtitleEngine.convert(vtt, to: .srt)
            try expect(try SubtitleEngine.parse(back).count == 2, "lost cues")
            return [vtt, back]
        }
        await check("SRT shift +1.5 s") {
            let output = try SubtitleEngine.shift(s.srt, by: 1.5)
            try expect(abs(try SubtitleEngine.parse(output)[0].start - 2.5) < 0.01, "not shifted")
            return [output]
        }
    }

    private static func testArchives(_ s: Samples) async {
        var zip: URL?
        await check("folder → ZIP") {
            let output = try await ArchiveEngine.archive([s.folder], as: .zip, context: context)
            zip = output
            return [output]
        }
        await check("files → TAR.GZ") { [try await ArchiveEngine.archive([s.wav, s.srt], as: .tgz, context: context)] }
        await check("file → GZIP") { [try await ArchiveEngine.archive([s.text], as: .gz, context: context)] }
        if let zip {
            await check("ZIP extract") { [try await ArchiveEngine.extract(zip, context: context)] }
            await check("ZIP → TAR.GZ") { [try await ArchiveEngine.repack(zip, as: .tgz, context: context)] }
        }
    }

    private static func testMetadata(_ s: Samples) async {
        for url in [s.jpg, s.mp4, s.pdf, s.wav] {
            await check("metadata read \(url.pathExtension)") {
                let sections = await MetadataEngine.read(url)
                try expect(sections.count >= 2, "only \(sections.count) section(s)")
                return [url]
            }
        }
        await check("metadata write PDF title") {
            var fields = await MetadataEngine.editableFields(s.pdf)
            fields[0].value = "Honning"
            let output = try await MetadataEngine.write(s.pdf, fields: fields, context: context)
            let title = PDFDocument(url: output)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            try expect(title == "Honning", "title \(title ?? "nil")")
            return [output]
        }
        await check("metadata write image artist") {
            var fields = await MetadataEngine.editableFields(s.jpg)
            fields[1].value = "Bumlebee"
            return [try await MetadataEngine.write(s.jpg, fields: fields, context: context)]
        }
        await check("metadata write video title") {
            var fields = await MetadataEngine.editableFields(s.mp4)
            try expect(!fields.isEmpty, "no fields")
            fields[0].value = "Honning"
            return [try await MetadataEngine.write(s.mp4, fields: fields, context: context)]
        }
        await check("metadata strip video") { [try await MetadataEngine.strip(s.mp4, context: context)] }
    }

    private static func testCatalog(_ s: Samples) {
        for url in [s.jpg, s.mp4, s.wav, s.pdf, s.markdown, s.srt, s.folder] {
            for mode in [WheelMode.convert, .tools] {
                let items = Catalog.items(for: [url], mode: mode)
                if items.isEmpty || items.count > Catalog.maxItems {
                    failures.append("catalog \(url.lastPathComponent) \(mode): \(items.count) items")
                }
            }
        }
        print("✓ catalog")
    }

    // MARK: Samples

    struct Samples {
        let png, jpg, qr, wav, mov, mp4, text, markdown, pdf, srt, folder: URL
    }

    private static func makeSamples(in directory: URL) async throws -> Samples {
        let png = directory.appendingPathComponent("gradient.png")
        let jpg = directory.appendingPathComponent("photo.jpg")
        let qr = directory.appendingPathComponent("qr.png")
        let wav = directory.appendingPathComponent("tone.wav")
        let mov = directory.appendingPathComponent("clip.mov")
        let mp4 = directory.appendingPathComponent("clip with sound.mp4")
        let text = directory.appendingPathComponent("notes.txt")
        let markdown = directory.appendingPathComponent("readme.md")
        let srt = directory.appendingPathComponent("subs.srt")
        let folder = directory.appendingPathComponent("folder", isDirectory: true)

        // A 640×480 image with transparency, and an opaque "photo" with EXIF.
        let canvas = ImageEngine.makeContext(width: 640, height: 480)!
        let colors = [CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1), CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 0.4)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil)!
        canvas.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 640, y: 480), options: [])
        canvas.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        canvas.fillEllipse(in: CGRect(x: 220, y: 140, width: 200, height: 200))
        let art = canvas.makeImage()!
        try ImageEngine.write(art, to: png, format: .png)
        let exif: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Bumlebee test"]]
        try ImageEngine.write(ImageEngine.flattened(art), to: jpg, format: .jpg, quality: 0.95, metadata: exif)

        // A QR code with a quiet zone.
        let generator = CIFilter(name: "CIQRCodeGenerator")!
        generator.setValue(Data("https://bumlebee.example/honning".utf8), forKey: "inputMessage")
        let code = generator.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let codeImage = CIContext().createCGImage(code, from: code.extent)!
        let qrCanvas = ImageEngine.makeContext(width: codeImage.width + 80, height: codeImage.height + 80)!
        qrCanvas.setFillColor(CGColor(gray: 1, alpha: 1))
        qrCanvas.fill(CGRect(x: 0, y: 0, width: qrCanvas.width, height: qrCanvas.height))
        qrCanvas.interpolationQuality = .none
        qrCanvas.draw(codeImage, in: CGRect(x: 40, y: 40, width: codeImage.width, height: codeImage.height))
        try ImageEngine.write(qrCanvas.makeImage()!, to: qr, format: .png)

        try makeTone(at: wav, seconds: 3)
        try await makeVideo(at: mov, seconds: 2)
        // Video + audio in MP4, which also exercises composition export.
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: mov), audioAsset = AVURLAsset(url: wav)
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(range, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(range, of: audioTrack, at: .zero)
        try await MediaExport.export(composition, preset: AVAssetExportPresetHighestQuality, to: mp4, format: .mp4, context: context)

        try "Bumlebee\n\nEn lille tekst om honning.\nAnden linje.".write(to: text, atomically: true, encoding: .utf8)
        try """
        # Bumlebee

        En **fed** og *kursiv* tekst med `kode` og et [link](https://example.com).

        - Honning
        - Voks

        1. Første
        2. Anden
        """.write(to: markdown, atomically: true, encoding: .utf8)
        try "1\n00:00:01,000 --> 00:00:02,500\nHej\n\n2\n00:00:03,000 --> 00:00:04,000\nMed dig\n".write(to: srt, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "a".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let pdf = try await DocumentEngine.convert(markdown, to: .pdf)
        print("✓ samples")
        return Samples(png: png, jpg: jpg, qr: qr, wav: wav, mov: mov, mp4: mp4, text: text, markdown: markdown, pdf: pdf, srt: srt, folder: folder)
    }

    private static func makeTone(at url: URL, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for index in 0..<Int(frames) {
                samples[index] = 0.3 * sin(2 * .pi * 440 * Float(index) / Float(format.sampleRate))
            }
        }
        try file.write(from: buffer)
    }

    private static func makeVideo(at url: URL, seconds: Int) async throws {
        let width = 320, height = 240, fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? BumlebeeError.failed("writer") }
        writer.startSession(atSourceTime: .zero)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var pixelBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { throw BumlebeeError.failed("no pixel buffer pool") }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else { throw BumlebeeError.failed("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )!
            let t = CGFloat(frame) / CGFloat(seconds * fps)
            context.setFillColor(CGColor(red: t, green: 0.6, blue: 1 - t, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: t * CGFloat(width - 60), y: 90, width: 60, height: 60))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? BumlebeeError.failed("video writer") }
    }
}
