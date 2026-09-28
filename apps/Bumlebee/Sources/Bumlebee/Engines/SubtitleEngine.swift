import Foundation

/// SRT and WebVTT conversion and timing shifts.
enum SubtitleEngine {
    struct Cue {
        var start: Double
        var end: Double
        var text: String
    }

    static func parse(_ url: URL) throws -> [Cue] {
        let raw = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .isoLatin1)
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = seconds(parts[0]),
                  let end = seconds(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else { continue }
            let text = lines[(timingIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            cues.append(Cue(start: start, end: end, text: text))
        }
        guard !cues.isEmpty else { throw BumlebeeError.failed("Ingen undertekster fundet i \(url.lastPathComponent).") }
        return cues
    }

    /// Parses `01:02:03,456`, `01:02:03.456` and `02:03.456`.
    static func seconds(_ text: String) -> Double? {
        let clean = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = clean.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return nil
        }
    }

    static func timestamp(_ seconds: Double, separator: String) -> String {
        let totalMilliseconds = Int((max(seconds, 0) * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let secs = (totalMilliseconds / 1000) % 60
        let millis = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, millis)
    }

    static func render(_ cues: [Cue], as format: Format) -> String {
        switch format {
        case .vtt:
            let body = cues.map { "\(timestamp($0.start, separator: ".")) --> \(timestamp($0.end, separator: "."))\n\($0.text)" }
            return "WEBVTT\n\n" + body.joined(separator: "\n\n") + "\n"
        case .txt:
            return cues.map(\.text).joined(separator: "\n") + "\n"
        default:
            let body = cues.enumerated().map { index, cue in
                "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(cue.text)"
            }
            return body.joined(separator: "\n\n") + "\n"
        }
    }

    static func convert(_ url: URL, to format: Format) throws -> URL {
        let output = Output.url(for: url, ext: format.fileExtension)
        try render(try parse(url), as: format).write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    static func shift(_ url: URL, by offset: Double) throws -> URL {
        let cues = try parse(url).map { Cue(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
            .filter { $0.end > 0 }
        let format = Format(fileExtension: url.normalizedExtension) ?? .srt
        let sign = offset >= 0 ? "+" : "−"
        let output = Output.url(for: url, ext: format.fileExtension, suffix: "\(sign)\(String(format: "%.1f", abs(offset))) s")
        try render(cues, as: format).write(to: output, atomically: true, encoding: .utf8)
        return output
    }
}
