import Foundation
import CryptoKit

struct FileCheckpoint: Codable, Sendable {
    let token: UUID
    let size: Int64
    let modified: Date?
    let digest: String
    var stagingName: String { ".opentransmit-\(token.uuidString).partial" }
}

/// Contains only hashes, sizes and random staging identifiers, never session URLs or credentials.
actor TransferCheckpointJournal {
    private let file: URL
    private var records: [String: FileCheckpoint]
    init(id: UUID, directory: URL? = nil) throws {
        let directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OpenTransmit/TransferCheckpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = directory.appendingPathComponent(id.uuidString + ".json")
        records = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode([String: FileCheckpoint].self, from: Data(contentsOf: file)) : [:]
    }
    func record(for key: String) -> FileCheckpoint? { records[key] }
    func save(_ record: FileCheckpoint?, for key: String) throws {
        var next = records
        next[key] = record
        if next.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } else {
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        records = next
    }
    static func key(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}

extension TransferEndpoint {
    func contentDigest(_ url: URL, limit: Int64? = nil) async throws -> String {
        let input = try await reader(url)
        do {
            var hash = SHA256()
            var remaining = limit
            while remaining == nil || remaining! > 0 {
                try Task.checkCancellation()
                let data = try await input.read()
                if data.isEmpty {
                    if let remaining, remaining > 0 { throw TransferFailure(message: "校验期间文件长度发生变化。") }
                    break
                }
                let used = remaining.map { min(Int64(data.count), $0) } ?? Int64(data.count)
                hash.update(data: data.prefix(Int(used)))
                if remaining != nil { remaining! -= used }
            }
            await input.close()
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { await input.close(); throw error }
    }
}
