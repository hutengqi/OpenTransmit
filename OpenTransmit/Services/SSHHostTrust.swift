import Foundation
import NIOCore
import NIOSSH
import Crypto

struct HostKeyChallenge: LocalizedError, Sendable {
    let host: String
    let key: String
    let changed: Bool
    var fingerprint: String {
        let parts = key.split(separator: " ")
        guard parts.count > 1, let data = Data(base64Encoded: String(parts[1])) else { return "未知" }
        return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    var errorDescription: String? { changed ? "服务器主机指纹已变化，连接已拒绝。请通过服务器控制台核实。" : "首次连接，请核对并信任服务器主机指纹。" }
}

/// NIO calls validation on its event loop; capture the challenge under a lock.
final class PinnedHostValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let expectedKey: String?
    private let lock = NSLock()
    private var captured: HostKeyChallenge?
    init(host: String, expectedKey: String?) { self.host = host; self.expectedKey = expectedKey }
    var challenge: HostKeyChallenge? { lock.lock(); defer { lock.unlock() }; return captured }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        if key == expectedKey { validationCompletePromise.succeed(()) }
        else {
            let challenge = HostKeyChallenge(host: host, key: key, changed: expectedKey != nil)
            lock.lock(); captured = challenge; lock.unlock()
            validationCompletePromise.fail(challenge)
        }
    }
}

@MainActor enum SSHHostTrust {
    static func identity(_ server: ServerProfile) -> String { "\(server.host.lowercased()):\(server.port)" }
    static func key(for server: ServerProfile) -> String? { UserDefaults.standard.dictionary(forKey: "ssh.trustedHosts.v1")?[identity(server)] as? String }
    static func trust(_ key: String, for server: ServerProfile) {
        var keys = UserDefaults.standard.dictionary(forKey: "ssh.trustedHosts.v1") as? [String: String] ?? [:]
        keys[identity(server)] = key
        UserDefaults.standard.set(keys, forKey: "ssh.trustedHosts.v1")
    }
}
