import Foundation
@preconcurrency import Citadel
import NIOCore

actor SFTPStreamReader: TransferReader {
    let sftp: SFTPClient
    let file: SFTPFile
    private var offset: UInt64 = 0
    init(sftp: SFTPClient, file: SFTPFile) { self.sftp = sftp; self.file = file }
    func read() async throws -> Data {
        let offset = self.offset
        let buffer = try await SFTPDeadline.run(sftp) { [file] in try await file.read(from: offset, length: 64 * 1024) }
        let data = Data(buffer.readableBytesView)
        self.offset += UInt64(data.count)
        return data
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
    private init(connection: SFTPConnection, sftp: SFTPClient, file: SFTPFile, target: URL, staging: String, replacing: Bool) {
        self.connection = connection; self.sftp = sftp; self.file = file
        self.target = target; self.staging = staging; self.replacing = replacing
    }
    static func open(connection: SFTPConnection, target: URL, replacing: Bool) async throws -> SFTPStreamWriter {
        let sftp = try await connection.open()
        let staging = target.deletingLastPathComponent().appendingPathComponent(".opentransmit-\(UUID().uuidString).partial").path
        do {
            let file = try await SFTPDeadline.run(sftp) { try await sftp.openFile(filePath: staging, flags: [.write, .create, .forceCreate]) }
            return SFTPStreamWriter(connection: connection, sftp: sftp, file: file, target: target, staging: staging, replacing: replacing)
        } catch { try? await sftp.close(); throw error }
    }
    func write(_ data: Data) async throws {
        let offset = self.offset
        try await SFTPDeadline.run(sftp) { [file] in try await file.write(ByteBuffer(bytes: data), at: offset) }
        self.offset += UInt64(data.count)
    }
    func commit() async throws {
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
        guard !committed else { return }
        let staging = self.staging
        // A canceled subchannel is closed; use a fresh one for best-effort cleanup.
        let connection = self.connection
        // Cleanup must outlive the cancellation of the transfer task itself.
        await Task.detached {
            _ = try? await connection.perform { try await $0.remove(at: staging) }
        }.value
    }
}
