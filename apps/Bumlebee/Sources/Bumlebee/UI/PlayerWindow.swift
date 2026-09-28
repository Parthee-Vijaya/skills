import AVKit
import SwiftUI

/// A player with trimming, snapshots and splitting, for video and audio.
@MainActor
final class PlayerModel: ObservableObject {
    let url: URL
    let player: AVPlayer
    let startTrimming: Bool
    let isVideo: Bool
    weak var playerView: AVPlayerView?
    @Published var isTrimming = false

    init(url: URL, startTrimming: Bool) {
        self.url = url
        self.startTrimming = startTrimming
        self.isVideo = FileKind.of(url) == .video
        player = AVPlayer(url: url)
    }

    func attach(_ view: AVPlayerView) {
        playerView = view
        guard startTrimming else { return }
        // Trimming can only begin once the item has loaded.
        Task { @MainActor [weak self] in
            for _ in 0..<40 {
                guard let self else { return }
                if self.playerView?.canBeginTrimming == true {
                    self.beginTrim()
                    return
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    func beginTrim() {
        guard let view = playerView, view.canBeginTrimming, !isTrimming else { return }
        isTrimming = true
        view.beginTrimming { [weak self] result in
            Task { @MainActor in self?.trimFinished(result) }
        }
    }

    private func trimFinished(_ result: AVPlayerViewTrimResult) {
        isTrimming = false
        guard result == .okButton, let item = player.currentItem else { return }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        guard end > start else { return }
        let url = self.url
        let range = CMTimeRange(start: start, end: end)
        JobRunner.shared.run(title: "Klipper", files: [url]) { context in
            [try await VideoEngine.trim(url, range: range, context: context)]
        }
    }

    func snapshot() {
        let url = self.url
        let time = player.currentTime()
        JobRunner.shared.run(title: "Tager snapshot", files: [url]) { _ in
            [try await VideoEngine.snapshot(url, at: time)]
        }
    }

    func splitHere() {
        let url = self.url
        let time = player.currentTime()
        player.pause()
        JobRunner.shared.run(title: "Deler", files: [url]) { context in
            try await VideoEngine.split(url, at: time, context: context)
        }
    }
}

struct PlayerView: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            PlayerRepresentable(model: model)
            Divider()
            HStack(spacing: 10) {
                Button("Klip …", systemImage: "scissors") { model.beginTrim() }
                    .disabled(model.isTrimming)
                if model.isVideo {
                    Button("Snapshot", systemImage: "camera") { model.snapshot() }
                }
                Button("Del ved afspilningshovedet", systemImage: "square.split.2x1") { model.splitHere() }
                Spacer()
                Text(model.isTrimming ? "Træk i de gule håndtag, og bekræft." : "Kopier gemmes ved siden af originalen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .onDisappear { model.player.pause() }
    }
}

private struct PlayerRepresentable: NSViewRepresentable {
    let model: PlayerModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = model.player
        view.controlsStyle = .floating
        view.showsFrameSteppingButtons = true
        view.showsTimecodes = true
        model.attach(view)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
