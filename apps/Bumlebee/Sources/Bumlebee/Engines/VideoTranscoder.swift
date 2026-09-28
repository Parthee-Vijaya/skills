import AVFoundation

/// Re-encodes video with an explicit bitrate and size, which AVAssetExportSession presets cannot do.
/// Used for "compress" and "aim for an exact file size".
enum VideoTranscoder {
    struct Settings {
        var maxDimension: Int?
        var videoBitrate: Int
        var audioBitrate: Int = 128_000
        var codec: AVVideoCodecType = .hevc
        var fileType: AVFileType = .mp4
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var error: Error?
    }

    private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    static func transcode(_ url: URL, to output: URL, settings: Settings, context: JobContext) async throws {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw BumlebeeError.failed("\(url.lastPathComponent) har intet videospor.")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds

        // Encoders want even dimensions.
        var width = Int(abs(naturalSize.width)), height = Int(abs(naturalSize.height))
        if let maxDimension = settings.maxDimension, max(width, height) > maxDimension {
            let scale = Double(maxDimension) / Double(max(width, height))
            width = Int(Double(width) * scale)
            height = Int(Double(height) * scale)
        }
        width -= width % 2
        height -= height % 2

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: settings.fileType)
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let fps = frameRate > 0 ? Double(frameRate) : 30
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.videoBitrate,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int((fps * 2).rounded()),
            ],
        ])
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack {
            let pcm = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            pcm.alwaysCopiesSampleData = false
            reader.add(pcm)
            let aac = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: settings.audioBitrate,
            ])
            aac.expectsMediaDataInRealTime = false
            writer.add(aac)
            audioOutput = pcm
            audioInput = aac
        }

        guard reader.startReading() else { throw reader.error ?? BumlebeeError.failed("Kunne ikke læse videoen.") }
        guard writer.startWriting() else { throw writer.error ?? BumlebeeError.failed("Kunne ikke skrive videoen.") }
        writer.startSession(atSourceTime: .zero)
        context.whenCancelled {
            reader.cancelReading()
            writer.cancelWriting()
        }

        let state = State()
        let group = DispatchGroup()

        func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String, reportsProgress: Bool) {
            group.enter()
            let queue = DispatchQueue(label: "bumlebee.transcode.\(label)")
            let finished = Flag()
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished.isSet else { return }
                while input.isReadyForMoreMediaData {
                    if context.isCancelled || reader.status != .reading {
                        finished.isSet = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        finished.isSet = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    if reportsProgress, duration > 0 {
                        context.progress(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)
                    }
                    if !input.append(sample) {
                        state.lock.lock()
                        state.error = writer.error
                        state.lock.unlock()
                        reader.cancelReading()
                        finished.isSet = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }

        pump(videoOutput, into: videoInput, label: "video", reportsProgress: true)
        if let audioOutput, let audioInput {
            pump(audioOutput, into: audioInput, label: "audio", reportsProgress: false)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }

        if context.isCancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw BumlebeeError.cancelled
        }
        if let error = state.error ?? (reader.status == .failed ? reader.error : nil) {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw BumlebeeError.failed("Videoen kunne ikke omkodes: \(error.localizedDescription)")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw BumlebeeError.failed("Videoen kunne ikke gemmes: \(writer.error?.localizedDescription ?? "ukendt fejl")")
        }
        context.progress(1)
    }

    /// A bitrate that looks good for the size and frame rate (≈0.06 bits per pixel for HEVC).
    static func suggestedBitrate(width: Int, height: Int, fps: Double, quality: Double) -> Int {
        Int(Double(width * height) * max(fps, 24) * quality)
    }
}
