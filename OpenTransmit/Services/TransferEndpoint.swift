import Foundation

extension URL {
    var isRemoteFile: Bool { scheme == "opentransmit-sftp" || scheme == "opentransmit-ftp" }
    var isTransferLocation: Bool { isFileURL || isRemoteFile }
    var locationLabel: String { isFileURL ? path : "\(user ?? "SFTP") · \(path)" }
}

struct TransferFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

protocol TransferReader: Sendable {
    func read() async throws -> Data
    func close() async
}
protocol TransferWriter: Sendable {
    func write(_ data: Data) async throws
    func prepare() async throws
    func commit() async throws
    func abort() async
}
extension TransferWriter { func prepare() async throws {} }

protocol TransferEndpoint: Sendable {
    func entry(_ url: URL) async throws -> FileEntry?
    func children(_ url: URL) async throws -> [FileEntry]
    func canonicalIdentity(_ url: URL) async throws -> String
    func createDirectory(_ url: URL) async throws
    func applyMetadata(_ entry: FileEntry, to url: URL) async throws
    func removeMovedSource(_ item: FileEntry) async throws
    func reader(_ url: URL) async throws -> any TransferReader
    func writer(_ url: URL, replacing: Bool) async throws -> any TransferWriter
    func reader(_ url: URL, offset: Int64) async throws -> any TransferReader
    func resumeWriter(_ url: URL, replacing: Bool, staging: URL, offset: Int64) async throws -> any TransferWriter
}

extension TransferEndpoint {
    func reader(_ url: URL, offset: Int64) async throws -> any TransferReader {
        guard offset == 0 else { throw TransferFailure(message: "此端点不支持偏移读取。") }
        return try await reader(url)
    }
    func resumeWriter(_ url: URL, replacing: Bool, staging: URL, offset: Int64) async throws -> any TransferWriter {
        throw TransferFailure(message: "此端点不支持断点续传。")
    }
    func removeMovedSource(_ item: FileEntry) async throws {
        throw TransferFailure(message: "此端点不支持移动后的源项目移除。")
    }
    func validateMovedSource(_ item: FileEntry) async throws {
        try Task.checkCancellation()
        guard item.url.path != "/", let current = try await entry(item.url),
              !current.isSymbolicLink, current.isDirectory == item.isDirectory,
              item.isDirectory || (current.size == item.size && current.modified == item.modified) else {
            throw TransferFailure(message: "目标已写入，但源项目已变化，未移除：\(item.url.path)")
        }
    }
    func applyMetadata(_ entry: FileEntry, to url: URL) async throws {}
}

/// Endpoint-neutral recursive transfer. Protocol streams own their bounded I/O windows.
actor EndpointTransferEngine {
    let endpoint: any TransferEndpoint
    init(endpoint: any TransferEndpoint) { self.endpoint = endpoint }

    func totalBytes(_ source: URL, depth: Int = 0) async throws -> Int64 {
        try Task.checkCancellation()
        guard depth < 128, let item = try await endpoint.entry(source) else {
            throw TransferFailure(message: "无法统计源项目，可能不存在、为符号链接或层级过深。")
        }
        if item.isSystemMetadata { return 0 }
        guard !item.isSymbolicLink else { throw TransferFailure(message: "暂不传输符号链接。") }
        if !item.isDirectory { return max(0, item.size) }
        var total: Int64 = 0
        for child in try await endpoint.children(source) {
            let count = try await totalBytes(child.url, depth: depth + 1)
            let sum = total.addingReportingOverflow(count)
            guard !sum.overflow else { throw TransferFailure(message: "目录大小超过支持范围。") }
            total = sum.partialValue
        }
        return total
    }

    func copy(_ source: URL, into directory: URL, duplicateInPlace: Bool = false, moving: Bool = false,
              journal: TransferCheckpointJournal? = nil,
              phase: @Sendable (String) async -> Void = { _ in },
              resumed: @Sendable (Int64) async -> Void = { _ in },
              conflict: @Sendable (FileConflict) async -> ConflictChoice,
              progress: @Sendable (Int64) async -> Void,
              warning: @Sendable (String) async -> Void = { _ in }) async throws -> Bool {
        try Task.checkCancellation()
        guard source.isTransferLocation, directory.isTransferLocation,
              !source.lastPathComponent.isEmpty, source.lastPathComponent != "/",
              source.lastPathComponent != ".", source.lastPathComponent != ".." else {
            throw TransferFailure(message: "请选择文件或子目录进行传输，不能复制文件系统根目录。")
        }
        guard let item = try await endpoint.entry(source) else { throw TransferFailure(message: "源项目已不存在。") }
        if item.isSystemMetadata { return false }
        guard !item.isSymbolicLink else { throw TransferFailure(message: "暂不传输符号链接。") }
        var target = directory.appendingPathComponent(source.lastPathComponent)
        let sourceIdentity = try await endpoint.canonicalIdentity(source)
        let targetIdentity = try await endpoint.canonicalIdentity(target)
        if sourceIdentity == targetIdentity && duplicateInPlace { target = try await unique(target) }
        else if sourceIdentity == targetIdentity || targetIdentity.hasPrefix(sourceIdentity + "/") {
            throw TransferFailure(message: "不能将项目传输到自身或其子目录。")
        }
        return try await copyItem(item, to: target, depth: 0, moving: moving, journal: journal, phase: phase, resumed: resumed, conflict: conflict, progress: progress, warning: warning)
    }

    private func copyItem(_ item: FileEntry, to requested: URL, depth: Int, moving: Bool,
                          journal: TransferCheckpointJournal?, phase: @Sendable (String) async -> Void,
                          resumed: @Sendable (Int64) async -> Void,
                          conflict: @Sendable (FileConflict) async -> ConflictChoice,
                          progress: @Sendable (Int64) async -> Void,
                          warning: @Sendable (String) async -> Void) async throws -> Bool {
        try Task.checkCancellation()
        guard depth < 128, !item.isSymbolicLink else { throw TransferFailure(message: "目录层级过深或包含符号链接：\(item.name)") }
        var target = requested
        var replacing = false
        if let existing = try await endpoint.entry(target) {
            guard !existing.isSymbolicLink else { throw TransferFailure(message: "目标是符号链接：\(existing.name)") }
            if !(item.isDirectory && existing.isDirectory) {
                switch await conflict(FileConflict(source: item.url, destination: target, sourceEntry: item, destinationEntry: existing)) {
                case .cancel: throw CancellationError()
                case .skip: return false
                case .keepBoth: target = try await unique(target)
                case .replace:
                    guard !item.isDirectory, !existing.isDirectory else { throw TransferFailure(message: "文件和目录类型不同，请保留两者或跳过。") }
                    replacing = true
                }
            }
        }
        try Task.checkCancellation()
        if item.isDirectory {
            let created = try await endpoint.entry(target) == nil
            if created { try await endpoint.createDirectory(target) }
            var complete = true
            for child in try await endpoint.children(item.url) where !child.isSystemMetadata {
                guard child.name != ".", child.name != "..", !child.name.contains("/"), !child.name.contains("\0") else {
                    throw TransferFailure(message: "服务器返回了无效文件名。")
                }
                let copied = try await copyItem(child, to: target.appendingPathComponent(child.name), depth: depth + 1, moving: moving, journal: journal, phase: phase, resumed: resumed, conflict: conflict, progress: progress, warning: warning)
                complete = copied && complete
            }
            if created { await preserve(item, at: target, warning: warning) }
            if moving {
                if try await endpoint.children(item.url).isEmpty {
                    try await endpoint.removeMovedSource(item)
                } else {
                    await warning("\(item.url.path)：保留含跳过项目、系统元数据或新增文件的源目录。")
                    complete = false
                }
            }
            return complete
        }
        var checkpoint: FileCheckpoint?
        var checkpointKey = ""
        var staging: URL?
        var offset: Int64 = 0
        if let journal {
            await phase("正在校验源文件与续传数据…")
            checkpointKey = TransferCheckpointJournal.key(try await endpoint.canonicalIdentity(item.url) + "\n" + endpoint.canonicalIdentity(target))
            let digest = try await endpoint.contentDigest(item.url)
            if let saved = await journal.record(for: checkpointKey) {
                guard saved.size == item.size, saved.modified == item.modified, saved.digest == digest else {
                    throw TransferFailure(message: "源文件已变化，已拒绝续传。请移除原任务记录后重新添加任务；旧临时文件保留供检查。")
                }
                checkpoint = saved
            } else {
                let saved = FileCheckpoint(token: UUID(), size: item.size, modified: item.modified, digest: digest)
                try await journal.save(saved, for: checkpointKey)
                checkpoint = saved
            }
            staging = target.deletingLastPathComponent().appendingPathComponent(checkpoint!.stagingName)
            if let partial = try await endpoint.entry(staging!) {
                guard !partial.isDirectory, !partial.isSymbolicLink, partial.size >= 0, partial.size <= item.size else {
                    throw TransferFailure(message: "续传临时文件类型或长度异常，未修改目标。")
                }
                let prefix = try await endpoint.contentDigest(item.url, limit: partial.size)
                guard try await endpoint.contentDigest(staging!) == prefix else {
                    throw TransferFailure(message: "已传内容校验不一致，已拒绝续传。请移除任务记录后重新添加任务；旧临时文件保留供检查。")
                }
                offset = partial.size
            }
        }
        let input = try await endpoint.reader(item.url, offset: offset)
        do {
            let output: any TransferWriter
            if let staging { output = try await endpoint.resumeWriter(target, replacing: replacing, staging: staging, offset: offset) }
            else { output = try await endpoint.writer(target, replacing: replacing) }
            if offset > 0 { await progress(offset); await resumed(offset) }
            await phase(offset > 0 ? "从已校验位置继续传输" : "传输与提交中")
            do {
                var count: Int64 = offset
                while true {
                    try Task.checkCancellation()
                    let data = try await input.read()
                    if data.isEmpty { break }
                    try await output.write(data)
                    count += Int64(data.count)
                    await progress(Int64(data.count))
                }
                guard count == item.size else { throw TransferFailure(message: "源文件大小在传输期间发生变化，请重试。") }
                try Task.checkCancellation()
                try await output.prepare()
                if let checkpoint, let staging {
                    await phase("正在校验完整文件并提交…")
                    guard try await endpoint.contentDigest(staging) == checkpoint.digest,
                          try await endpoint.contentDigest(item.url) == checkpoint.digest else {
                        throw TransferFailure(message: "完整内容校验失败，目标未提交，源文件保留。")
                    }
                }
                try Task.checkCancellation()
                try await output.commit()
                if let journal { try await journal.save(nil, for: checkpointKey) }
                await input.close()
                await preserve(item, at: target, warning: warning)
                if moving {
                    do { try await endpoint.removeMovedSource(item) }
                    catch { throw TransferFailure(message: "目标已提交，源文件未确认移除：\(item.url.path)（\(error.localizedDescription)）") }
                }
                return true
            } catch {
                await output.abort()
                throw error
            }
        } catch {
            await input.close()
            throw error
        }
    }
    private func preserve(_ item: FileEntry, at target: URL, warning: @Sendable (String) async -> Void) async {
        do { try await endpoint.applyMetadata(item, to: target) }
        catch { await warning("\(target.path)：内容已复制，但元数据未完整保留（\(error.localizedDescription)）") }
    }
    private func unique(_ target: URL) async throws -> URL {
        let ext = target.pathExtension
        let base = ext.isEmpty ? target.lastPathComponent : target.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            try Task.checkCancellation()
            let name = base + " 副本" + (n == 1 ? "" : " \(n)") + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = target.deletingLastPathComponent().appendingPathComponent(name)
            if try await endpoint.entry(candidate) == nil { return candidate }
            n += 1
        }
    }
}
