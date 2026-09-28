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

    // MARK: Encoders

    /// Builds differ a lot (Homebrew's ffmpeg ships without libwebp, libvorbis and libaom),
    /// so Bumlebee asks the binary which encoders it has and picks from those.
    nonisolated(unsafe) private static var encoderCache: (path: String, encoders: Set<String>)?
    private static let cacheLock = NSLock()

    static var encoders: Set<String> {
        guard let path else { return [] }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cache = encoderCache, cache.path == path { return cache.encoders }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var found = Set<String>()
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // Lines look like " V....D libx264   libx264 H.264 / AVC …".
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: " ")
                if parts.count >= 2, parts[0].count == 6 { found.insert(String(parts[1])) }
            }
        }
        encoderCache = (path, found)
        return found
    }

    static func has(_ encoder: String) -> Bool { encoders.contains(encoder) }

    private static func firstAvailable(_ options: [(String, [String])]) -> [String]? {
        options.first { has($0.0) }?.1
    }

    private static var h264: [String]? {
        firstAvailable([
            ("libx264", ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p"]),
            ("h264_videotoolbox", ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-pix_fmt", "yuv420p"]),
            ("mpeg4", ["-c:v", "mpeg4", "-q:v", "3"]),
        ])
    }

    private static func audio(for format: Format) -> [String]? {
        switch format {
        case .mp3: return firstAvailable([("libmp3lame", ["-c:a", "libmp3lame", "-q:a", "2"])])
        case .m4a: return ["-c:a", "aac", "-b:a", "192k"]
        case .wav, .caf: return ["-c:a", "pcm_s16le"]
        case .aiff: return ["-c:a", "pcm_s16be"]
        case .flac: return ["-c:a", "flac"]
        case .ogg:
            // Vorbis if available, otherwise Opus, which is just as valid inside an Ogg file.
            return firstAvailable([
                ("libvorbis", ["-c:a", "libvorbis", "-q:a", "5"]),
                ("libopus", ["-c:a", "libopus", "-b:a", "128k"]),
                ("vorbis", ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"]),
            ])
        case .opus:
            return firstAvailable([
                ("libopus", ["-c:a", "libopus", "-b:a", "128k"]),
                ("opus", ["-c:a", "opus", "-strict", "-2", "-ar", "48000", "-b:a", "128k"]),
            ])
        default: return nil
        }
    }

    /// Encoder settings for each output format, or nil if this ffmpeg cannot make it.
    static func arguments(for format: Format, from kind: FileKind) -> [String]? {
        let streams = ["-map", "0:v:0?", "-map", "0:a:0?"]
        switch format {
        // Video
        case .mp4, .m4v:
            guard let video = h264 else { return nil }
            return streams + video + ["-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case .mov:
            guard let video = h264 else { return nil }
            return streams + video + ["-c:a", "aac", "-b:a", "160k"]
        case .mkv:
            guard let video = h264 else { return nil }
            return ["-map", "0:v:0?", "-map", "0:a?", "-map", "0:s?"] + video + ["-c:a", "aac", "-b:a", "160k", "-c:s", "copy"]
        case .webm:
            guard let video = firstAvailable([
                ("libvpx-vp9", ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1"]),
                ("libvpx", ["-c:v", "libvpx", "-crf", "10", "-b:v", "2M"]),
            ]), let sound = firstAvailable([
                ("libopus", ["-c:a", "libopus", "-b:a", "128k"]),
                ("libvorbis", ["-c:a", "libvorbis", "-q:a", "5"]),
            ]) else { return nil }
            return streams + video + sound
        case .avi:
            let sound = audio(for: .mp3) ?? ["-c:a", "pcm_s16le"]
            return streams + ["-c:v", "mpeg4", "-q:v", "3"] + sound
        case .wmv:
            return streams + ["-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]
        case .gif:
            if kind == .image { return ["-frames:v", "1"] }
            return ["-vf", "fps=12,scale='min(480,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]
        // Audio
        case .mp3, .m4a, .wav, .aiff, .flac, .caf, .ogg, .opus:
            guard let sound = audio(for: format) else { return nil }
            return ["-vn"] + sound
        // Images
        case .webp:
            return firstAvailable([("libwebp", ["-frames:v", "1", "-c:v", "libwebp", "-quality", "\(Int(Prefs.imageQuality * 100))"])])
        case .avif:
            let even = ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p", "-frames:v", "1"]
            return firstAvailable([
                ("libaom-av1", even + ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", "28", "-cpu-used", "6"]),
                ("libsvtav1", even + ["-c:v", "libsvtav1", "-crf", "30", "-preset", "8"]),
            ])
        case .png, .jpg, .bmp, .tiff:
            return ["-frames:v", "1"]
        default:
            return nil
        }
    }
}

/// Stand-alone encoders Bumlebee can use when ffmpeg lacks one (brew install webp libavif).
enum ExternalTool {
    static func path(_ name: String) -> String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.path(forAuxiliaryExecutable: name) { candidates.append(bundled) }
        candidates += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"].map { "\($0)/\(name)" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The tool that can make `format` from a PNG, if any.
    static func imageEncoder(for format: Format) -> String? {
        switch format {
        case .webp: return path("cwebp")
        case .avif: return path("avifenc")
        default: return nil
        }
    }
}
