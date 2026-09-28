import Foundation

/// A tool the Option-Shift wheel offers.
enum Tool: String, CaseIterable, Identifiable {
    // Shared
    case compress, targetSize, metadata, rotate, join, speed, trim
    // Images
    case resize, crop, adjust, annotate, redact, removeBackground, readQR, combinePDF, collage, makeGIF
    // Video
    case snapshot, split, mute, extractAudio
    // Audio
    case normalize, toMono, toStereo
    // PDF
    case organize
    // Documents and subtitles
    case stats, shiftTime
    // Archives and folders
    case extract, archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress: return "KOMPRIMÉR"
        case .targetSize: return "MÅLSTØRRELSE"
        case .metadata: return "METADATA"
        case .rotate: return "ROTÉR"
        case .join: return "SAML"
        case .speed: return "HASTIGHED"
        case .trim: return "KLIP"
        case .resize: return "SKALÉR"
        case .crop: return "BESKÆR"
        case .adjust: return "JUSTÉR"
        case .annotate: return "TEGN"
        case .redact: return "CENSURÉR"
        case .removeBackground: return "FJERN BG"
        case .readQR: return "LÆS QR"
        case .combinePDF: return "SAML PDF"
        case .collage: return "COLLAGE"
        case .makeGIF: return "LAV GIF"
        case .snapshot: return "SNAPSHOT"
        case .split: return "DEL OP"
        case .mute: return "LYDLØS"
        case .extractAudio: return "UDTRÆK LYD"
        case .normalize: return "NORMALISÉR"
        case .toMono: return "MONO"
        case .toStereo: return "STEREO"
        case .organize: return "ORGANISÉR"
        case .stats: return "STATISTIK"
        case .shiftTime: return "FORSKYD"
        case .extract: return "UDPAK"
        case .archive: return "ZIP"
        }
    }

    var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .targetSize: return "scalemass"
        case .metadata: return "tag"
        case .rotate: return "rotate.right"
        case .join: return "rectangle.stack.badge.plus"
        case .speed: return "speedometer"
        case .trim: return "scissors"
        case .resize: return "arrow.up.left.and.arrow.down.right"
        case .crop: return "crop"
        case .adjust: return "slider.horizontal.3"
        case .annotate: return "pencil.tip"
        case .redact: return "eye.slash"
        case .removeBackground: return "wand.and.stars"
        case .readQR: return "qrcode.viewfinder"
        case .combinePDF: return "doc.on.doc"
        case .collage: return "square.grid.2x2"
        case .makeGIF: return "photo.stack"
        case .snapshot: return "camera"
        case .split: return "square.split.2x1"
        case .mute: return "speaker.slash"
        case .extractAudio: return "waveform"
        case .normalize: return "waveform.path.ecg"
        case .toMono: return "speaker.wave.1"
        case .toStereo: return "speaker.wave.2"
        case .organize: return "square.grid.3x3"
        case .stats: return "textformat.123"
        case .shiftTime: return "clock.arrow.2.circlepath"
        case .extract: return "archivebox"
        case .archive: return "doc.zipper"
        }
    }
}
