import Foundation

/// Optional ffmpeg backend for formats macOS cannot write on its own (WebP, MP3, MKV, WebM, OGG …).
/// Bumlebee looks for a bundled copy first, then the usual Homebrew and MacPorts locations.
enum FFmpeg {
    static var path: String? {
        var candidates: [String] = []
        let custom = Prefs.ffmpegPath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { candidates.append((custom as NSString).expandingTildeInPath) }
        if let bundled = Bundle.main.path(forAuxiliaryExecutable: "ffmpeg") { candidates.append(bundled) }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { path != nil }

    private final class DurationBox: @unchecked Sendable {
        var seconds: Double
        init(_ seconds: Double) { self.seconds = seconds }
    }

    /// Runs `ffmpeg -i input <arguments> output` and reports progress from its log.
    static func convert(
        _ input: URL,
        to output: URL,
        arguments: [String],
        inputArguments: [String] = [],
        duration: Double? = nil,
        context: JobContext
    ) async throws {
        guard let path else { throw BumlebeeError.needsFFmpeg(output.pathExtension.uppercased()) }
        let box = DurationBox(duration ?? 0)
        let args = ["-hide_banner", "-nostdin", "-y"] + inputArguments + ["-i", input.path] + arguments + [output.path]
        let result = try await ProcessRunner.run(path, args, context: context) { line in
            if box.seconds <= 0, let total = parseTime(after: "Duration: ", in: line) {
                box.seconds = total
            }
            if box.seconds > 0, let time = parseTime(after: "time=", in: line) {
                context.progress(time / box.seconds)
            }
        }
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw BumlebeeError.failed("ffmpeg kunne ikke lave \(output.pathExtension.uppercased()):\n\(result.stderr.lastLines(3))")
        }
        context.progress(1)
    }

    static func parseTime(after marker: String, in line: String) -> Double? {
        guard let range = line.range(of: marker) else { return nil }
        let rest = line[range.upperBound...]
        let token = rest.prefix { $0 != " " && $0 != "," }
        let parts = token.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Encoder settings for each output format.
    static func arguments(for format: Format, from kind: FileKind) -> [String] {
        switch format {
        // Video
        case .mp4, .m4v:
            return ["-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case .mov:
            return ["-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k"]
        case .mkv:
            return ["-map", "0:v:0?", "-map", "0:a?", "-map", "0:s?", "-c:v", "libx264", "-crf", "20", "-preset", "medium", "-c:a", "aac", "-b:a", "160k", "-c:s", "copy"]
        case .webm:
            return ["-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case .avi:
            return ["-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case .wmv:
            return ["-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]
        case .gif:
            if kind == .image { return ["-frames:v", "1"] }
            return ["-vf", "fps=12,scale='min(480,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]
        // Audio
        case .mp3: return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a: return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case .wav: return ["-vn", "-c:a", "pcm_s16le"]
        case .aiff: return ["-vn", "-c:a", "pcm_s16be"]
        case .flac: return ["-vn", "-c:a", "flac"]
        case .caf: return ["-vn", "-c:a", "pcm_s16le"]
        case .ogg: return ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case .opus: return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        // Images
        case .webp: return ["-frames:v", "1", "-c:v", "libwebp", "-quality", "\(Int(Prefs.imageQuality * 100))"]
        case .avif: return ["-frames:v", "1", "-c:v", "libaom-av1", "-still-picture", "1", "-crf", "28", "-cpu-used", "6", "-pix_fmt", "yuv420p"]
        case .png, .jpg, .bmp, .tiff: return ["-frames:v", "1"]
        default: return []
        }
    }
}
