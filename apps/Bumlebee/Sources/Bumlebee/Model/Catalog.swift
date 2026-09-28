import Foundation

enum WheelMode: Equatable {
    case convert, tools

    var title: String { self == .convert ? "KONVERTÉR" : "VÆRKTØJER" }
    var toggled: WheelMode { self == .convert ? .tools : .convert }
}

enum WheelAction: Equatable {
    case convert(Format)
    case tool(Tool)
}

struct WheelItem: Identifiable {
    let action: WheelAction
    let title: String
    let symbol: String?
    let disabledReason: String?

    var isEnabled: Bool { disabledReason == nil }

    var id: String {
        switch action {
        case .convert(let format): return "convert." + format.rawValue
        case .tool(let tool): return "tool." + tool.rawValue
        }
    }
}

/// Decides what the wheel shows for a set of dragged files.
enum Catalog {
    static let maxItems = 10

    static func items(for urls: [URL], mode: WheelMode) -> [WheelItem] {
        let kind = FileKind.of(urls)
        switch mode {
        case .convert:
            return convertFormats(for: kind, urls: urls).map { format in
                WheelItem(
                    action: .convert(format),
                    title: format.label,
                    symbol: nil,
                    disabledReason: Converter.availability(of: format, for: urls).disabledReason
                )
            }
        case .tools:
            return tools(for: kind, count: urls.count).map { tool in
                WheelItem(
                    action: .tool(tool),
                    title: tool.title,
                    symbol: tool.symbol,
                    disabledReason: ToolAvailability.disabledReason(tool, urls: urls)
                )
            }
        }
    }

    static func convertFormats(for kind: FileKind, urls: [URL]) -> [Format] {
        let candidates: [Format]
        switch kind {
        case .image: candidates = [.jpg, .png, .heic, .webp, .avif, .pdf, .gif, .tiff, .bmp, .ico]
        case .video: candidates = [.mp4, .mov, .mkv, .webm, .gif, .avi, .wmv, .m4a, .mp3, .wav]
        case .audio: candidates = [.mp3, .m4a, .wav, .flac, .aiff, .ogg, .opus, .caf]
        case .pdf: candidates = [.png, .jpg, .tiff, .txt, .docx, .rtf, .html]
        case .document: candidates = [.pdf, .docx, .rtf, .txt, .html, .odt, .md]
        case .subtitle: candidates = [.srt, .vtt, .txt]
        case .archive: candidates = [.zip, .tgz, .tar]
        case .folder: candidates = [.zip, .tgz, .tar]
        case .other: candidates = urls.count == 1 ? [.zip, .gz, .tgz, .tar] : [.zip, .tgz, .tar]
        }
        // Converting to the format every input already has is pointless.
        let inputFormats = Set(urls.compactMap { Format(fileExtension: $0.normalizedExtension) })
        let filtered = candidates.filter { !(inputFormats.count == 1 && inputFormats.contains($0)) }
        return Array(filtered.prefix(maxItems))
    }

    static func tools(for kind: FileKind, count: Int) -> [Tool] {
        let many = count > 1
        let list: [Tool]
        switch kind {
        case .image:
            list = many
                ? [.compress, .targetSize, .resize, .combinePDF, .collage, .makeGIF, .removeBackground, .metadata, .rotate, .archive]
                : [.compress, .targetSize, .resize, .crop, .adjust, .annotate, .redact, .removeBackground, .metadata, .readQR]
        case .video:
            list = many
                ? [.join, .compress, .targetSize, .mute, .extractAudio, .speed, .rotate, .metadata]
                : [.compress, .targetSize, .trim, .snapshot, .split, .speed, .mute, .extractAudio, .rotate, .metadata]
        case .audio:
            list = many
                ? [.join, .compress, .normalize, .toMono, .toStereo, .speed, .metadata]
                : [.compress, .targetSize, .normalize, .trim, .split, .toMono, .toStereo, .speed, .metadata]
        case .pdf:
            list = many
                ? [.join, .compress, .rotate, .metadata, .archive]
                : [.compress, .targetSize, .organize, .split, .rotate, .readQR, .metadata]
        case .document: list = [.stats, .metadata, .archive]
        case .subtitle: list = [.shiftTime, .stats]
        case .archive: list = [.extract, .metadata]
        case .folder, .other: list = [.archive, .metadata]
        }
        return Array(list.prefix(maxItems))
    }
}

enum ToolAvailability {
    static func disabledReason(_ tool: Tool, urls: [URL]) -> String? {
        let kind = FileKind.of(urls)
        let needsNativeMedia: Set<Tool> = [.compress, .targetSize, .trim, .snapshot, .split, .speed, .mute, .extractAudio, .rotate, .normalize, .toMono, .toStereo, .join]
        if (kind == .video || kind == .audio), needsNativeMedia.contains(tool) {
            let unreadable = urls.filter { !MediaSupport.isNativelyReadable($0) }
            if !unreadable.isEmpty {
                return "macOS kan ikke læse \(unreadable[0].pathExtension.uppercased())-filer direkte. Konvertér først til MP4/M4A."
            }
        }
        return nil
    }
}
