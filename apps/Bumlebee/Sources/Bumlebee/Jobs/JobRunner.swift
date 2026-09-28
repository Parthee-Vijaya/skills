import AppKit
import SwiftUI

final class JobProgressModel: ObservableObject {
    @Published var title: String
    @Published var detail: String
    @Published var fraction: Double = 0
    var isFinished = false
    var onCancel: () -> Void = {}

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

/// Runs jobs off the main thread, shows a small progress window per job and reveals the results in Finder.
@MainActor
final class JobRunner {
    static let shared = JobRunner()
    private var panels: [ProgressPanel] = []

    func run(title: String, files: [URL], work: @escaping (JobContext) async throws -> [URL]) {
        let model = JobProgressModel(title: title, detail: files.count == 1 ? files[0].lastPathComponent : "\(files.count) filer")
        let panel = ProgressPanel(model: model)
        let context = JobContext { fraction, status in
            DispatchQueue.main.async {
                if fraction >= 0 { model.fraction = fraction }
                if let status { model.detail = status }
            }
        }
        model.onCancel = { context.cancel() }
        panels.append(panel)

        // Quick jobs finish before the window would appear, which avoids flicker.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !model.isFinished else { return }
            panel.show(slot: self.panels.firstIndex { $0 === panel } ?? 0)
        }

        Task.detached(priority: .userInitiated) {
            do {
                let outputs = try await work(context)
                await self.finish(panel, model: model, outputs: outputs, error: nil, count: files.count)
            } catch {
                await self.finish(panel, model: model, outputs: [], error: error, count: files.count)
            }
        }
    }

    private func finish(_ panel: ProgressPanel, model: JobProgressModel, outputs: [URL], error: Error?, count: Int) {
        model.isFinished = true
        panel.close()
        panels.removeAll { $0 === panel }

        if let error {
            if error.isCancellation { return }
            Alerts.error(title: "\(model.title) mislykkedes", message: error.localizedDescription)
            return
        }
        Prefs.countProcessed(count)
        if Prefs.playSound { NSSound(named: "Glass")?.play() }
        let existing = outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if Prefs.revealInFinder, !existing.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }
}

/// A compact floating window with the job's name, the current file, a progress bar and a cancel button.
@MainActor
final class ProgressPanel {
    private let window: NSPanel

    init(model: JobProgressModel) {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 84),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: JobProgressView(model: model))
    }

    func show(slot: Int) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16 - CGFloat(slot) * (size.height + 10))
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
    }
}

struct JobProgressView: View {
    @ObservedObject var model: JobProgressModel

    var body: some View {
        HStack(spacing: 14) {
            BeeMark(size: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(model.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: model.fraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.honeyDeep)
            }
            Button {
                model.onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Annullér")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 360, height: 84)
    }
}
