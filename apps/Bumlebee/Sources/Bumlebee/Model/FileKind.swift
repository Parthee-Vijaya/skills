import Foundation
import UniformTypeIdentifiers

/// The broad family a dragged file belongs to. It decides which formats and tools the wheel offers.
enum FileKind: String {
    case image, video, audio, pdf, document, subtitle, archive, folder, other

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp", "gif", "avif", "svg", "ico", "jp2", "psd", "tga", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
    ]
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "ts", "mts", "m2ts", "ogv",
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aif", "aiff", "aifc", "flac", "ogg", "oga", "opus", "caf", "aac", "wma", "m4b", "amr",
    ]
    static let documentExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive",
    ]
    static let subtitleExtensions: Set<String> = ["srt", "vtt"]
    static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "rar", "7z", "cpio", "xar", "iso",
    ]

    static func of(_ url: URL) -> FileKind {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            // Packages such as .rtfd are directories on disk but documents to the user.
            if url.pathExtension.lowercased() == "rtfd" { return .document }
            return .folder
        }
        let ext = url.pathExtension.lowercased()
        if subtitleExtensions.contains(ext) { return .subtitle }
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if documentExtensions.contains(ext) { return .document }
        if archiveExtensions.contains(ext) || url.lastPathComponent.lowercased().hasSuffix(".tar.gz") { return .archive }

        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .text) { return .document }
        return .other
    }

    /// The shared kind of a batch. A batch that mixes kinds only gets the generic archive actions.
    static func of(_ urls: [URL]) -> FileKind {
        let kinds = Set(urls.map { FileKind.of($0) })
        if kinds.count == 1, let only = kinds.first { return only }
        return .other
    }

    var displayName: String {
        switch self {
        case .image: return "Billede"
        case .video: return "Video"
        case .audio: return "Lyd"
        case .pdf: return "PDF"
        case .document: return "Dokument"
        case .subtitle: return "Undertekster"
        case .archive: return "Arkiv"
        case .folder: return "Mappe"
        case .other: return "Fil"
        }
    }
}

extension URL {
    /// Lower-cased extension, treating `.tar.gz` as one extension.
    var normalizedExtension: String {
        let name = lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return "tgz" }
        let ext = pathExtension.lowercased()
        switch ext {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "aif", "aifc": return "aiff"
        case "htm": return "html"
        case "markdown": return "md"
        case "heif": return "heic"
        default: return ext
        }
    }

    /// File name without extension, treating `.tar.gz` as one extension.
    var baseName: String {
        let name = lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") { return String(name.dropLast(7)) }
        return deletingPathExtension().lastPathComponent
    }
}
