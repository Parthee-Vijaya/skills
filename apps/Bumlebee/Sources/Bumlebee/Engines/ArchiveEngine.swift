import Foundation

/// Packing and unpacking with the tools that ship with macOS (ditto, zip, tar, gzip).
/// macOS's tar is libarchive, so it also extracts RAR, 7-Zip, ISO, XZ and friends.
enum ArchiveEngine {
    static func archive(_ urls: [URL], as format: Format, context: JobContext) async throws -> URL {
        guard let first = urls.first else { throw BumlebeeError.failed("Ingen filer.") }
        let name = urls.count == 1 ? first.lastPathComponent : "Arkiv"
        let output = Output.unique(in: Output.directory(for: first), base: name, ext: format.fileExtension)
        try await archive(urls, as: format, to: output, context: context)
        return output
    }

    static func archive(_ urls: [URL], as format: Format, to output: URL, context: JobContext) async throws {
        guard let first = urls.first else { throw BumlebeeError.failed("Ingen filer.") }
        let parent = first.deletingLastPathComponent().standardizedFileURL
        let sameParent = urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == parent }

        // Items from different folders are staged together so the archive has a flat top level.
        var workDirectory = parent
        var staging: URL?
        if !sameParent {
            let temp = try Output.temporaryDirectory()
            for url in urls {
                try FileManager.default.copyItem(at: url, to: temp.appendingPathComponent(url.lastPathComponent))
            }
            staging = temp
            workDirectory = temp
        }
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        let names = urls.map(\.lastPathComponent)
        context.status("Pakker \(names.count == 1 ? names[0] : "\(names.count) emner")")

        switch format {
        case .zip:
            if urls.count == 1 {
                try await ProcessRunner.check("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, output.path], context: context)
            } else {
                try await ProcessRunner.check("/usr/bin/zip", ["-q", "-r", "-y", "-X", output.path] + names, currentDirectory: workDirectory, context: context)
            }
        case .tar:
            try await ProcessRunner.check("/usr/bin/tar", ["--no-mac-metadata", "-cf", output.path, "-C", workDirectory.path] + names, context: context)
        case .tgz:
            try await ProcessRunner.check("/usr/bin/tar", ["--no-mac-metadata", "-czf", output.path, "-C", workDirectory.path] + names, context: context)
        case .gz:
            guard urls.count == 1, FileKind.of(first) != .folder else {
                try await archive(urls, as: .tgz, to: output.deletingPathExtension().appendingPathExtension("tar.gz"), context: context)
                return
            }
            try await ProcessRunner.check("/usr/bin/gzip", ["-c", "-9", first.path], stdoutFile: output, context: context)
        default:
            throw BumlebeeError.unsupported("\(format.label) er ikke et arkivformat.")
        }
        context.progress(1)
    }

    /// Unpacks next to the archive. A single top-level item is moved out instead of being wrapped in a folder.
    static func extract(_ url: URL, context: JobContext) async throws -> URL {
        let directory = Output.directory(for: url)
        let ext = url.normalizedExtension

        if ext == "gz" {
            let inner = URL(fileURLWithPath: url.baseName)
            let output = Output.unique(in: directory, base: inner.deletingPathExtension().lastPathComponent, ext: inner.pathExtension)
            try await ProcessRunner.check("/usr/bin/gzip", ["-d", "-c", url.path], stdoutFile: output, context: context)
            return output
        }

        let temp = try Output.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        context.status("Pakker \(url.lastPathComponent) ud")
        if ext == "zip" {
            try await ProcessRunner.check("/usr/bin/ditto", ["-x", "-k", url.path, temp.path], context: context)
        } else {
            try await ProcessRunner.check("/usr/bin/tar", ["-xf", url.path, "-C", temp.path], context: context)
        }

        let items = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
        if items.count == 1, let only = items.first {
            let isFolder = FileKind.of(only) == .folder
            let destination = isFolder
                ? Output.unique(in: directory, base: only.lastPathComponent, ext: "")
                : Output.unique(in: directory, base: only.deletingPathExtension().lastPathComponent, ext: only.pathExtension)
            try FileManager.default.moveItem(at: only, to: destination)
            return destination
        }
        let folder = Output.unique(in: directory, base: url.baseName, ext: "")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in items {
            try FileManager.default.moveItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
        }
        context.progress(1)
        return folder
    }

    /// Archive → archive of another type, via a temporary extraction.
    static func repack(_ url: URL, as format: Format, context: JobContext) async throws -> URL {
        if FileKind.of(url) != .archive {
            return try await archive([url], as: format, context: context)
        }
        let temp = try Output.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let extractTo = temp.appendingPathComponent("x", isDirectory: true)
        try FileManager.default.createDirectory(at: extractTo, withIntermediateDirectories: true)
        if url.normalizedExtension == "zip" {
            try await ProcessRunner.check("/usr/bin/ditto", ["-x", "-k", url.path, extractTo.path], context: context.step(0, of: 2))
        } else {
            try await ProcessRunner.check("/usr/bin/tar", ["-xf", url.path, "-C", extractTo.path], context: context.step(0, of: 2))
        }
        let items = try FileManager.default.contentsOfDirectory(at: extractTo, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" }
        guard !items.isEmpty else { throw BumlebeeError.failed("\(url.lastPathComponent) er tomt.") }
        let output = Output.url(for: url, ext: format.fileExtension)
        // A lone folder is zipped as-is; otherwise the loose items become the archive's top level.
        try await archive(items, as: format, to: output, context: context.step(1, of: 2))
        return output
    }

    /// Lists an archive's contents for the metadata window.
    static func listing(_ url: URL) async throws -> [String] {
        let result = try await ProcessRunner.check("/usr/bin/tar", ["-tf", url.path])
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
