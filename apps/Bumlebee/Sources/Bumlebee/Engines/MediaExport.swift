import AVFoundation

/// Thin async wrapper around AVAssetExportSession with progress and cancellation.
enum MediaExport {
    struct Options {
        var timeRange: CMTimeRange?
        var metadata: [AVMetadataItem]?
        var stripMetadata = false
        var audioTimePitchAlgorithm: AVAudioTimePitchAlgorithm?
        var videoComposition: AVVideoComposition?
    }

    static func fileType(for format: Format) -> AVFileType {
        switch format {
        case .mov: return .mov
        case .m4v: return .m4v
        case .m4a: return .m4a
        case .wav: return .wav
        case .aiff: return .aiff
        case .caf: return .caf
        default: return .mp4
        }
    }

    /// Container to use when an operation keeps "the same" format as a video input.
    static func sameVideoFormat(as url: URL) -> Format {
        switch url.normalizedExtension {
        case "mov": return .mov
        case "m4v": return .m4v
        default: return .mp4
        }
    }

    /// Tries a lossless passthrough first and re-encodes only if that fails.
    static func exportPreferringPassthrough(
        _ asset: AVAsset, to output: URL, format: Format, options: Options = Options(), context: JobContext
    ) async throws {
        do {
            try await export(asset, preset: AVAssetExportPresetPassthrough, to: output, format: format, options: options, context: context)
        } catch BumlebeeError.cancelled {
            throw BumlebeeError.cancelled
        } catch {
            try? FileManager.default.removeItem(at: output)
            let preset = format == .m4a ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
            try await export(asset, preset: preset, to: output, format: format, options: options, context: context)
        }
    }

    static func export(
        _ asset: AVAsset, preset: String, to output: URL, format: Format, options: Options = Options(), context: JobContext
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw BumlebeeError.failed("Eksport er ikke mulig for denne fil.")
        }
        let fileType = Self.fileType(for: format)
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if let range = options.timeRange { session.timeRange = range }
        if let algorithm = options.audioTimePitchAlgorithm { session.audioTimePitchAlgorithm = algorithm }
        if let composition = options.videoComposition { session.videoComposition = composition }
        if let metadata = options.metadata { session.metadata = metadata }
        if options.stripMetadata {
            session.metadata = []
            session.metadataItemFilter = .forSharing()
        }
        context.whenCancelled { session.cancelExport() }

        let poller = Task {
            while !Task.isCancelled {
                context.progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        poller.cancel()

        try context.checkCancelled()
        switch session.status {
        case .completed:
            context.progress(1)
        case .cancelled:
            throw BumlebeeError.cancelled
        default:
            try? FileManager.default.removeItem(at: output)
            let reason = session.error?.localizedDescription ?? "ukendt fejl"
            throw BumlebeeError.failed("Eksporten fejlede: \(reason)")
        }
    }

    /// Copies an asset's first video and audio track into an editable composition.
    static func composition(
        from asset: AVAsset, includeVideo: Bool = true, includeAudio: Bool = true
    ) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        if includeVideo, let track = try await asset.loadTracks(withMediaType: .video).first,
           let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let range = try await track.load(.timeRange)
            try target.insertTimeRange(range, of: track, at: range.start)
            target.preferredTransform = try await track.load(.preferredTransform)
        }
        if includeAudio, let track = try await asset.loadTracks(withMediaType: .audio).first,
           let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let range = try await track.load(.timeRange)
            try target.insertTimeRange(range, of: track, at: range.start)
        }
        return composition
    }
}
