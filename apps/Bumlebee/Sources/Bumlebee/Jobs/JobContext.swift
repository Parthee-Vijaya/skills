import Foundation

enum BumlebeeError: LocalizedError {
    case unsupported(String)
    case failed(String)
    case needsFFmpeg(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupported(let message): return message
        case .failed(let message): return message
        case .needsFFmpeg(let what):
            return "\(what) kræver ffmpeg. Installér det med \"brew install ffmpeg\", eller vælg stien under Indstillinger."
        case .cancelled: return "Annulleret."
        }
    }
}

/// Passed to every job so engines can report progress, check for cancellation and name their output.
final class JobContext: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var onCancel: [() -> Void] = []
    private let report: (Double, String?) -> Void
    private let range: ClosedRange<Double>

    init(range: ClosedRange<Double> = 0...1, report: @escaping (Double, String?) -> Void) {
        self.range = range
        self.report = report
    }

    private init(parent: JobContext, range: ClosedRange<Double>) {
        self.range = range
        self.report = parent.report
        self.parentRef = parent
    }

    private var parentRef: JobContext?

    var isCancelled: Bool {
        if let parentRef { return parentRef.isCancelled }
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        if let parentRef { parentRef.cancel(); return }
        lock.lock()
        cancelled = true
        let handlers = onCancel
        onCancel = []
        lock.unlock()
        handlers.forEach { $0() }
    }

    /// Registers work to run on cancellation, e.g. killing a child process. Runs immediately if already cancelled.
    func whenCancelled(_ handler: @escaping () -> Void) {
        if let parentRef { parentRef.whenCancelled(handler); return }
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        onCancel.append(handler)
        lock.unlock()
    }

    func checkCancelled() throws {
        if isCancelled { throw BumlebeeError.cancelled }
    }

    /// Reports progress in 0...1 of this context's own share of the job.
    func progress(_ fraction: Double, status: String? = nil) {
        let clamped = min(max(fraction, 0), 1)
        report(range.lowerBound + (range.upperBound - range.lowerBound) * clamped, status)
    }

    func status(_ text: String) {
        report(-1, text)
    }

    /// A child context for step `index` of `count` equal steps.
    func step(_ index: Int, of count: Int) -> JobContext {
        let width = (range.upperBound - range.lowerBound) / Double(max(count, 1))
        let lower = range.lowerBound + width * Double(index)
        return JobContext(parent: self, range: lower...(lower + width))
    }
}
