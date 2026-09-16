import Foundation

struct SavedTransferLocation: Codable {
    var bookmark: Data?
    var server: ServerProfile?
    var path: String

    static func capture(_ url: URL) async throws -> Self {
        if url.isFileURL {
            return Self(bookmark: try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), path: url.path)
        }
        return Self(server: try await SFTPRegistry.shared.profile(for: url), path: url.path)
    }
    func resolve() async throws -> URL {
        if let bookmark {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw TransferFailure(message: "本地目录授权已失效，请重新选择目录并添加任务。") }
            _ = url.startAccessingSecurityScopedResource()
            return url
        }
        guard let server, let url = await SFTPRegistry.shared.activeLocation(for: server, path: path) else {
            throw TransferFailure(message: "请先在文件栏连接任务原来的服务器，再重新执行。服务器地址或账号改变后需重新添加任务。")
        }
        return url
    }
}
struct SavedTransferTask: Identifiable, Codable {
    let id: UUID
    let source: SavedTransferLocation
    let destination: SavedTransferLocation
    let duplicateInPlace: Bool
    var moving: Bool? = nil
}

extension ServerProfile {
    func matchesEndpoint(_ other: ServerProfile) -> Bool {
        id == other.id && protocolKind == other.protocolKind && host.lowercased() == other.host.lowercased() && port == other.port && username == other.username
    }
}
