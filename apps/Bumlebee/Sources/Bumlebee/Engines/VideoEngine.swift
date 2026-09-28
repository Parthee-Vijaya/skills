@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Video conversion and editing on top of AVFoundation.
enum VideoEngine {
    enum CompressionLevel: String, CaseIterable, Identifiable {
        case high, medium, small

        var id: String { rawValue }

        var title: String {
            switch self {
            case .high: return "Høj kvalitet (op til 1080p)"
            case .medium: return "Mellem (op til 720p)"
            case .small: return "Lille fil (op til 540p)"
            }
        }

        var maxDimension: Int {
            switch self {
            case .high: return 1920
            case .medium: return 1280
            case .small: return 960
            }
        }

        /// Bits per pixel per frame for HEVC.
        var quality: Double {
            switch self {
            case .high: return 0.07
            case .medium: return 0.05
            case .small: return 0.035
            }
        }
    }

    static func convert(_ url: URL, to format: Format, context: JobContext) async throws -> URL {
        switch format {
        case .gif:
            return try await makeGIF(url, context: context)
        case .m4a, .wav, .aiff, .caf, .flac:
            return try await AudioEngine.convert(url, to: format, context: context)
        default:
            let output = Output.url(for: url, ext: format.fileExtension)
            try await MediaExport.exportPreferringPassthrough(AVURLAsset(url: url), to: output, format: format, context: context)
            return output
        }
    }

    static func makeGIF(_ url: URL, maxDimension: CGFloat = 480, context: JobContext) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw BumlebeeError.failed("Kunne ikke læse længden af \(url.lastPathComponent).") }
        // Long clips get fewer frames per second so the GIF stays a sensible size.
        let fps: Double = duration <= 10 ? 12 : duration <= 30 ? 8 : 5
        let frameCount = max(1, min(Int(duration * fps), 360))
        let step = duration / Double(frameCount)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let output = Output.url(for: url, ext: "gif")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw BumlebeeError.failed("Kunne ikke oprette GIF.")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: step]] as CFDictionary
        for index in 0..<frameCount {
            try context.checkCancelled()
            let time = CMTime(seconds: Double(index) * step, preferredTimescale: 600)
            let frame = try await generator.image(at: time).image
            CGImageDestinationAddImage(destination, frame, frameProperties)
            context.progress(Double(index + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(destination) else { throw BumlebeeError.failed("Kunne ikke gemme GIF.") }
        return output
    }

    static func snapshot(_ url: URL, at time: CMTime) async throws -> URL {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: time).image
        let output = Output.url(for: url, ext: "png", suffix: "snapshot \(timestamp(time.seconds))")
        try ImageEngine.write(image, to: output, format: .png)
        return output
    }

    static func compress(_ url: URL, level: CompressionLevel, context: JobContext) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw BumlebeeError.failed("\(url.lastPathComponent) har intet videospor.")
        }
        let size = try await track.load(.naturalSize)
        let fps = Double(try await track.load(.nominalFrameRate))
        let longest = max(abs(size.width), abs(size.height))
        let scale = min(1, CGFloat(level.maxDimension) / max(longest, 1))
        let bitrate = VideoTranscoder.suggestedBitrate(
            width: Int(abs(size.width) * scale), height: Int(abs(size.height) * scale), fps: fps, quality: level.quality
        )
        let output = Output.url(for: url, ext: "mp4", suffix: "komprimeret")
        try await VideoTranscoder.transcode(url, to: output, settings: .init(maxDimension: level.maxDimension, videoBitrate: bitrate), context: context)
        return output
    }

    static func fit(_ url: URL, toBytes bytes: Int, context: JobContext) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw BumlebeeError.failed("Kunne ikke læse længden af \(url.lastPathComponent).") }
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        // 4 % headroom for the container, and the audio's share comes off the top.
        let totalBitrate = Double(bytes) * 8 * 0.96 / duration
        let audioBitrate = hasAudio ? (totalBitrate > 600_000 ? 128_000 : 64_000) : 0
        let videoBitrate = Int(totalBitrate) - audioBitrate
        guard videoBitrate >= 100_000 else {
            throw BumlebeeError.failed("\(url.lastPathComponent) er for lang til at blive så lille.")
        }
        // Lower bitrates look better at lower resolutions.
        let maxDimension = videoBitrate > 4_000_000 ? 1920 : videoBitrate > 1_500_000 ? 1280 : videoBitrate > 600_000 ? 960 : 640
        let output = Output.url(for: url, ext: "mp4", suffix: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        let settings = VideoTranscoder.Settings(maxDimension: maxDimension, videoBitrate: videoBitrate, audioBitrate: max(audioBitrate, 32_000))
        try await VideoTranscoder.transcode(url, to: output, settings: settings, context: context)
        return output
    }

    static func trim(_ url: URL, range: CMTimeRange, suffix: String = "klippet", context: JobContext) async throws -> URL {
        if FileKind.of(url) == .audio {
            return try await AudioEngine.trim(url, range: range, suffix: suffix, context: context)
        }
        let format = MediaExport.sameVideoFormat(as: url)
        let output = Output.url(for: url, ext: format.fileExtension, suffix: suffix)
        var options = MediaExport.Options()
        options.timeRange = range
        try await MediaExport.exportPreferringPassthrough(AVURLAsset(url: url), to: output, format: format, options: options, context: context)
        return output
    }

    static func split(_ url: URL, at time: CMTime, context: JobContext) async throws -> [URL] {
        let duration = try await AVURLAsset(url: url).load(.duration)
        guard time > .zero, time < duration else { throw BumlebeeError.failed("Vælg et delepunkt inde i klippet.") }
        let first = try await trim(url, range: CMTimeRange(start: .zero, end: time), suffix: "del 1", context: context.step(0, of: 2))
        let second = try await trim(url, range: CMTimeRange(start: time, end: duration), suffix: "del 2", context: context.step(1, of: 2))
        return [first, second]
    }

    static func changeSpeed(_ url: URL, factor: Double, context: JobContext) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = try await MediaExport.composition(from: asset)
        let duration = composition.duration
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: duration), toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / factor))
        let isAudio = FileKind.of(url) == .audio
        let format: Format = isAudio ? .m4a : .mp4
        let label = String(format: "%g×", factor).replacingOccurrences(of: ".", with: ",")
        let output = Output.url(for: url, ext: format.fileExtension, suffix: label)
        var options = MediaExport.Options()
        options.audioTimePitchAlgorithm = .spectral
        try await MediaExport.export(composition, preset: isAudio ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality,
                                     to: output, format: format, options: options, context: context)
        return output
    }

    static func mute(_ url: URL, context: JobContext) async throws -> URL {
        let composition = try await MediaExport.composition(from: AVURLAsset(url: url), includeAudio: false)
        let format = MediaExport.sameVideoFormat(as: url)
        let output = Output.url(for: url, ext: format.fileExtension, suffix: "lydløs")
        try await MediaExport.exportPreferringPassthrough(composition, to: output, format: format, context: context)
        return output
    }

    static func extractAudio(_ url: URL, context: JobContext) async throws -> URL {
        let output = Output.url(for: url, ext: "m4a")
        let composition = try await MediaExport.composition(from: AVURLAsset(url: url), includeVideo: false)
        guard !composition.tracks(withMediaType: .audio).isEmpty else {
            throw BumlebeeError.failed("\(url.lastPathComponent) har ingen lyd.")
        }
        try await MediaExport.exportPreferringPassthrough(composition, to: output, format: .m4a, context: context)
        return output
    }

    /// Rotates 90° clockwise by changing the display transform, so no quality is lost.
    static func rotate(_ url: URL, context: JobContext) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = try await MediaExport.composition(from: asset)
        guard let track = composition.tracks(withMediaType: .video).first else {
            throw BumlebeeError.failed("\(url.lastPathComponent) har intet videospor.")
        }
        let displayed = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        let clockwise = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: abs(displayed.height), ty: 0)
        track.preferredTransform = track.preferredTransform.concatenating(clockwise)
        let format = MediaExport.sameVideoFormat(as: url)
        let output = Output.url(for: url, ext: format.fileExtension, suffix: "roteret")
        try await MediaExport.exportPreferringPassthrough(composition, to: output, format: format, context: context)
        return output
    }

    static func join(_ urls: [URL], context: JobContext) async throws -> URL {
        guard let first = urls.first else { throw BumlebeeError.failed("Ingen filer.") }
        if FileKind.of(urls) == .audio { return try await AudioEngine.join(urls, context: context) }

        let composition = AVMutableComposition()
        guard let videoTarget = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTarget = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw BumlebeeError.failed("Kunne ikke samle videoerne.") }

        var cursor = CMTime.zero
        for (index, url) in urls.enumerated() {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let video = try await asset.loadTracks(withMediaType: .video).first {
                try videoTarget.insertTimeRange(range, of: video, at: cursor)
                if index == 0 { videoTarget.preferredTransform = try await video.load(.preferredTransform) }
            }
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTarget.insertTimeRange(range, of: audio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        if audioTarget.segments.isEmpty { composition.removeTrack(audioTarget) }

        let output = Output.url(named: "\(first.baseName) (samlet)", beside: first, ext: "mp4")
        try await MediaExport.export(composition, preset: AVAssetExportPresetHighestQuality, to: output, format: .mp4, context: context)
        return output
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let fraction = Int(((seconds - Double(total)) * 100).rounded(.down))
        return String(format: "%02d.%02d.%02d", total / 60, total % 60, fraction)
    }
}
