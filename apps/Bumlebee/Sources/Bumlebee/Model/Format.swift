import Foundation
import UniformTypeIdentifiers

/// An output format the convert wheel can produce.
enum Format: String, CaseIterable, Identifiable {
    // Images
    case jpg, png, heic, webp, tiff, bmp, gif, avif, ico, pdf
    // Video
    case mp4, mov, m4v, mkv, webm, avi, wmv
    // Audio
    case m4a, mp3, wav, aiff, flac, caf, ogg, opus
    // Documents
    case txt, rtf, docx, odt, html, md
    // Subtitles
    case srt, vtt
    // Archives
    case zip, tar, tgz, gz

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tgz: return "TAR.GZ"
        case .gz: return "GZIP"
        case .md: return "MARKDOWN"
        default: return rawValue.uppercased()
        }
    }

    var fileExtension: String {
        switch self {
        case .tgz: return "tar.gz"
        default: return rawValue
        }
    }

    var utType: UTType? {
        switch self {
        case .jpg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .webp: return .webP
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .gif: return .gif
        case .avif: return UTType("public.avif")
        case .ico: return .ico
        case .pdf: return .pdf
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        case .m4v: return UTType("com.apple.m4v-video")
        case .m4a: return .mpeg4Audio
        case .wav: return .wav
        case .aiff: return .aiff
        case .mp3: return .mp3
        default: return UTType(filenameExtension: fileExtension)
        }
    }

    var isLossyImage: Bool { [.jpg, .heic, .webp, .avif].contains(self) }

    /// Maps a file extension back to a format, for "same format as input" operations.
    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "jpeg", "jpg": self = .jpg
        case "tif", "tiff": self = .tiff
        case "heif", "heic": self = .heic
        case "aif", "aiff", "aifc": self = .aiff
        case "htm", "html": self = .html
        case "markdown", "md": self = .md
        case "tar.gz", "tgz": self = .tgz
        default:
            guard let format = Format(rawValue: ext.lowercased()) else { return nil }
            self = format
        }
    }
}
