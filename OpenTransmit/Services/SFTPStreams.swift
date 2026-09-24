import Foundation
@preconcurrency import Citadel
import NIOCore

// Keep requests small for server compatibility, but amortize network round trips.
private enum SFTPWindow {
    static let chunk = 32 * 1024
    static let requests = 32
    static let bytes = chunk * requests
}

actor SFTPStreamReader: TransferReader {
    let sftp: SFTPClient
    let file: SFTPFile
    private var offset: UInt64
    private var ended = false
    init(sftp: SFTPClient, file: SFTPFile, offset: Int64 = 0) {
        self.sftp = sftp; self.file = file; self.offset = UInt64(offset)
    }
    func read() async throws -> Data {
        try Task.checkCancellation()
        if ended { return Data() }
        let start = offset
        let blocks = try await SFTPDeadline.run(sftp) { [file] in
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for index in 0..<SFTPWindow.requests {
                    group.addTask {
                        var data = Data()
                        // A short DATA response need not mean EOF. Fill this range first.
                        while data.count < SFTPWindow.chunk {
                            try Task.checkCancellation()
                            let buffer = try await file.read(
                                from: start + UInt64(index * SFTPWindow.chunk + data.count),
                                length: UInt32(SFTPWindow.chunk - data.count))
                            if buffer.readableBytes == 0 { break }
                            guard buffer.readableBytes <= SFTPWindow.chunk - data.count else {
                                throw TransferFailure(message: "SFTP 返回的数据超过请求范围。")
                            }
                            data.append(contentsOf: buffer.readableBytesView)
                        }
                        return (index, data)
                    }
                }
                var blocks = Array(repeating: Data(), count: SFTPWindow.requests)
                for try await (index, data) in group { blocks[index] = data }
                return blocks
            }
        }
        var result = Data()
        for block in blocks {
            guard !ended || block.isEmpty else {
                throw TransferFailure(message: "SFTP 文件在读取期间发生变化。")
            }
            result.append(block)
            if block.count < SFTPWindow.chunk { ended = true }
        }
        offset += UInt64(result.count)
        return result
    }
    func close() async { try? await sftp.close() }
}

actor SFTPStreamWriter: TransferWriter {
    let connection: SFTPConnection
    let sftp: SFTPClient
    let file: SFTPFile
    let target: URL
    let staging: String
    let replacing: Bool
    private var offset: UInt64 = 0
    private var committed = false
    private var pending = Data()
    let retainPartial: Bool
    private init(connection: SFTPConnection, sftp: SFTPClient, file: SFTPFile, target: URL, staging: String, replacing: Bool, retainPartial: Bool, offset: Int64) {
        self.connection = connection; self.sftp = sftp; self.file = file
        self.target = target; self.staging = staging; self.replacing = replacing
        self.retainPartial = retainPartial; self.offset = UInt64(offset)
    }
    static func open(connection: SFTPConnection, target: URL, replacing: Bool, retainedStaging: URL? = nil, offset: Int64 = 0, existing: Bool = false) async throws -> SFTPStreamWriter {
        let sftp = try await connection.open()
        let staging = (retainedStaging ?? target.deletingLastPathComponent().appendingPathComponent(".opentransmit-\(UUID().uuidString).partial")).path
        do {
            var newAttributes = SFTPFileAttributes()
            newAttributes.permissions = 0o600
            let attributes = newAttributes
            let file = try await SFTPDeadline.run(sftp) { try await sftp.openFile(filePath: staging, flags: existing ? [.write] : [.write, .create, .forceCreate], attributes: attributes) }
            return SFTPStreamWriter(connection: connection, sftp: sftp, file: file, target: target, staging: staging, replacing: replacing, retainPartial: retainedStaging != nil, offset: offset)
        } catch { try? await sftp.close(); throw error }
    }
    func write(_ data: Data) async throws {
        try Task.checkCancellation()
        var position = 0
        while position < data.count {
            let count = min(SFTPWindow.bytes - pending.count, data.count - position)
            let lower = data.startIndex + position
            pending.append(data[lower..<(lower + count)])
            position += count
            if pending.count == SFTPWindow.bytes { try await prepare() }
        }
    }
    func prepare() async throws {
        try Task.checkCancellation()
        guard !pending.isEmpty else { return }
        let payload = pending
        let start = offset
        try await SFTPDeadline.run(sftp) { [file] in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for position in stride(from: 0, to: payload.count, by: SFTPWindow.chunk) {
                    let block = payload.subdata(in: position..<min(position + SFTPWindow.chunk, payload.count))
                    group.addTask {
                        try Task.checkCancellation()
                        try await file.write(ByteBuffer(bytes: block), at: start + UInt64(position))
                    }
                }
                try await group.waitForAll()
            }
        }
        offset += UInt64(payload.count)
        pending.removeAll(keepingCapacity: true)
    }
    func commit() async throws {
        try await prepare()
        try await SFTPDeadline.run(sftp) { [file] in try await file.close() }
        try Task.checkCancellation()
        let backup = target.deletingLastPathComponent().appendingPathComponent(".opentransmit-\(UUID().uuidString).backup").path
        let targetPath = target.path
        let staging = self.staging
        let replacing = self.replacing
        // SFTP v3 rename cannot atomically replace a file. Preserve the old file in a backup,
        // then rename staged content and roll back if commit fails. Never delete the old file first.
        try await SFTPDeadline.run(sftp) { [sftp] in
            if replacing { try await sftp.rename(at: targetPath, to: backup) }
            do { try await sftp.rename(at: staging, to: targetPath) }
            catch {
                if replacing {
                    do { try await sftp.rename(at: backup, to: targetPath) }
                    catch { throw TransferFailure(message: "提交或回滚失败。原文件备份可能位于 \(backup)，请重新连接后检查；不要删除该备份。") }
                }
                throw error
            }
            if replacing {
                do { try await sftp.remove(at: backup) }
                catch { throw TransferFailure(message: "新文件已提交，但旧文件备份未清理：\(backup)") }
            }
        }
        committed = true
        try? await sftp.close()
    }
    func abort() async {
        try? await sftp.close()
        guard !committed, !retainPartial else { return }
        let staging = self.staging
        // A canceled subchannel is closed; use a fresh one for best-effort cleanup.
        let connection = self.connection
        // Cleanup must outlive the cancellation of the transfer task itself.
        await Task.detached {
            _ = try? await connection.perform { try await $0.remove(at: staging) }
        }.value
    }
}
