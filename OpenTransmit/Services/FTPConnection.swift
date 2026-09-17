import Foundation

private final class FTPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var canceled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct FTPConnection: Sendable {
    let server: ServerProfile
    let password: String

    static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("//"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.split(separator: "/").contains(".."), !path.split(separator: "/").contains(".") else {
            throw TransferFailure(message: "FTP 路径无效，不能包含控制字符或相对路径段。")
        }
    }
    func request(path: String, mode: Int32, file: URL? = nil, offset: Int64 = 0, length: Int64 = 0, commands: [String] = []) async throws {
        try Self.validatePath(path)
        try Task.checkCancellation()
        var components = URLComponents()
        components.scheme = "ftp"
        components.host = server.host
        components.port = server.port
        // The first slash belongs to the URL; the second requests an absolute FTP path.
        components.path = "/" + path + (mode == 0 && !path.hasSuffix("/") ? "/" : "")
        guard let address = components.url?.absoluteString else { throw TransferFailure(message: "FTP 地址无效。") }
        let cancellation = FTPCancellation()
        try await withTaskCancellationHandler {
            try await Task.detached {
                var reply: Int = 0
                let code = ot_ftp_request(address, server.username, password, server.protocolKind == .ftps ? 1 : 0,
                                          mode, file?.path ?? "", offset, length, commands.first ?? "", commands.dropFirst().first ?? "",
                                          { raw in
                    guard let raw else { return 1 }
                    return Unmanaged<FTPCancellation>.fromOpaque(raw).takeUnretainedValue().canceled ? 1 : 0
                }, Unmanaged.passUnretained(cancellation).toOpaque(), &reply)
                if cancellation.canceled { throw CancellationError() }
                guard code == 0 else { throw FTPFailure(code: code, reply: reply) }
            }.value
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
    }
    func command(_ verb: String, path: String, to: String? = nil) async throws {
        try Self.validatePath(path)
        var commands = ["\(verb) \(path)"]
        if let to { try Self.validatePath(to); commands.append("RNTO \(to)") }
        try await request(path: "/", mode: 3, commands: commands)
    }
    func children(_ url: URL) async throws -> [FileEntry] {
        let scratch = try FTPScratch()
        defer { scratch.remove() }
        try await request(path: url.path, mode: 0, file: scratch.file)
        let values = try scratch.file.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) < 32 * 1024 * 1024 else { throw TransferFailure(message: "FTP 目录列表过大。") }
        guard let text = String(data: try Data(contentsOf: scratch.file), encoding: .utf8) else {
            throw TransferFailure(message: "FTP 目录列表不是 UTF-8 编码。")
        }
        return try FTPListing.parse(text, directory: url)
    }
}

struct FTPFailure: LocalizedError {
    let code: Int32
    let reply: Int
    var errorDescription: String? {
        let reason: String
        switch code {
        case 60, 51, 83, 90: reason = "TLS 证书不受信任、已过期或主机名不匹配；已拒绝连接。"
        case 35, 64: reason = "FTPS TLS 握手失败或服务器不支持加密；不会降级为明文。"
        case 67: reason = "FTP 认证失败，请检查用户名、密码和服务器登录策略。"
        case 7, 6: reason = "无法连接 FTP 服务器，请检查主机、端口和网络。"
        case 28: reason = "FTP 请求超时，请检查服务器及被动数据端口的防火墙设置。"
        case 19, 78: reason = "FTP 文件不存在或无权访问。"
        default: reason = "FTP 操作失败，请检查权限、被动端口及服务器是否支持 MLSD。"
        }
        return "\(reason)（FTP \(reply)，错误 \(code)）"
    }
}

/// Private per-operation directory; transfer contents never enter server configuration.
final class FTPScratch: @unchecked Sendable {
    let directory: URL
    let file: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenTransmit-FTP-\(UUID().uuidString)", isDirectory: true)
        file = directory.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            try? FileManager.default.removeItem(at: directory)
            throw TransferFailure(message: "无法创建 FTP 临时文件。")
        }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    deinit { remove() }
}

enum FTPListing {
    static func parse(_ text: String, directory: URL) throws -> [FileEntry] {
        var result: [FileEntry] = []
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "yyyyMMddHHmmss"
        for raw in text.components(separatedBy: "\n") where !raw.isEmpty {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard let space = line.firstIndex(of: " ") else { throw TransferFailure(message: "服务器返回无效的 MLSD 目录列表。") }
            let name = String(line[line.index(after: space)...])
            var facts: [String: String] = [:]
            for fact in line[..<space].split(separator: ";") {
                let parts = fact.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw TransferFailure(message: "服务器返回无效 MLSD 属性。") }
                facts[String(parts[0]).lowercased()] = String(parts[1])
            }
            let type = facts["type"]?.lowercased() ?? "unknown"
            if type == "cdir" || type == "pdir" { continue }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                  !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw TransferFailure(message: "服务器返回不安全的 FTP 文件名。")
            }
            result.append(FileEntry(url: directory.appendingPathComponent(name), isDirectory: type == "dir",
                                    size: max(0, Int64(facts["size"] ?? "0") ?? 0),
                                    modified: facts["modify"].flatMap { date.date(from: String($0.prefix(14))) },
                                    isSymbolicLink: type != "dir" && type != "file"))
        }
        return result
    }
}
