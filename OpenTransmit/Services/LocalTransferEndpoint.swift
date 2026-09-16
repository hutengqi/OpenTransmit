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
    func canonicalIdentity(_ url: URL) async throws -> String { "local:" + url.resolvingSymlinksInPath().standardizedFileURL.path }
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
    func writer(_ url: URL, replacing: Bool) async throws -> any TransferWriter { try LocalStreamWriter(url, replacing: replacing) }
}
actor LocalStreamReader: TransferReader {
    private var file: FileHandle?
    init(_ url: URL) throws { file = try FileHandle(forReadingFrom: url) }
    func read() throws -> Data { try file?.read(upToCount: 64 * 1024) ?? Data() }
    func close() { try? file?.close(); file = nil }
}
actor LocalStreamWriter: TransferWriter {
    let target: URL
    let staging: URL
    let replacing: Bool
    private var file: FileHandle?
    init(_ target: URL, replacing: Bool) throws {
        self.target = target
        self.replacing = replacing
        staging = target.deletingLastPathComponent().appendingPathComponent(".opentransmit-\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw TransferFailure(message: "无法创建本地临时文件。") }
        do { file = try FileHandle(forWritingTo: staging) }
        catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
    func write(_ data: Data) throws { try file?.write(contentsOf: data) }
    func commit() throws {
        try file?.synchronize(); try file?.close(); file = nil
        if replacing {
            guard rename(staging.path, target.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } else { try FileManager.default.moveItem(at: staging, to: target) }
    }
    func abort() { try? file?.close(); file = nil; try? FileManager.default.removeItem(at: staging) }
}
