import Foundation
import Citadel
import NIOPosix

extension Error {
    var transferDescription: String {
        if self is NIOConnectionError {
            return "无法连接服务器，请检查地址、端口、防火墙和 SFTP 服务是否启动。"
        }
        if let status = self as? SFTPMessage.Status {
            switch status.errorCode {
            case .permissionDenied: return "服务器拒绝访问：\(status.message)"
            case .noSuchFile: return "远程文件或目录不存在：\(status.message)"
            default: return "SFTP 操作失败：\(status.message)"
            }
        }
        if let error = self as? SSHClientError {
            switch error {
            case .allAuthenticationOptionsFailed: return "SSH 认证失败，请检查用户名、密码或私钥。"
            case .unsupportedPasswordAuthentication: return "服务器不支持密码认证，请使用私钥。"
            case .unsupportedPrivateKeyAuthentication: return "服务器不支持此私钥认证方式。"
            default: return "无法建立 SSH 会话，请检查服务器认证配置。"
            }
        }
        if let error = self as? SFTPError, case .connectionClosed = error {
            return "SFTP 通道已关闭，可能是请求超时或连接中断。请检查网络后重试。"
        }
        return localizedDescription
    }
}
