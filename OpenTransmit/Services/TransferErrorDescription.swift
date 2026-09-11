import Foundation
import Citadel
import NIOPosix
import NIOCore

extension Error {
    var transferDescription: String {
        // Citadel's handshake-disconnected type is private and its reflected name
        // contains unstable compiler addresses; do not expose it as a password error.
        let typeName = String(reflecting: type(of: self))
        if typeName.contains("ClientHandshakeHandler"), typeName.contains("Disconnected") {
            return "SSH 握手尚未完成，连接已断开，暂时无法确认是否为密码问题。请用终端或其他 SFTP 客户端验证同一地址、端口和账号；若也失败，请检查服务器 SSH 日志及连接限制。"
        }
        if let channelError = self as? ChannelError, case .connectTimeout = channelError {
            return "SSH 连接或认证超时。请检查网络和服务器负载；当前 SSH 握手等待上限约为 10 秒。"
        }
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
