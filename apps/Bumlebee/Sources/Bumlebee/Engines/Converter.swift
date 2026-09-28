import Foundation

enum Availability {
    case native, ffmpeg, unavailable(String)

    var disabledReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

enum MediaSupport {
    /// Containers AVFoundation can open without help.
    static let nativeVideo: Set<String> = ["mp4", "mov", "m4v", "3gp"]
    static let nativeAudio: Set<String> = ["mp3", "m4a", "m4b", "wav", "aif", "aiff", "aifc", "flac", "caf", "aac", "amr"]

    static func isNativelyReadable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return nativeVideo.contains(ext) || nativeAudio.contains(ext)
    }
}

/// Routes a conversion to the engine that can do it, preferring built-in macOS frameworks over ffmpeg.
enum Converter {
    static func availability(of format: Format, for urls: [URL]) -> Availability {
        var result = Availability.native
        for url in urls {
            let availability = Self.availability(of: format, for: url)
            switch availability {
            case .unavailable: return availability
            case .ffmpeg: result = .ffmpeg
            case .native: break
            }
        }
        return result
    }

    static func availability(of format: Format, for url: URL) -> Availability {
        let kind = FileKind.of(url)
        if canConvertNatively(url, kind: kind, to: format) { return .native }
        if ffmpegCanConvert(kind: kind, to: format) {
            return FFmpeg.isAvailable ? .ffmpeg : .unavailable("\(format.label) kræver ffmpeg. Installér med: brew install ffmpeg")
        }
        return .unavailable("\(kind.displayName) kan ikke konverteres til \(format.label).")
    }

    static func canConvertNatively(_ url: URL, kind: FileKind, to format: Format) -> Bool {
        switch kind {
        case .image:
            return format == .pdf || ImageEngine.canWrite(format)
        case .video:
            guard MediaSupport.isNativelyReadable(url) else { return false }
            return [.mp4, .mov, .m4v, .gif, .m4a, .wav, .aiff, .caf, .flac].contains(format)
        case .audio:
            guard MediaSupport.isNativelyReadable(url) else { return false }
            return [.m4a, .wav, .aiff, .caf, .flac].contains(format)
        case .pdf:
            return [.png, .jpg, .tiff, .txt, .docx, .rtf, .html].contains(format)
        case .document:
            return [.pdf, .docx, .rtf, .txt, .html, .odt, .md].contains(format)
        case .subtitle:
            return [.srt, .vtt, .txt].contains(format)
        case .archive, .folder, .other:
            return [.zip, .tar, .tgz, .gz].contains(format)
        }
    }

    static func ffmpegCanConvert(kind: FileKind, to format: Format) -> Bool {
        switch kind {
        case .image: return [.webp, .avif, .png, .jpg, .bmp, .tiff, .gif].contains(format)
        case .video: return [.mp4, .mov, .m4v, .mkv, .webm, .avi, .wmv, .gif, .mp3, .m4a, .wav, .aiff, .flac, .ogg, .opus, .caf].contains(format)
        case .audio: return [.mp3, .m4a, .wav, .aiff, .flac, .ogg, .opus, .caf].contains(format)
        default: return false
        }
    }

    /// Converts every input. Archive formats pack the whole batch into one archive.
    static func convert(_ urls: [URL], to format: Format, context: JobContext) async throws -> [URL] {
        let kind = FileKind.of(urls)
        if [.zip, .tar, .tgz, .gz].contains(format), kind != .archive {
            return [try await ArchiveEngine.archive(urls, as: format, context: context)]
        }
        var outputs: [URL] = []
        for (index, url) in urls.enumerated() {
            let step = context.step(index, of: urls.count)
            context.status(url.lastPathComponent)
            outputs += try await convert(url, to: format, context: step)
        }
        return outputs
    }

    static func convert(_ url: URL, to format: Format, context: JobContext) async throws -> [URL] {
        try context.checkCancelled()
        let kind = FileKind.of(url)
        if canConvertNatively(url, kind: kind, to: format) {
            switch kind {
            case .image: return [try await ImageEngine.convert(url, to: format, context: context)]
            case .video: return [try await VideoEngine.convert(url, to: format, context: context)]
            case .audio: return [try await AudioEngine.convert(url, to: format, context: context)]
            case .pdf: return try await PDFEngine.convert(url, to: format, context: context)
            case .document: return [try await DocumentEngine.convert(url, to: format)]
            case .subtitle: return [try SubtitleEngine.convert(url, to: format)]
            case .archive, .folder, .other: return [try await ArchiveEngine.repack(url, as: format, context: context)]
            }
        }
        guard ffmpegCanConvert(kind: kind, to: format) else {
            throw BumlebeeError.unsupported("\(url.lastPathComponent) kan ikke konverteres til \(format.label).")
        }
        if kind == .image {
            return [try await ImageEngine.convertViaFFmpeg(url, to: format, context: context)]
        }
        let output = Output.url(for: url, ext: format.fileExtension)
        try await FFmpeg.convert(url, to: output, arguments: FFmpeg.arguments(for: format, from: kind), context: context)
        return [output]
    }
}
