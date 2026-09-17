import Foundation
import Darwin

struct LocalTransferEndpoint: TransferEndpoint {
    func entry(_ url: URL) async throws -> FileEntry? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular || type == .typeSymbolicLink else {
                throw TransferFailure(message: "不支持特殊文件：\(url.lastPathComponent)")
            }
            return FileEntry(url: url, isDirectory: type == .typeDirectory, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                             modified: attributes[.modificationDate] as? Date, isSymbolicLink: type == .typeSymbolicLink, permissions: (attributes[.posixPermissions] as? NSNumber)?.uint32Value)
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile { return nil }
    }
    func children(_ url: URL) async throws -> [FileEntry] {
        var result: [FileEntry] = []
        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            if let item = try await entry(child) { result.append(item) }
        }
        return result
    }
    func canonicalIdentity(_ url: URL) async throws -> String {
        // Foundation can spell /var differently before and after a target exists.
        // Resolve an existing ancestor using POSIX, then append missing components.
        var ancestor = url
        var suffix: [String] = []
        while true {
            if let resolved = Darwin.realpath(ancestor.path, nil) {
                let base = String(cString: resolved)
                free(resolved)
                return "local:" + base + (suffix.isEmpty ? "" : (base == "/" ? "" : "/") + suffix.reversed().joined(separator: "/"))
            }
            guard errno == ENOENT, ancestor.path != "/" else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }
    func createDirectory(_ url: URL) async throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
    func removeMovedSource(_ item: FileEntry) async throws {
        try await validateMovedSource(item)
        let result = item.url.path.withCString { path in item.isDirectory ? Darwin.rmdir(path) : Darwin.unlink(path) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func applyMetadata(_ entry: FileEntry, to url: URL) async throws {
        var attributes: [FileAttributeKey: Any] = [:]
        if let date = entry.modified { attributes[.modificationDate] = date }
        if let permissions = entry.permissions { attributes[.posixPermissions] = permissions & 0o777 }
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }
    func reader(_ url: URL) async throws -> any TransferReader { try LocalStreamReader(url) }
    func reader(_ url: URL, offset: Int64) async throws -> any TransferReader { try LocalStreamReader(url, offset: offset) }
    func resumeWriter(_ url: URL, replacing: Bool, staging: URL, offset: Int64) async throws -> any TransferWriter {
        try LocalStreamWriter(url, replacing: replacing, retainedStaging: staging, offset: offset)
    }
    func writer(_ url: URL, replacing: Bool) async throws -> any TransferWriter { try LocalStreamWriter(url, replacing: replacing) }
}
actor LocalStreamReader: TransferReader {
    private var file: FileHandle?
    init(_ url: URL, offset: Int64 = 0) throws {
        let handle = try FileHandle(forReadingFrom: url)
        do { try handle.seek(toOffset: UInt64(offset)); file = handle }
        catch { try? handle.close(); throw error }
    }
    func read() throws -> Data { try file?.read(upToCount: 64 * 1024) ?? Data() }
    func close() { try? file?.close(); file = nil }
}
actor LocalStreamWriter: TransferWriter {
    let target: URL
    let staging: URL
    let replacing: Bool
    private var file: FileHandle?
    let retainPartial: Bool
    init(_ target: URL, replacing: Bool, retainedStaging: URL? = nil, offset: Int64 = 0) throws {
        self.target = target
        self.replacing = replacing
        retainPartial = retainedStaging != nil
        staging = retainedStaging ?? target.deletingLastPathComponent().appendingPathComponent(".opentransmit-\(UUID().uuidString).partial")
        let exists = FileManager.default.fileExists(atPath: staging.path)
        let descriptor = Darwin.open(staging.path, O_WRONLY | O_NOFOLLOW | (exists && retainedStaging != nil ? 0 : O_CREAT | O_EXCL), 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_nlink == 1, info.st_size == offset else { throw TransferFailure(message: "本地续传文件在校验后发生变化。") }
            try handle.seek(toOffset: UInt64(offset)); file = handle
        } catch { try? handle.close(); throw error }
    }
    func prepare() throws { try file?.synchronize() }

    func write(_ data: Data) throws { try file?.write(contentsOf: data) }
    func commit() throws {
        try file?.synchronize(); try file?.close(); file = nil
        if replacing {
            guard rename(staging.path, target.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } else { try FileManager.default.moveItem(at: staging, to: target) }
    }
    func abort() { try? file?.synchronize(); try? file?.close(); file = nil; if !retainPartial { try? FileManager.default.removeItem(at: staging) } }
}
