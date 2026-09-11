import Foundation
import Darwin

/// Filesystem work stays off the main actor, including recursive directory copies.
actor LocalFileService {
    private let fm = FileManager.default
    func list(_ directory: URL, showHidden: Bool) throws -> [FileEntry] {
        try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: showHidden ? [] : [.skipsHiddenFiles]).map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            return FileEntry(url: url, isDirectory: values.isDirectory == true && values.isSymbolicLink != true, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func copy(_ source: URL, into directory: URL, duplicateInPlace: Bool = false,
              conflict: @Sendable (FileConflict) async -> ConflictChoice,
              progress: @Sendable (Int64) async -> Void) async throws -> Bool {
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let target = directory.appendingPathComponent(source.lastPathComponent)
        let targetPath = target.resolvingSymlinksInPath().standardizedFileURL.path
        if duplicateInPlace && targetPath == sourcePath {
            return try await copyItem(source, to: uniqueTarget(target), conflict: conflict, progress: progress)
        }
        guard targetPath != sourcePath, !targetPath.hasPrefix(sourcePath + "/") else {
            throw failure("不能将项目复制到自身或其子目录。")
        }
        return try await copyItem(source, to: target, conflict: conflict, progress: progress)
    }

    private func copyItem(_ source: URL, to requestedTarget: URL,
                          conflict: @Sendable (FileConflict) async -> ConflictChoice,
                          progress: @Sendable (Int64) async -> Void) async throws -> Bool {
        try Task.checkCancellation()
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw failure("暂不复制符号链接：\(source.lastPathComponent)") }
        guard values.isDirectory == true || values.isRegularFile == true else { throw failure("不支持此文件类型：\(source.lastPathComponent)") }
        var target = requestedTarget
        var replacing = false
        if fm.fileExists(atPath: target.path) {
            let targetValues = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard targetValues.isSymbolicLink != true else { throw failure("目标是符号链接，已停止：\(target.lastPathComponent)") }
            if values.isDirectory == true && targetValues.isDirectory == true {
                return try await copyChildren(source, to: target, conflict: conflict, progress: progress)
            }
            switch await conflict(FileConflict(source: source, destination: target)) {
            case .cancel: throw CancellationError()
            case .skip: return false
            case .keepBoth: target = uniqueTarget(target)
            case .replace:
                guard values.isDirectory != true && targetValues.isDirectory != true else {
                    throw failure("文件与目录类型不同，不能替换；请选择保留两者或跳过。")
                }
                replacing = true
            }
        }
        try Task.checkCancellation()
        if values.isDirectory == true {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            return try await copyChildren(source, to: target, conflict: conflict, progress: progress)
        }
        // Stage alongside the destination so a failed copy never truncates an existing file.
        let staging = target.deletingLastPathComponent().appendingPathComponent(".opentransmit-\(UUID().uuidString).partial")
        guard fm.createFile(atPath: staging.path, contents: nil) else { throw failure("无法创建临时文件。") }
        defer { try? fm.removeItem(at: staging) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: staging)
        defer { try? output.close() }
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            try output.write(contentsOf: data)
            await progress(Int64(data.count))
        }
        try output.synchronize()
        try output.close()
        try Task.checkCancellation()
        if replacing {
            // POSIX rename atomically replaces a file on the same volume.
            guard rename(staging.path, target.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } else {
            // moveItem fails if a new destination appeared after the conflict check.
            try fm.moveItem(at: staging, to: target)
        }
        return true
    }

    private func copyChildren(_ source: URL, to target: URL,
                              conflict: @Sendable (FileConflict) async -> ConflictChoice,
                              progress: @Sendable (Int64) async -> Void) async throws -> Bool {
        var allCopied = true
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let copied = try await copyItem(child, to: target.appendingPathComponent(child.lastPathComponent), conflict: conflict, progress: progress)
            allCopied = allCopied && copied
        }
        return allCopied
    }

    private func uniqueTarget(_ target: URL) -> URL {
        let ext = target.pathExtension
        let base = ext.isEmpty ? target.lastPathComponent : target.deletingPathExtension().lastPathComponent
        var number = 1
        while true {
            let name = base + " 副本" + (number == 1 ? "" : " \(number)") + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = target.deletingLastPathComponent().appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "OpenTransmit", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
