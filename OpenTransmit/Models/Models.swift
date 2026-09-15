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
    var status = "等待中"
    var bytes: Int64 = 0
    var finished = false
    var failed = false
}
