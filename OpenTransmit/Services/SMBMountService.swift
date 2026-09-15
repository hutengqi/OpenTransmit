import Foundation
import NetFS

/// NetFS owns authentication and share enumeration; panes only receive local mount URLs.
@MainActor final class SMBMountService {
    private var request: AsyncRequestID?
    private var completion: CheckedContinuation<[URL], Error>?
    private var token: UUID?
    private var timeout: Task<Void, Never>?

    static func serverURL(_ server: ServerProfile) throws -> URL {
        let host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard server.protocolKind == .smb, !host.isEmpty,
              !host.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !host.contains(where: { "/\\@?#".contains($0) || $0.isWhitespace }),
              (1...65535).contains(server.port) else {
            throw TransferFailure(message: "SMB 主机或端口无效，请只填写主机名或 IP 地址。")
        }
        let path = server.directory.isEmpty ? "/" : server.directory
        guard path.hasPrefix("/"), !path.contains("//"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else {
            throw TransferFailure(message: "SMB 路径应为 / 或 /共享名，不允许相对路径段。")
        }
        guard path.split(separator: "/").count <= 1 else {
            throw TransferFailure(message: "请填写 /共享名，连接后再在文件栏中进入子目录。")
        }
        var parts = URLComponents()
        parts.scheme = "smb"; parts.host = host; parts.port = server.port
        parts.path = path == "/" ? "" : path
        guard let url = parts.url else { throw TransferFailure(message: "无法生成 SMB 地址。") }
        return url
    }

    func connect(_ server: ServerProfile) async throws -> [URL] {
        let url = try Self.serverURL(server)
        try Task.checkCancellation()
        guard completion == nil else { throw TransferFailure(message: "SMB 连接正在进行。") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                let id = UUID(); token = id
                let options = NSMutableDictionary(dictionary: ["UIOption": "AllowUI"])
                let user: CFString? = server.username.isEmpty ? nil : server.username as CFString
                let status = NetFSMountURLAsync(url as CFURL, nil, user, nil,
                    options, nil, &request, DispatchQueue.main) { [weak self] status, _, paths in
                    let mounts = (paths as? [String]) ?? []
                    Task { @MainActor [weak self] in
                        guard let self, self.token == id else { return }
                        if status == 0, !mounts.isEmpty {
                            self.finish(.success(mounts.map { URL(fileURLWithPath: $0, isDirectory: true) }))
                        } else if status == -128 { self.finish(.failure(CancellationError())) }
                        else { self.finish(.failure(TransferFailure(message: "SMB 连接未完成（系统错误 \(status)）。请检查地址、账号权限和共享名称。"))) }
                    }
                }
                if status != 0 {
                    finish(.failure(TransferFailure(message: "无法发起 SMB 连接（系统错误 \(status)）。")))
                    return
                }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(180))
                    guard !Task.isCancelled, let self, self.token == id else { return }
                    self.cancel(message: "SMB 连接超时，请重试。")
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel(message: String? = nil) {
        if let request { NetFSMountURLCancel(request) }
        if let message { finish(.failure(TransferFailure(message: message))) }
        else { finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<[URL], Error>) {
        let continuation = completion
        completion = nil; request = nil; token = nil
        timeout?.cancel(); timeout = nil
        continuation?.resume(with: result)
    }
}
