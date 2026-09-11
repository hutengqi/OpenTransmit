import Foundation
import Security
import CryptoKit

/// Secrets never enter the library JSON. Items stay on this Mac and are scoped
/// to the saved profile, endpoint and (for passphrases) the selected key contents.
struct CredentialVault {
    private let service: String
    private let endpoint: String

    init(server: ServerProfile) {
        service = "OpenTransmit.credentials.v1.\(server.id.uuidString)"
        endpoint = "\(server.protocolKind.rawValue)|\(server.host.lowercased())|\(server.port)|\(server.username)"
    }

    func account(privateKey: String?) -> String {
        guard let privateKey else { return endpoint + "|password" }
        let hash = SHA256.hash(data: Data(privateKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return endpoint + "|passphrase|" + hash
    }

    private func query(_ account: String? = nil) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrSynchronizable as String: false]
        if let account { result[kSecAttrAccount as String] = account }
        return result
    }

    func read(account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw VaultError(status: errSecDecode)
        }
        return value
    }

    func save(_ secret: String, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item.merge(attributes) { _, new in new }
            item[kSecAttrLabel as String] = "OpenTransmit 服务器凭据"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }

    func removeAll() throws {
        var request = query()
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        let status = SecItemDelete(request as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw VaultError(status: status) }
    }

    struct VaultError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "钥匙串操作失败：\(SecCopyErrorMessageString(status, nil) as String? ?? String(status))。请检查钥匙串是否已解锁及是否允许访问。"
        }
    }
}
