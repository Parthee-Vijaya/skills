@preconcurrency import AVFoundation

/// Audio conversion and processing. Everything flows through one decode → (gain) → encode pipeline:
/// AVAssetReader decodes any track AVFoundation can open (including a video's soundtrack) to float PCM,
/// AVAudioFile writes WAV, AIFF, CAF or FLAC, and AAC goes through AVAssetWriter, which, unlike
/// AVAudioFile, honours the requested bitrate.
enum AudioEngine {
    /// Formats the pipeline can write.
    static let writable: Set<Format> = [.m4a, .wav, .aiff, .caf, .flac]

    /// Keeps the input's format when possible, otherwise falls back to AAC in M4A.
    static func sameFormat(as url: URL) -> Format {
        if let format = Format(fileExtension: url.normalizedExtension), writable.contains(format) { return format }
        return .m4a
    }

    // MARK: Conversion and tools

    static func convert(_ url: URL, to format: Format, context: JobContext) async throws -> URL {
        let output = Output.url(for: url, ext: format.fileExtension)
        try await process([url], to: output, format: format, context: context)
        return output
    }

    static func compress(_ url: URL, context: JobContext) async throws -> URL {
        let output = Output.url(for: url, ext: "m4a", suffix: "komprimeret")
        try await process([url], to: output, format: .m4a, bitrate: 96_000, context: context)
        return output
    }

    static func fit(_ url: URL, toBytes bytes: Int, context: JobContext) async throws -> URL {
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration > 0 else { throw BumlebeeError.failed("Kunne ikke læse længden af \(url.lastPathComponent).") }
        // 5 % headroom for the container.
        let bitrate = Int(Double(bytes) * 8 * 0.95 / duration)
        guard bitrate >= 16_000 else {
            throw BumlebeeError.failed("\(url.lastPathComponent) er for lang til at blive så lille (ville kræve \(bitrate / 1000) kbit/s).")
        }
        let output = Output.url(for: url, ext: "m4a", suffix: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        try await process([url], to: output, format: .m4a, channels: bitrate < 64_000 ? 1 : nil,
                          sampleRate: bitrate < 48_000 ? 32_000 : nil, bitrate: min(bitrate, 320_000), context: context)
        return output
    }

    /// Peak-normalises to −1 dBFS.
    static func normalize(_ url: URL, context: JobContext) async throws -> URL {
        let peak = try await peakLevel(url, context: context.step(0, of: 2))
        guard peak > 0 else { throw BumlebeeError.failed("\(url.lastPathComponent) er helt stille.") }
        let gain = Float(pow(10, -1.0 / 20)) / peak
        let format = sameFormat(as: url)
        let output = Output.url(for: url, ext: format.fileExtension, suffix: "normaliseret")
        try await process([url], to: output, format: format, bitrate: 256_000, gain: gain, context: context.step(1, of: 2))
        return output
    }

    static func setChannels(_ url: URL, channels: Int, context: JobContext) async throws -> URL {
        let format = sameFormat(as: url)
        let output = Output.url(for: url, ext: format.fileExtension, suffix: channels == 1 ? "mono" : "stereo")
        try await process([url], to: output, format: format, channels: channels, bitrate: channels == 1 ? 128_000 : 256_000, context: context)
        return output
    }

    static func trim(_ url: URL, range: CMTimeRange, suffix: String = "klippet", context: JobContext) async throws -> URL {
        let format = sameFormat(as: url)
        let output = Output.url(for: url, ext: format.fileExtension, suffix: suffix)
        try await process([url], to: output, format: format, bitrate: 256_000, timeRange: range, context: context)
        return output
    }

    static func join(_ urls: [URL], context: JobContext) async throws -> URL {
        guard let first = urls.first else { throw BumlebeeError.failed("Ingen filer.") }
        let format = sameFormat(as: first)
        let output = Output.url(named: "\(first.baseName) (samlet)", beside: first, ext: format.fileExtension)
        try await process(urls, to: output, format: format, bitrate: 256_000, context: context)
        return output
    }

    // MARK: Pipeline

    static func process(
        _ inputs: [URL],
        to output: URL,
        format: Format,
        channels: Int? = nil,
        sampleRate: Double? = nil,
        bitrate: Int? = nil,
        timeRange: CMTimeRange? = nil,
        gain: Float = 1,
        context: JobContext
    ) async throws {
        guard let first = inputs.first else { throw BumlebeeError.failed("Ingen filer.") }
        let info = try await audioInfo(first)
        var rate = sampleRate ?? info.sampleRate
        if rate <= 0 { rate = 44_100 }
        if format == .m4a { rate = min(rate, 48_000) }
        let channelCount = max(1, min(channels ?? info.channels, 2))

        if format == .m4a {
            let temp = try Output.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let pcm = temp.appendingPathComponent("pcm.caf")
            try await process(inputs, to: pcm, format: .caf, channels: channelCount, sampleRate: rate,
                              timeRange: timeRange, gain: gain, context: context.step(0, of: 2))
            try await encodeAAC(pcm, to: output, sampleRate: rate, channels: channelCount,
                                bitrate: bitrate ?? 192_000, context: context.step(1, of: 2))
            return
        }

        var totalSeconds = 0.0
        for input in inputs {
            if let timeRange {
                totalSeconds += timeRange.duration.seconds
            } else {
                totalSeconds += try await AVURLAsset(url: input).load(.duration).seconds
            }
        }

        let settings = fileSettings(format, sampleRate: rate, channels: channelCount, bitrate: bitrate)
        do {
            let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            var doneSeconds = 0.0
            for input in inputs {
                let seconds = try await decode(input, sampleRate: rate, channels: channelCount, timeRange: timeRange, context: context) { buffer, position in
                    if gain != 1 { apply(gain: gain, to: buffer) }
                    try file.write(from: buffer)
                    if totalSeconds > 0 { context.progress((doneSeconds + position) / totalSeconds) }
                }
                doneSeconds += seconds
            }
            if #available(macOS 15.0, *) { file.close() }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        context.progress(1)
    }

    /// Decodes one input to float PCM in `format`'s sample rate and channel count. Returns the decoded duration.
    @discardableResult
    static func decode(
        _ url: URL,
        sampleRate: Double,
        channels: Int,
        timeRange: CMTimeRange? = nil,
        context: JobContext,
        handle: (AVAudioPCMBuffer, Double) throws -> Void
    ) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw BumlebeeError.failed("\(url.lastPathComponent) har ingen lyd.") }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: true) else {
            throw BumlebeeError.failed("Ugyldigt lydformat.")
        }

        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw BumlebeeError.failed("Kunne ikke læse lyden i \(url.lastPathComponent).") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? BumlebeeError.failed("Kunne ikke læse \(url.lastPathComponent).")
        }
        context.whenCancelled { reader.cancelReading() }

        let start = timeRange?.start.seconds ?? 0
        var position = 0.0
        while let sample = output.copyNextSampleBuffer() {
            try context.checkCancelled()
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            guard status == noErr else { throw BumlebeeError.failed("Lyddata kunne ikke kopieres (\(status)).") }
            position = CMSampleBufferGetPresentationTimeStamp(sample).seconds - start + Double(frames) / sampleRate
            try handle(buffer, position)
        }
        try context.checkCancelled()
        if reader.status == .failed {
            throw reader.error ?? BumlebeeError.failed("Kunne ikke læse \(url.lastPathComponent).")
        }
        return position
    }

    /// Encodes a PCM file to AAC in M4A at an exact bitrate.
    static func encodeAAC(_ input: URL, to output: URL, sampleRate: Double, channels: Int, bitrate: Int, context: JobContext) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw BumlebeeError.failed("Ingen lyd at kode.")
        }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        // AAC only accepts certain bitrates for a given rate and channel count; step down until one fits.
        let limit = channels == 1 ? 160_000 : 320_000
        let candidates = [min(max(bitrate, 16_000), limit), 128_000, 96_000, 64_000]
        guard let settings = candidates.lazy.map({ rate -> [String: Any] in
            [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: rate]
        }).first(where: { writer.canApply(outputSettings: $0, forMediaType: .audio) }) else {
            throw BumlebeeError.failed("AAC-koderen accepterer ikke disse indstillinger.")
        }
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        guard reader.startReading() else { throw reader.error ?? BumlebeeError.failed("Kunne ikke læse lyden.") }
        guard writer.startWriting() else { throw writer.error ?? BumlebeeError.failed("Kunne ikke skrive lyden.") }
        writer.startSession(atSourceTime: .zero)
        context.whenCancelled {
            reader.cancelReading()
            writer.cancelWriting()
        }
        do {
            while let sample = readerOutput.copyNextSampleBuffer() {
                while !writerInput.isReadyForMoreMediaData {
                    try context.checkCancelled()
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                guard writerInput.append(sample) else {
                    throw writer.error ?? BumlebeeError.failed("AAC-kodningen fejlede.")
                }
                if duration > 0 { context.progress(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration) }
            }
            try context.checkCancelled()
            if reader.status == .failed { throw reader.error ?? BumlebeeError.failed("Kunne ikke læse lyden.") }
            writerInput.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? BumlebeeError.failed("AAC-filen kunne ikke gemmes.")
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        context.progress(1)
    }

    static func peakLevel(_ url: URL, context: JobContext) async throws -> Float {
        let info = try await audioInfo(url)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        var peak: Float = 0
        try await decode(url, sampleRate: info.sampleRate > 0 ? info.sampleRate : 44_100, channels: max(1, min(info.channels, 2)), context: context) { buffer, position in
            guard let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
            for index in 0..<count { peak = max(peak, abs(data[index])) }
            if duration > 0 { context.progress(position / duration) }
        }
        return peak
    }

    static func apply(gain: Float, to buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
        for index in 0..<count { data[index] = max(-1, min(1, data[index] * gain)) }
    }

    static func audioInfo(_ url: URL) async throws -> (sampleRate: Double, channels: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw BumlebeeError.failed("\(url.lastPathComponent) har ingen lyd.")
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return (44_100, 2) }
        return (basic.mSampleRate, Int(basic.mChannelsPerFrame))
    }

    static func fileSettings(_ format: Format, sampleRate: Double, channels: Int, bitrate: Int?) -> [String: Any] {
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        switch format {
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = bitrate ?? 192_000
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = 16
        default:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
            settings[AVLinearPCMIsBigEndianKey] = format == .aiff
        }
        return settings
    }
}
