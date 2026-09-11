import Foundation
@preconcurrency import Citadel
import NIOCore
import NIOPosix
import Crypto

struct SSHCredentials: Sendable {
    enum Method: String, CaseIterable { case password = "密码", ed25519 = "Ed25519 私钥", rsa = "RSA 私钥" }
    var method: Method = .password
    var password = ""
    var privateKey: String?
    var passphrase = ""
    func authentication(username: String) throws -> @Sendable () -> SSHAuthenticationMethod {
        let phrase = passphrase.isEmpty ? nil : Data(passphrase.utf8)
        switch method {
        case .password:
            let password = self.password
            return { .passwordBased(username: username, password: password) }
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: privateKey ?? "", decryptionKey: phrase)
            return { .ed25519(username: username, privateKey: key) }
        case .rsa:
            let key = try Insecure.RSA.PrivateKey(sshRsa: privateKey ?? "", decryptionKey: phrase)
            return { .rsa(username: username, privateKey: key) }
        }
    }
}

actor SFTPConnection {
    let server: ServerProfile
    private let client: SSHClient
    private let group: MultiThreadedEventLoopGroup
    private init(server: ServerProfile, client: SSHClient, group: MultiThreadedEventLoopGroup) {
        self.server = server; self.client = client; self.group = group
    }
    static func connect(_ server: ServerProfile, credentials: SSHCredentials, trustedKey: String?) async throws -> SFTPConnection {
        let validator = PinnedHostValidator(host: "\(server.host):\(server.port)", expectedKey: trustedKey)
        // Parse keys before entering NIO's synchronous authentication callback.
        let authentication = try credentials.authentication(username: server.username)
        var settings = SSHClientSettings(host: server.host, port: server.port, authenticationMethod: authentication, hostKeyValidator: .custom(validator))
        // Own the event loop so failed authentication/canceled handshakes cannot leak channels.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        settings.group = group
        let connectionSettings = settings
        do {
            let client = try await withTaskCancellationHandler {
                try await SSHClient.connect(to: connectionSettings)
            } onCancel: {
                Task { try? await group.shutdownGracefully() }
            }
            if Task.isCancelled { try? await client.close(); throw CancellationError() }
            return SFTPConnection(server: server, client: client, group: group)
        } catch {
            try? await group.shutdownGracefully()
            if Task.isCancelled { throw CancellationError() }
            if let challenge = validator.challenge { throw challenge }
            throw error
        }
    }
    func open() async throws -> SFTPClient { try await client.openSFTP() }
    func close() async { try? await client.close(); try? await group.shutdownGracefully() }
    func perform<T: Sendable>(_ operation: @Sendable (SFTPClient) async throws -> T) async throws -> T {
        let sftp = try await open()
        do {
            let value = try await SFTPDeadline.run(sftp) { try await operation(sftp) }
            try? await sftp.close()
            return value
        } catch { try? await sftp.close(); throw error }
    }
}

enum SFTPDeadline {
    /// Closing the subchannel fails outstanding NIO promises on cancellation or timeout.
    static func run<T: Sendable>(_ sftp: SFTPClient, operation: @Sendable () async throws -> T) async throws -> T {
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            try? await sftp.close()
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation()
        } onCancel: { Task { try? await sftp.close() } }
    }
}

actor SFTPRegistry: TransferEndpoint {
    static let shared = SFTPRegistry()
    private var sessions: [String: SFTPConnection] = [:]
    private let local = LocalTransferEndpoint()

    func connect(_ server: ServerProfile, credentials: SSHCredentials, trustedKey: String?) async throws -> URL {
        guard server.protocolKind == .sftp else { throw TransferFailure(message: "当前连接仅支持 SFTP。") }
        let connection = try await SFTPConnection.connect(server, credentials: credentials, trustedKey: trustedKey)
        do {
            let root = try await connection.perform { try await $0.getRealPath(atPath: server.directory.isEmpty ? "." : server.directory) }
            var components = URLComponents()
            components.scheme = "opentransmit-sftp"
            components.host = UUID().uuidString.lowercased()
            components.user = server.name
            components.path = root
            guard let url = components.url else { throw TransferFailure(message: "无效的远程路径。") }
            sessions[url.host!] = connection
            return url
        } catch { await connection.close(); throw error }
    }
    func disconnect(_ url: URL) async {
        if let host = url.host, let connection = sessions.removeValue(forKey: host) { await connection.close() }
    }
    /// Frozen UI selection only; directories are removed bottom-up and links are unlinked.
    func delete(_ urls: [URL]) async -> TrashResult {
        var result = TrashResult()
        var seen: Set<URL> = []
        let selected = urls.filter { seen.insert($0).inserted }
        // A selected ancestor already covers its descendants.
        let roots = selected.filter { candidate in
            !selected.contains { parent in
                parent != candidate && parent.host == candidate.host && parent.scheme == candidate.scheme &&
                candidate.path.hasPrefix(parent.path.hasSuffix("/") ? parent.path : parent.path + "/")
            }
        }
        for url in roots {
            do {
                try await deleteTree(url, depth: 0)
                result.completed.append(url)
            } catch {
                result.failures.append("\(url.locationLabel)：\(error.transferDescription)（目录可能已部分删除）")
            }
        }
        return result
    }
    private func deleteTree(_ url: URL, depth: Int) async throws {
        guard url.isRemoteFile, !url.path.isEmpty, url.path != "/",
              !url.pathComponents.contains(".."), !url.pathComponents.contains("."), depth <= 128 else {
            throw TransferFailure(message: "不能删除服务器根目录、无效路径或过深的目录。")
        }
        try Task.checkCancellation()
        guard let item = try await entry(url) else { throw TransferFailure(message: "远程项目已不存在。") }
        let session = try connection(url)
        if item.isDirectory && !item.isSymbolicLink {
            for child in try await children(url) {
                try await deleteTree(child.url, depth: depth + 1)
            }
            try await session.perform { try await $0.rmdir(at: url.path) }
        } else {
            try await session.perform { try await $0.remove(at: url.path) }
        }
    }
    private func connection(_ url: URL) throws -> SFTPConnection {
        guard url.isRemoteFile, let host = url.host, let connection = sessions[host] else { throw TransferFailure(message: "服务器连接已关闭，请重新连接。") }
        return connection
    }
    func children(_ url: URL) async throws -> [FileEntry] {
        if url.isFileURL { return try await local.children(url) }
        let connection = try connection(url)
        return try await connection.perform { sftp in
            let names = try await sftp.listDirectory(atPath: url.path)
            return try names.flatMap(\.components).filter { $0.filename != "." && $0.filename != ".." }.map { child in
                guard !child.filename.isEmpty, !child.filename.contains("/"), !child.filename.contains("\0") else { throw TransferFailure(message: "服务器返回无效文件名。") }
                let mode = (child.attributes.permissions ?? 0) & 0o170000
                return FileEntry(url: url.appendingPathComponent(child.filename), isDirectory: mode == 0o040000,
                                 size: Int64(clamping: child.attributes.size ?? 0), modified: child.attributes.accessModificationTime?.modificationTime,
                                 isSymbolicLink: mode != 0o100000 && mode != 0o040000)
            }
        }
    }
    func entry(_ url: URL) async throws -> FileEntry? {
        if url.isFileURL { return try await local.entry(url) }
        // READDIR attributes describe the link itself, unlike STAT, which follows links.
        if url.path == "/" { return FileEntry(url: url, isDirectory: true, size: 0, modified: nil) }
        do { return try await children(url.deletingLastPathComponent()).first { $0.name == url.lastPathComponent } }
        catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile { return nil }
    }
    func canonicalIdentity(_ url: URL) async throws -> String {
        if url.isFileURL { return try await local.canonicalIdentity(url) }
        let connection = try connection(url)
        let server = connection.server
        let parent = try await connection.perform { try await $0.getRealPath(atPath: url.deletingLastPathComponent().path) }
        return "sftp:\(server.username)@\(server.host.lowercased()):\(server.port)" + (parent == "/" ? "" : parent) + "/" + url.lastPathComponent
    }
    func createDirectory(_ url: URL) async throws {
        if url.isFileURL { return try await local.createDirectory(url) }
        try await connection(url).perform { try await $0.createDirectory(atPath: url.path) }
    }
    func reader(_ url: URL) async throws -> any TransferReader {
        if url.isFileURL { return try await local.reader(url) }
        let sftp = try await connection(url).open()
        do {
            let file = try await SFTPDeadline.run(sftp) { try await sftp.openFile(filePath: url.path, flags: .read) }
            return SFTPStreamReader(sftp: sftp, file: file)
        } catch { try? await sftp.close(); throw error }
    }
    func writer(_ url: URL, replacing: Bool) async throws -> any TransferWriter {
        if url.isFileURL { return try await local.writer(url, replacing: replacing) }
        return try await SFTPStreamWriter.open(connection: connection(url), target: url, replacing: replacing)
    }
}
