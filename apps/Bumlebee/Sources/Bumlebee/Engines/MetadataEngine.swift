@preconcurrency import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct MetadataRow: Identifiable {
    let id = UUID()
    let key: String
    let value: String
}

struct MetadataSection: Identifiable {
    let id = UUID()
    let title: String
    var rows: [MetadataRow]
}

struct EditableField: Identifiable {
    let id: String
    let label: String
    var value: String
}

/// Reads, edits and removes metadata for images, audio/video and PDFs.
enum MetadataEngine {
    // MARK: Reading

    static func read(_ url: URL) async -> [MetadataSection] {
        var sections = [fileSection(url)]
        switch FileKind.of(url) {
        case .image: sections += imageSections(url)
        case .video, .audio: sections += await mediaSections(url)
        case .pdf: sections += pdfSections(url)
        case .archive:
            if let entries = try? await ArchiveEngine.listing(url) {
                var rows = [MetadataRow(key: "Antal emner", value: "\(entries.count)")]
                rows += entries.prefix(200).map { MetadataRow(key: "", value: $0) }
                sections.append(MetadataSection(title: "Indhold", rows: rows))
            }
        default: break
        }
        return sections.filter { !$0.rows.isEmpty }
    }

    private static func fileSection(_ url: URL) -> MetadataSection {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey, .totalFileSizeKey])
        var rows = [MetadataRow(key: "Navn", value: url.lastPathComponent)]
        if let type = values?.contentType { rows.append(MetadataRow(key: "Type", value: type.localizedDescription ?? type.identifier)) }
        if let size = values?.fileSize ?? values?.totalFileSize {
            rows.append(MetadataRow(key: "Størrelse", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        if let date = values?.creationDate { rows.append(MetadataRow(key: "Oprettet", value: format(date))) }
        if let date = values?.contentModificationDate { rows.append(MetadataRow(key: "Ændret", value: format(date))) }
        rows.append(MetadataRow(key: "Placering", value: url.deletingLastPathComponent().path))
        return MetadataSection(title: "Fil", rows: rows)
    }

    private static func imageSections(_ url: URL) -> [MetadataSection] {
        let properties = ImageEngine.metadata(url)
        var sections: [MetadataSection] = []
        var general: [MetadataRow] = []
        if let width = properties[kCGImagePropertyPixelWidth], let height = properties[kCGImagePropertyPixelHeight] {
            general.append(MetadataRow(key: "Dimensioner", value: "\(width) × \(height) px"))
        }
        let simpleKeys: [(CFString, String)] = [
            (kCGImagePropertyColorModel, "Farvemodel"), (kCGImagePropertyProfileName, "Farveprofil"),
            (kCGImagePropertyDepth, "Bitdybde"), (kCGImagePropertyDPIWidth, "DPI"), (kCGImagePropertyOrientation, "Orientering"),
            (kCGImagePropertyHasAlpha, "Gennemsigtighed"),
        ]
        for (key, label) in simpleKeys {
            if let value = properties[key] { general.append(MetadataRow(key: label, value: describe(value))) }
        }
        let frames = ImageEngine.frameCount(url)
        if frames > 1 { general.append(MetadataRow(key: "Billeder", value: "\(frames)")) }
        sections.append(MetadataSection(title: "Billede", rows: general))

        let dictionaries: [(CFString, String)] = [
            (kCGImagePropertyTIFFDictionary, "TIFF"), (kCGImagePropertyExifDictionary, "EXIF"),
            (kCGImagePropertyGPSDictionary, "GPS / lokation"), (kCGImagePropertyIPTCDictionary, "IPTC"),
            (kCGImagePropertyExifAuxDictionary, "EXIF (ekstra)"), (kCGImagePropertyMakerAppleDictionary, "Apple"),
        ]
        for (key, title) in dictionaries {
            guard let dictionary = properties[key] as? [String: Any] else { continue }
            let rows = dictionary.keys.sorted().map { MetadataRow(key: $0, value: describe(dictionary[$0] as Any)) }
            sections.append(MetadataSection(title: title, rows: rows))
        }
        return sections
    }

    private static func mediaSections(_ url: URL) async -> [MetadataSection] {
        let asset = AVURLAsset(url: url)
        var general: [MetadataRow] = []
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
            general.append(MetadataRow(key: "Varighed", value: formatDuration(duration.seconds)))
        }
        if let tracks = try? await asset.load(.tracks) {
            for track in tracks {
                let type = track.mediaType
                let descriptions = (try? await track.load(.formatDescriptions)) ?? []
                let codec = descriptions.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
                if type == .video {
                    let size = (try? await track.load(.naturalSize)) ?? .zero
                    let fps = (try? await track.load(.nominalFrameRate)) ?? 0
                    let rate = (try? await track.load(.estimatedDataRate)) ?? 0
                    general.append(MetadataRow(key: "Video", value: "\(Int(abs(size.width)))×\(Int(abs(size.height))), \(String(format: "%.2f", fps)) fps, \(codec), \(Int(rate / 1000)) kbit/s"))
                } else if type == .audio {
                    let rate = (try? await track.load(.estimatedDataRate)) ?? 0
                    var detail = codec
                    if let description = descriptions.first, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                        detail += ", \(Int(basic.mSampleRate)) Hz, \(basic.mChannelsPerFrame) kanal(er)"
                    }
                    general.append(MetadataRow(key: "Lyd", value: "\(detail), \(Int(rate / 1000)) kbit/s"))
                }
            }
        }
        var sections = [MetadataSection(title: FileKind.of(url) == .video ? "Video" : "Lyd", rows: general)]

        if let items = try? await asset.load(.metadata), !items.isEmpty {
            var rows: [MetadataRow] = []
            for item in items {
                let key = item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "?"
                if let value = try? await item.load(.stringValue) {
                    rows.append(MetadataRow(key: key, value: value))
                } else if let value = try? await item.load(.value) {
                    rows.append(MetadataRow(key: key, value: describe(value)))
                }
            }
            sections.append(MetadataSection(title: "Tags", rows: rows))
        }
        return sections
    }

    private static func pdfSections(_ url: URL) -> [MetadataSection] {
        guard let document = PDFDocument(url: url) else { return [] }
        var rows = [
            MetadataRow(key: "Sider", value: "\(document.pageCount)"),
            MetadataRow(key: "PDF-version", value: "\(document.majorVersion).\(document.minorVersion)"),
            MetadataRow(key: "Krypteret", value: document.isEncrypted ? "Ja" : "Nej"),
        ]
        if let page = document.page(at: 0) {
            let size = page.bounds(for: .mediaBox).size
            rows.append(MetadataRow(key: "Sidestørrelse", value: String(format: "%.0f × %.0f pt (%.0f × %.0f mm)", size.width, size.height, size.width / 72 * 25.4, size.height / 72 * 25.4)))
        }
        for (key, value) in document.documentAttributes ?? [:] {
            rows.append(MetadataRow(key: "\(key)", value: describe(value)))
        }
        return [MetadataSection(title: "PDF", rows: rows)]
    }

    // MARK: Editing

    static func editableFields(_ url: URL) async -> [EditableField] {
        switch FileKind.of(url) {
        case .image:
            let tiff = ImageEngine.metadata(url)[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            return [
                EditableField(id: kCGImagePropertyTIFFImageDescription as String, label: "Beskrivelse", value: tiff[kCGImagePropertyTIFFImageDescription] as? String ?? ""),
                EditableField(id: kCGImagePropertyTIFFArtist as String, label: "Fotograf", value: tiff[kCGImagePropertyTIFFArtist] as? String ?? ""),
                EditableField(id: kCGImagePropertyTIFFCopyright as String, label: "Copyright", value: tiff[kCGImagePropertyTIFFCopyright] as? String ?? ""),
            ]
        case .pdf:
            let attributes = PDFDocument(url: url)?.documentAttributes ?? [:]
            func value(_ key: PDFDocumentAttribute) -> String {
                if let list = attributes[key] as? [String] { return list.joined(separator: ", ") }
                return attributes[key] as? String ?? ""
            }
            return [
                EditableField(id: PDFDocumentAttribute.titleAttribute.rawValue, label: "Titel", value: value(.titleAttribute)),
                EditableField(id: PDFDocumentAttribute.authorAttribute.rawValue, label: "Forfatter", value: value(.authorAttribute)),
                EditableField(id: PDFDocumentAttribute.subjectAttribute.rawValue, label: "Emne", value: value(.subjectAttribute)),
                EditableField(id: PDFDocumentAttribute.keywordsAttribute.rawValue, label: "Nøgleord", value: value(.keywordsAttribute)),
            ]
        case .video, .audio:
            guard ["mp4", "mov", "m4v", "m4a"].contains(url.normalizedExtension) else { return [] }
            let items = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
            func value(_ identifier: AVMetadataIdentifier) async -> String {
                guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first else { return "" }
                return (try? await item.load(.stringValue)) ?? ""
            }
            return [
                EditableField(id: AVMetadataIdentifier.commonIdentifierTitle.rawValue, label: "Titel", value: await value(.commonIdentifierTitle)),
                EditableField(id: AVMetadataIdentifier.commonIdentifierArtist.rawValue, label: "Kunstner", value: await value(.commonIdentifierArtist)),
                EditableField(id: AVMetadataIdentifier.commonIdentifierAlbumName.rawValue, label: "Album", value: await value(.commonIdentifierAlbumName)),
                EditableField(id: AVMetadataIdentifier.commonIdentifierDescription.rawValue, label: "Beskrivelse", value: await value(.commonIdentifierDescription)),
            ]
        default:
            return []
        }
    }

    static func write(_ url: URL, fields: [EditableField], context: JobContext) async throws -> URL {
        switch FileKind.of(url) {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
                throw BumlebeeError.failed("Kunne ikke læse billedet.")
            }
            let output = Output.url(for: url, ext: url.pathExtension.lowercased(), suffix: "redigeret")
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
                throw BumlebeeError.failed("Kunne ikke gemme billedet.")
            }
            let metadata = CGImageMetadataCreateMutable()
            for field in fields {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, field.id as CFString, field.value as CFString)
            }
            let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
            guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else {
                throw BumlebeeError.failed("Metadata kunne ikke skrives til dette billedformat.")
            }
            return output
        case .pdf:
            let document = try PDFEngine.open(url)
            var attributes = document.documentAttributes ?? [:]
            for field in fields {
                let key = PDFDocumentAttribute(rawValue: field.id)
                if key == .keywordsAttribute {
                    attributes[key] = field.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                } else {
                    attributes[key] = field.value
                }
            }
            document.documentAttributes = attributes
            let output = Output.url(for: url, ext: "pdf", suffix: "redigeret")
            try PDFEngine.save(document, to: output)
            return output
        case .video, .audio:
            let asset = AVURLAsset(url: url)
            let edited = Set(fields.map(\.id))
            var items = try await asset.load(.metadata).filter { item in
                guard let identifier = item.identifier else { return true }
                // Drop any existing item that means the same thing as an edited field.
                let common = item.commonKey.map { AVMetadataItem.identifier(forKey: $0.rawValue, keySpace: .common)?.rawValue ?? "" } ?? ""
                return !edited.contains(identifier.rawValue) && !edited.contains(common)
            }
            for field in fields where !field.value.isEmpty {
                let item = AVMutableMetadataItem()
                item.identifier = AVMetadataIdentifier(rawValue: field.id)
                item.value = field.value as NSString
                item.extendedLanguageTag = "und"
                items.append(item)
            }
            let format = FileKind.of(url) == .audio ? Format.m4a : MediaExport.sameVideoFormat(as: url)
            let output = Output.url(for: url, ext: format.fileExtension, suffix: "redigeret")
            var options = MediaExport.Options()
            options.metadata = items
            try await MediaExport.export(asset, preset: AVAssetExportPresetPassthrough, to: output, format: format, options: options, context: context)
            return output
        default:
            throw BumlebeeError.unsupported("Metadata kan ikke redigeres for denne filtype.")
        }
    }

    static func strip(_ url: URL, onlyLocation: Bool = false, context: JobContext) async throws -> URL {
        switch FileKind.of(url) {
        case .image:
            return try ImageEngine.stripMetadata(url, onlyLocation: onlyLocation)
        case .pdf:
            return try PDFEngine.stripMetadata(url)
        case .video, .audio:
            guard MediaSupport.isNativelyReadable(url) else {
                throw BumlebeeError.unsupported("macOS kan ikke læse \(url.pathExtension.uppercased()) direkte.")
            }
            if FileKind.of(url) == .audio, !["m4a", "mp4"].contains(url.normalizedExtension) {
                // Re-encoding through the audio pipeline writes no tags at all.
                let format = AudioEngine.sameFormat(as: url)
                let output = Output.url(for: url, ext: format.fileExtension, suffix: "uden metadata")
                try await AudioEngine.process([url], to: output, format: format, bitrate: 256_000, context: context)
                return output
            }
            let format = FileKind.of(url) == .audio ? Format.m4a : MediaExport.sameVideoFormat(as: url)
            let output = Output.url(for: url, ext: format.fileExtension, suffix: "uden metadata")
            var options = MediaExport.Options()
            options.stripMetadata = true
            try await MediaExport.exportPreferringPassthrough(AVURLAsset(url: url), to: output, format: format, options: options, context: context)
            return output
        default:
            throw BumlebeeError.unsupported("Metadata kan ikke fjernes fra denne filtype.")
        }
    }

    // MARK: Formatting

    static func describe(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case let date as Date: return format(date)
        case let array as [Any]: return array.map { describe($0) }.joined(separator: ", ")
        case let dictionary as [String: Any]: return dictionary.map { "\($0.key): \(describe($0.value))" }.sorted().joined(separator: "; ")
        case let data as Data: return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .memory) + " data"
        default: return "\(value)"
        }
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "da_DK")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total / 60) % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let text = String(bytes: bytes, encoding: .macOSRoman) ?? "?"
        return text.trimmingCharacters(in: .whitespaces)
    }
}
