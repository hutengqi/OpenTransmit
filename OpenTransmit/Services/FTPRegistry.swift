import Foundation

actor FTPRegistry: TransferEndpoint {
    static let shared = FTPRegistry()
    private var sessions: [String: FTPConnection] = [:]
    func connect(_ server: ServerProfile, password: String) async throws -> URL {
        guard server.protocolKind == .ftp || server.protocolKind == .ftps else { throw TransferFailure(message: "不支持的 FTP 协议。") }
        guard !server.username.contains("\0"), !password.contains("\0") else { throw TransferFailure(message: "凭据不能包含 NUL 字符。") }
        let path = server.directory.isEmpty ? "/" : server.directory
        try FTPConnection.validatePath(path)
        let connection = FTPConnection(server: server, password: password)
        var location = URLComponents()
        location.scheme = "opentransmit-ftp"; location.host = UUID().uuidString.lowercased()
        location.user = server.name; location.path = path
        guard let url = location.url else { throw TransferFailure(message: "FTP 路径无效。") }
        _ = try await connection.children(url)
        try Task.checkCancellation()
        sessions[url.host!] = connection
        return url
    }
    func renameItem(_ source: URL, to target: URL) async throws {
        guard source.host == target.host, source.deletingLastPathComponent() == target.deletingLastPathComponent() else {
            throw TransferFailure(message: "仅支持在同一目录内重命名。")
        }
        try await connection(source).command("RNFR", path: source.path, to: target.path)
    }
    func profile(for url: URL) throws -> ServerProfile { try connection(url).server }
    func activeLocation(for server: ServerProfile, path: String) -> URL? {
        guard let session = sessions.first(where: { $0.value.server.matchesEndpoint(server) }) else { return nil }
        var parts = URLComponents()
        parts.scheme = "opentransmit-ftp"; parts.host = session.key; parts.user = server.name; parts.path = path
        return parts.url
    }
    func disconnect(_ url: URL) { if let host = url.host { sessions.removeValue(forKey: host) } }
    private func connection(_ url: URL) throws -> FTPConnection {
        guard url.scheme == "opentransmit-ftp", let host = url.host, let connection = sessions[host] else {
            throw TransferFailure(message: "FTP 会话已关闭，请重新连接。")
        }
        return connection
    }
    func children(_ url: URL) async throws -> [FileEntry] { try await connection(url).children(url) }
    func entry(_ url: URL) async throws -> FileEntry? {
        if url.path == "/" { _ = try connection(url); return FileEntry(url: url, isDirectory: true, size: 0, modified: nil) }
        return try await children(url.deletingLastPathComponent()).first { $0.name == url.lastPathComponent }
    }
    func canonicalIdentity(_ url: URL) throws -> String {
        let server = try connection(url).server
        try FTPConnection.validatePath(url.path)
        // FTP and FTPS can expose the same files; use one identity namespace.
        return "ftp:\(server.username)@\(server.host.lowercased()):\(server.port)\(url.path)"
    }
    func createDirectory(_ url: URL) async throws { try await connection(url).command("MKD", path: url.path) }
    func removeMovedSource(_ item: FileEntry) async throws {
        try await validateMovedSource(item)
        try await connection(item.url).command(item.isDirectory ? "RMD" : "DELE", path: item.url.path)
    }
    func applyMetadata(_ entry: FileEntry, to url: URL) async throws {
        if let modified = entry.modified {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMddHHmmss"
            try await connection(url).command("MFMT " + formatter.string(from: modified), path: url.path)
        }
        if entry.permissions != nil { throw TransferFailure(message: "FTP 不保证 POSIX 权限保留。") }
    }
    func reader(_ url: URL) async throws -> any TransferReader {
        let scratch = try FTPScratch()
        try await connection(url).request(path: url.path, mode: 1, file: scratch.file)
        return try FTPDiskReader(scratch: scratch)
    }
    func reader(_ url: URL, offset: Int64) async throws -> any TransferReader {
        guard let item = try await entry(url), !item.isDirectory, !item.isSymbolicLink, offset <= item.size else {
            throw TransferFailure(message: "FTP 源文件不可读取或偏移超出范围。")
        }
        return FTPRangeReader(connection: try connection(url), url: url, offset: offset, size: item.size)
    }
    func resumeWriter(_ url: URL, replacing: Bool, staging: URL, offset: Int64) async throws -> any TransferWriter {
        let partial = try await entry(staging)
        guard partial == nil ? offset == 0 : (!partial!.isDirectory && !partial!.isSymbolicLink && partial!.size == offset) else {
            throw TransferFailure(message: "FTP 续传文件在校验后发生变化。")
        }
        return try FTPDiskWriter(connection: connection(url), target: url, replacing: replacing, retainedStaging: staging, offset: offset)
    }
    func writer(_ url: URL, replacing: Bool) throws -> any TransferWriter {
        try FTPDiskWriter(connection: connection(url), target: url, replacing: replacing)
    }
    func deleteTree(_ url: URL, depth: Int = 0) async throws {
        try FTPConnection.validatePath(url.path)
        guard url.path != "/", depth <= 128 else { throw TransferFailure(message: "不能删除服务器根目录或过深的目录。") }
        guard let item = try await entry(url) else { throw TransferFailure(message: "远程项目已不存在。") }
        let session = try connection(url)
        if item.isDirectory && !item.isSymbolicLink {
            for child in try await children(url) { try await deleteTree(child.url, depth: depth + 1) }
            try await session.command("RMD", path: url.path)
        } else { try await session.command("DELE", path: url.path) }
    }
}

actor FTPDiskReader: TransferReader {
    let scratch: FTPScratch
    private var file: FileHandle?
    init(scratch: FTPScratch) throws { self.scratch = scratch; file = try FileHandle(forReadingFrom: scratch.file) }
    func read() throws -> Data { try Task.checkCancellation(); return try file?.read(upToCount: 64 * 1024) ?? Data() }
    func close() { try? file?.close(); file = nil; scratch.remove() }
}

actor FTPDiskWriter: TransferWriter {
    let connection: FTPConnection
    let target: URL
    let replacing: Bool
    let scratch: FTPScratch
    let staging: String
    private var file: FileHandle?
    private var committed = false
    private var prepared = false
    let retainPartial: Bool
    let resumeOffset: Int64
    init(connection: FTPConnection, target: URL, replacing: Bool, retainedStaging: URL? = nil, offset: Int64 = 0) throws {
        self.connection = connection; self.target = target; self.replacing = replacing
        retainPartial = retainedStaging != nil; resumeOffset = offset
        scratch = try FTPScratch()
        file = try FileHandle(forWritingTo: scratch.file)
        try file?.truncate(atOffset: UInt64(offset))
        try file?.seek(toOffset: UInt64(offset))
        staging = (retainedStaging ?? target.deletingLastPathComponent().appendingPathComponent(".opentransmit-\(UUID().uuidString).partial")).path
    }
    func write(_ data: Data) throws { try Task.checkCancellation(); try file?.write(contentsOf: data) }
    func prepare() async throws {
        guard !prepared else { return }
        try file?.synchronize(); try file?.close(); file = nil
        let size = (try scratch.file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        if resumeOffset == 0 || Int64(size) > resumeOffset {
            try await connection.request(path: staging, mode: 2, file: scratch.file, offset: resumeOffset)
        }
        prepared = true
    }
    func commit() async throws {
        try await prepare()
        let backup = target.deletingLastPathComponent().appendingPathComponent(".opentransmit-\(UUID().uuidString).backup").path
        // Re-check names before publishing. FTP has no portable atomic no-clobber rename.
        let siblings = try await connection.children(target.deletingLastPathComponent())
        let exists = siblings.contains { $0.name == target.lastPathComponent }
        if exists && !replacing { throw TransferFailure(message: "目标在传输期间出现同名项目，请刷新后重试。") }
        if exists {
            do { try await connection.command("RNFR", path: target.path, to: backup) }
            catch { throw TransferFailure(message: "FTP 备份步骤中断。原文件可能仍在目标位置或备份 \(backup)，请检查后重试。") }
        }
        do { try await connection.command("RNFR", path: staging, to: target.path) }
        catch {
            if exists {
                let restored = await Task.detached { [connection, target] in
                    do { try await connection.command("RNFR", path: backup, to: target.path); return true }
                    catch { return false }
                }.value
                if !restored { throw TransferFailure(message: "FTP 提交或回滚失败，原文件备份可能位于 \(backup)，请保留备份并检查目标。") }
            }
            throw error
        }
        committed = true
        scratch.remove()
        if exists {
            do { try await connection.command("DELE", path: backup) }
            catch { throw TransferFailure(message: "文件已传输，但旧文件备份未能清理：\(backup)") }
        }
    }
    func abort() async {
        try? file?.close(); file = nil; scratch.remove()
        guard !committed, !retainPartial else { return }
        await Task.detached { [connection, staging] in try? await connection.command("DELE", path: staging) }.value
    }
}

/// Bounded range requests expose downloaded chunks before the whole FTP file completes.
actor FTPRangeReader: TransferReader {
    let connection: FTPConnection
    let url: URL
    var offset: Int64
    let size: Int64
    init(connection: FTPConnection, url: URL, offset: Int64, size: Int64) {
        self.connection = connection; self.url = url; self.offset = offset; self.size = size
    }
    func read() async throws -> Data {
        try Task.checkCancellation()
        guard offset < size else { return Data() }
        let scratch = try FTPScratch()
        defer { scratch.remove() }
        let length = min(Int64(64 * 1024), size - offset)
        try await connection.request(path: url.path, mode: 1, file: scratch.file, offset: offset, length: length)
        let bytes = try scratch.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes == length else { throw TransferFailure(message: "FTP 服务器未正确返回续传范围，已停止传输。") }
        let data = try Data(contentsOf: scratch.file)
        offset += Int64(data.count)
        return data
    }
    func close() {}
}
