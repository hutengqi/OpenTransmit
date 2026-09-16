import Foundation

enum ServerProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case sftp = "SFTP", ftp = "FTP", ftps = "FTPS", smb = "SMB"
    var id: String { rawValue }
    var defaultPort: Int { switch self { case .sftp: 22; case .ftp, .ftps: 21; case .smb: 445 } }
}   

struct ServerProfile: Identifiable, Codable, Sendable {
    var id = UUID()
    var name = ""
    var protocolKind: ServerProtocol = .sftp
    var host = ""
    var port = 22
    var username = ""
    var directory = "/"
}

enum TransferDirection: String, Codable, CaseIterable, Identifiable {
    case unspecified, leftToRight, rightToLeft
    var id: String { rawValue }
    var title: String { switch self { case .unspecified: "不设默认方向"; case .leftToRight: "左 → 右"; case .rightToLeft: "右 → 左" } }
}

struct Workspace: Identifiable, Codable {
    var id = UUID()
    var name: String
    var leftBookmark: Data? = nil
    var rightBookmark: Data? = nil
    var leftRemote: WorkspaceRemote? = nil
    var rightRemote: WorkspaceRemote? = nil
    var direction: TransferDirection? = nil
}

struct WorkspaceRemote: Codable {
    let serverID: UUID
    let path: String
}

struct FileEntry: Identifiable, Sendable, Equatable {
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    var isSymbolicLink = false
    var permissions: UInt32? = nil
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum ConflictChoice: Sendable { case replace, keepBoth, skip, cancel }
struct FileConflict: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    let destination: URL
    var sourceEntry: FileEntry?
    var destinationEntry: FileEntry?
}
struct TransferJob: Identifiable {
    let id = UUID()
    let source: URL
    let destination: URL
    var duplicateInPlace = false
    var moving = false
    var recoveryID: UUID?
    var status = "等待中"
    var bytes: Int64 = 0
    var totalBytes: Int64?
    var startedAt: Date?
    var endedAt: Date?
    var cancelled = false
    var warnings: [String] = []
    var fraction: Double? {
        guard let totalBytes else { return nil }
        if finished && !failed && !cancelled { return 1 }
        guard totalBytes > 0 else { return 0 }
        return min(0.99, Double(bytes) / Double(totalBytes))
    }
    func bytesPerSecond(at now: Date) -> Double {
        guard let startedAt else { return 0 }
        return Double(bytes) / max(0.001, (endedAt ?? now).timeIntervalSince(startedAt))
    }
    var finished = false
    var failed = false
}

extension FileEntry {
    /// Finder metadata and AppleDouble sidecars; ordinary dotfiles remain transferable.
    var isSystemMetadata: Bool {
        !isDirectory && (name == ".DS_Store" || name == ".localized" || name.hasPrefix("._"))
    }
}
