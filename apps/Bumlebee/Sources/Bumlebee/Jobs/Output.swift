import Foundation

/// Decides where converted files go and gives them names that never overwrite anything.
enum Output {
    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static func directory(for input: URL) -> URL {
        let beside = input.deletingLastPathComponent()
        switch Prefs.outputLocation {
        case .besideOriginal:
            return FileManager.default.isWritableFile(atPath: beside.path) ? beside : downloads
        case .downloads:
            return downloads
        case .custom:
            let path = Prefs.customOutputPath
            var isDirectory: ObjCBool = false
            if !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return beside
        }
    }

    /// `<dir>/<name> (<suffix>).<ext>`, numbered if it already exists.
    static func url(for input: URL, ext: String, suffix: String? = nil) -> URL {
        var base = input.baseName
        if let suffix, !suffix.isEmpty { base += " (\(suffix))" }
        return unique(in: directory(for: input), base: base, ext: ext)
    }

    static func url(named base: String, beside input: URL, ext: String) -> URL {
        unique(in: directory(for: input), base: base, ext: ext)
    }

    /// Creates and returns a fresh folder for jobs that produce many files.
    static func folder(for input: URL, suffix: String) throws -> URL {
        let url = unique(in: directory(for: input), base: "\(input.baseName) (\(suffix))", ext: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func unique(in directory: URL, base: String, ext: String) -> URL {
        func make(_ name: String) -> URL {
            ext.isEmpty
                ? directory.appendingPathComponent(name, isDirectory: true)
                : directory.appendingPathComponent("\(name).\(ext)")
        }
        let first = make(base)
        if !FileManager.default.fileExists(atPath: first.path) { return first }
        var index = 2
        while true {
            let candidate = make("\(base) \(index)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// A fresh scratch directory. Callers remove it when they are done.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bumlebee-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
