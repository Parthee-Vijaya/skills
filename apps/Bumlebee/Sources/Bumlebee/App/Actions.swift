import AppKit
import AVFoundation

/// Turns a wheel choice into a job, a prompt or a window.
@MainActor
enum Actions {
    static func perform(_ action: WheelAction, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch action {
        case .convert(let format):
            let noun = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) filer"
            JobRunner.shared.run(title: "Konverterer til \(format.label)", files: urls) { context in
                context.status(noun)
                return try await Converter.convert(urls, to: format, context: context)
            }
        case .tool(let tool):
            perform(tool, on: urls)
        }
    }

    private static func perform(_ tool: Tool, on urls: [URL]) {
        let kind = FileKind.of(urls)
        let first = urls[0]

        switch tool {
        case .compress:
            if kind == .video {
                guard let level = Prompts.compressionLevel() else { return }
                each(urls, title: "Komprimerer") { url, context in [try await VideoEngine.compress(url, level: level, context: context)] }
            } else {
                each(urls, title: "Komprimerer") { url, context in
                    switch kind {
                    case .image: return [try await ImageEngine.compress(url, context: context)]
                    case .audio: return [try await AudioEngine.compress(url, context: context)]
                    case .pdf: return [try await PDFEngine.compress(url, context: context)]
                    default: throw BumlebeeError.unsupported("Kan ikke komprimere \(url.lastPathComponent).")
                    }
                }
            }

        case .targetSize:
            let defaults: (Double, String) = kind == .image ? (500, "KB") : kind == .pdf ? (2, "MB") : kind == .audio ? (5, "MB") : (25, "MB")
            guard let bytes = Prompts.targetSize(defaultValue: defaults.0, defaultUnit: defaults.1, fileName: urls.count == 1 ? first.lastPathComponent : "hver fil") else { return }
            each(urls, title: "Rammer \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))") { url, context in
                switch kind {
                case .image: return [try await ImageEngine.fit(url, toBytes: bytes, context: context)]
                case .video: return [try await VideoEngine.fit(url, toBytes: bytes, context: context)]
                case .audio: return [try await AudioEngine.fit(url, toBytes: bytes, context: context)]
                case .pdf: return [try await PDFEngine.fit(url, toBytes: bytes, context: context)]
                default: throw BumlebeeError.unsupported("Kan ikke ramme en størrelse for \(url.lastPathComponent).")
                }
            }

        case .resize:
            guard let spec = Prompts.resize() else { return }
            each(urls, title: "Skalerer") { url, context in [try await ImageEngine.resize(url, spec: spec, context: context)] }

        case .crop, .adjust, .annotate, .redact:
            let mode: ImageEditorModel.Mode = tool == .crop ? .crop : tool == .adjust ? .adjust : tool == .annotate ? .draw : .redact
            Windows.openEditor(for: first, mode: mode)

        case .removeBackground:
            each(urls, title: "Fjerner baggrund") { url, context in [try await VisionEngine.removeBackground(url, context: context)] }

        case .readQR:
            do {
                let codes = try VisionEngine.readCodes(in: urls)
                if codes.isEmpty {
                    Alerts.info(title: "Ingen koder fundet", message: "Bumlebee fandt ingen QR-koder eller stregkoder.")
                } else {
                    Alerts.results(title: codes.count == 1 ? "Fandt 1 kode" : "Fandt \(codes.count) koder", lines: codes)
                }
            } catch {
                Alerts.error(title: "Kunne ikke læse koder", message: error.localizedDescription)
            }

        case .combinePDF:
            JobRunner.shared.run(title: "Samler til PDF", files: urls) { _ in
                let output = Output.url(named: "\(first.baseName) (samlet)", beside: first, ext: "pdf")
                try PDFEngine.makePDF(fromImages: urls, to: output)
                return [output]
            }

        case .collage:
            JobRunner.shared.run(title: "Laver collage", files: urls) { context in [try await ImageEngine.collage(from: urls, context: context)] }

        case .makeGIF:
            JobRunner.shared.run(title: "Laver GIF", files: urls) { context in [try await ImageEngine.makeGIF(from: urls, context: context)] }

        case .metadata:
            if urls.count == 1 {
                Windows.openMetadata(for: first)
            } else {
                each(urls, title: "Fjerner metadata") { url, context in [try await MetadataEngine.strip(url, context: context)] }
            }

        case .rotate:
            each(urls, title: "Roterer") { url, context in
                switch kind {
                case .image: return [try await ImageEngine.rotate(url, context: context)]
                case .video: return [try await VideoEngine.rotate(url, context: context)]
                case .pdf: return [try await PDFEngine.rotate(url, context: context)]
                default: throw BumlebeeError.unsupported("Kan ikke rotere \(url.lastPathComponent).")
                }
            }

        case .join:
            JobRunner.shared.run(title: "Samler \(urls.count) filer", files: urls) { context in
                if kind == .pdf {
                    return [try await PDFEngine.merge(urls, context: context)]
                }
                return [try await VideoEngine.join(urls, context: context)]
            }

        case .speed:
            guard let factor = Prompts.speed() else { return }
            each(urls, title: "Skifter hastighed") { url, context in [try await VideoEngine.changeSpeed(url, factor: factor, context: context)] }

        case .trim, .snapshot, .split:
            Windows.openPlayer(for: first, startTrimming: tool == .trim)

        case .mute:
            each(urls, title: "Fjerner lyd") { url, context in [try await VideoEngine.mute(url, context: context)] }

        case .extractAudio:
            each(urls, title: "Udtrækker lyd") { url, context in [try await VideoEngine.extractAudio(url, context: context)] }

        case .normalize:
            each(urls, title: "Normaliserer") { url, context in [try await AudioEngine.normalize(url, context: context)] }

        case .toMono, .toStereo:
            let channels = tool == .toMono ? 1 : 2
            each(urls, title: channels == 1 ? "Laver mono" : "Laver stereo") { url, context in
                [try await AudioEngine.setChannels(url, channels: channels, context: context)]
            }

        case .organize:
            Windows.openOrganizer(for: first)

        case .stats:
            showStats(for: urls)

        case .shiftTime:
            guard let offset = Prompts.subtitleShift(), offset != 0 else { return }
            each(urls, title: "Forskyder undertekster") { url, _ in [try SubtitleEngine.shift(url, by: offset)] }

        case .extract:
            each(urls, title: "Pakker ud") { url, context in [try await ArchiveEngine.extract(url, context: context)] }

        case .archive:
            JobRunner.shared.run(title: "Pakker som ZIP", files: urls) { context in
                [try await ArchiveEngine.archive(urls, as: .zip, context: context)]
            }
        }
    }

    /// Runs the same operation on every file as one job with shared progress.
    private static func each(_ urls: [URL], title: String, operation: @escaping (URL, JobContext) async throws -> [URL]) {
        JobRunner.shared.run(title: title, files: urls) { context in
            var outputs: [URL] = []
            for (index, url) in urls.enumerated() {
                try context.checkCancelled()
                context.status(url.lastPathComponent)
                outputs += try await operation(url, context.step(index, of: urls.count))
            }
            return outputs
        }
    }

    private static func showStats(for urls: [URL]) {
        var lines: [String] = []
        for url in urls {
            do {
                let text: String
                if FileKind.of(url) == .subtitle {
                    text = try SubtitleEngine.parse(url).map(\.text).joined(separator: "\n")
                } else {
                    text = try DocumentEngine.read(url).string
                }
                let stats = DocumentEngine.stats(for: text)
                lines.append("""
                \(url.lastPathComponent)
                Ord: \(stats.words) · Tegn: \(stats.characters) (uden mellemrum: \(stats.charactersWithoutSpaces))
                Linjer: \(stats.lines) · Afsnit: \(stats.paragraphs) · Læsetid: ca. \(stats.readingMinutes) min.
                """)
            } catch {
                lines.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        Alerts.results(title: "Statistik", lines: lines)
    }
}
