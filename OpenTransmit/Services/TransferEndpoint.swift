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
    func commit() async throws
    func abort() async
}
protocol TransferEndpoint: Sendable {
    func entry(_ url: URL) async throws -> FileEntry?
    func children(_ url: URL) async throws -> [FileEntry]
    func canonicalIdentity(_ url: URL) async throws -> String
    func createDirectory(_ url: URL) async throws
    func applyMetadata(_ entry: FileEntry, to url: URL) async throws
    func reader(_ url: URL) async throws -> any TransferReader
    func writer(_ url: URL, replacing: Bool) async throws -> any TransferWriter
}

extension TransferEndpoint {
    func applyMetadata(_ entry: FileEntry, to url: URL) async throws {}
}

/// Endpoint-neutral recursive transfer. At most one 64 KiB payload is in flight.
actor EndpointTransferEngine {
    let endpoint: any TransferEndpoint
    init(endpoint: any TransferEndpoint) { self.endpoint = endpoint }

    func totalBytes(_ source: URL, depth: Int = 0) async throws -> Int64 {
        try Task.checkCancellation()
        guard depth < 128, let item = try await endpoint.entry(source), !item.isSymbolicLink else {
            throw TransferFailure(message: "无法统计源项目，可能不存在、为符号链接或层级过深。")
        }
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

    func copy(_ source: URL, into directory: URL, duplicateInPlace: Bool = false,
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
        guard !item.isSymbolicLink else { throw TransferFailure(message: "暂不传输符号链接。") }
        var target = directory.appendingPathComponent(source.lastPathComponent)
        let sourceIdentity = try await endpoint.canonicalIdentity(source)
        let targetIdentity = try await endpoint.canonicalIdentity(target)
        if sourceIdentity == targetIdentity && duplicateInPlace { target = try await unique(target) }
        else if sourceIdentity == targetIdentity || targetIdentity.hasPrefix(sourceIdentity + "/") {
            throw TransferFailure(message: "不能将项目传输到自身或其子目录。")
        }
        return try await copyItem(item, to: target, depth: 0, conflict: conflict, progress: progress, warning: warning)
    }

    private func copyItem(_ item: FileEntry, to requested: URL, depth: Int,
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
            for child in try await endpoint.children(item.url) {
                guard child.name != ".", child.name != "..", !child.name.contains("/"), !child.name.contains("\0") else {
                    throw TransferFailure(message: "服务器返回了无效文件名。")
                }
                let copied = try await copyItem(child, to: target.appendingPathComponent(child.name), depth: depth + 1, conflict: conflict, progress: progress, warning: warning)
                complete = copied && complete
            }
            if created { await preserve(item, at: target, warning: warning) }
            return complete
        }
        let input = try await endpoint.reader(item.url)
        do {
            let output = try await endpoint.writer(target, replacing: replacing)
            do {
                var count: Int64 = 0
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
                try await output.commit()
                await input.close()
                await preserve(item, at: target, warning: warning)
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
