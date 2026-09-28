import Foundation

/// Runs command-line tools (ditto, tar, ffmpeg …) without blocking, with cancellation.
enum ProcessRunner {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var pendingLine = ""
        let onLine: ((String) -> Void)?

        init(onLine: ((String) -> Void)?) { self.onLine = onLine }

        func appendOut(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); out.append(data); lock.unlock()
        }

        func appendErr(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            err.append(data)
            var lines: [String] = []
            if onLine != nil {
                pendingLine += String(decoding: data, as: UTF8.self)
                // ffmpeg separates progress updates with carriage returns.
                var parts = pendingLine.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                pendingLine = parts.removeLast()
                lines = parts.filter { !$0.isEmpty }
            }
            lock.unlock()
            lines.forEach { onLine?($0) }
        }

        func result(status: Int32) -> Result {
            lock.lock(); defer { lock.unlock() }
            return Result(status: status, stdout: out, stderr: String(decoding: err, as: UTF8.self))
        }
    }

    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        stdoutFile: URL? = nil,
        context: JobContext? = nil,
        onStderrLine: ((String) -> Void)? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice

        let collector = Collector(onLine: onStderrLine)
        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe

        let outFile: FileHandle?
        if let stdoutFile {
            FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
            outFile = try FileHandle(forWritingTo: stdoutFile)
            process.standardOutput = outFile
        } else {
            outFile = nil
            process.standardOutput = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.appendOut(handle.availableData)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.appendErr(handle.availableData)
        }

        let result: Result = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                errPipe.fileHandleForReading.readabilityHandler = nil
                collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                if stdoutFile == nil {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                }
                try? outFile?.close()
                continuation.resume(returning: collector.result(status: finished.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                try? outFile?.close()
                continuation.resume(throwing: error)
                return
            }
            context?.whenCancelled {
                if process.isRunning { process.terminate() }
            }
        }

        if let context { try context.checkCancelled() }
        return result
    }

    /// Runs a tool and throws with its error output if it exits non-zero.
    @discardableResult
    static func check(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        stdoutFile: URL? = nil,
        context: JobContext? = nil
    ) async throws -> Result {
        let result = try await run(executable, arguments, currentDirectory: currentDirectory, stdoutFile: stdoutFile, context: context)
        guard result.status == 0 else {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            throw BumlebeeError.failed("\(name) fejlede: \(result.stderr.lastLines(4))")
        }
        return result
    }
}

extension String {
    func lastLines(_ count: Int) -> String {
        split(whereSeparator: \.isNewline).suffix(count).joined(separator: "\n")
    }
}
