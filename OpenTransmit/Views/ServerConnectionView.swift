import SwiftUI
import AppKit

struct ServerConnectionView: View {
    let server: ServerProfile
    let pane: PaneStore
    @Environment(\.dismiss) private var dismiss
    @State private var credentials = SSHCredentials()
    @State private var keyName = "未选择私钥"
    @State private var connecting = false
    @State private var message: String?
    @State private var challenge: HostKeyChallenge?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接 \(server.name)").font(.title2.bold())
            Text("SFTP · \(server.username)@\(server.host):\(String(server.port))").foregroundStyle(.secondary)
            Form {
                Picker("认证方式", selection: $credentials.method) {
                    ForEach(SSHCredentials.Method.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if credentials.method == .password { SecureField("密码", text: $credentials.password) }
                else {
                    HStack { Text(keyName).lineLimit(1); Spacer(); Button("选择私钥…") { chooseKey() } }
                    SecureField("私钥口令（可选）", text: $credentials.passphrase)
                }
            }.disabled(connecting)
            Text("认证信息仅用于本次连接，不保存到服务器资料。私钥支持 OpenSSH 格式。").font(.caption).foregroundStyle(.secondary)
            if let challenge {
                VStack(alignment: .leading, spacing: 8) {
                    Text(challenge.changed ? "主机指纹变化，已拒绝连接" : "首次连接：请核对主机指纹").font(.headline)
                    Text(challenge.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if !challenge.changed {
                        Text("请通过云服务器控制台核对以上 SHA256 指纹，然后信任并重新连接。").font(.caption)
                        Button("信任此主机并连接") { SSHHostTrust.trust(challenge.key, for: server); self.challenge = nil; connect() }
                            .disabled(connecting)
                    }
                }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if let message { Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                if connecting { ProgressView().controlSize(.small); Text("正在连接…").foregroundStyle(.secondary) }
                Spacer()
                Button("取消") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("连接") { connect() }.keyboardShortcut(.defaultAction)
                    .disabled(connecting || (credentials.method != .password && credentials.privateKey == nil) || challenge?.changed == true)
            }
        }.padding(24).frame(width: 500)
        .interactiveDismissDisabled(connecting)
        .onDisappear { task?.cancel(); credentials = SSHCredentials() }
    }
    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size < 1024 * 1024 else { throw TransferFailure(message: "私钥文件过大。") }
            credentials.privateKey = try String(contentsOf: url, encoding: .utf8)
            keyName = url.lastPathComponent
        } catch { message = error.transferDescription }
    }
    private func connect() {
        connecting = true; message = nil
        let credentials = self.credentials
        let trusted = SSHHostTrust.key(for: server)
        task = Task {
            do {
                let url = try await SFTPRegistry.shared.connect(server, credentials: credentials, trustedKey: trusted)
                guard !Task.isCancelled else { await SFTPRegistry.shared.disconnect(url); return }
                pane.openRemote(url)
                self.credentials = SSHCredentials()
                dismiss()
            } catch let challenge as HostKeyChallenge { self.challenge = challenge }
            catch is CancellationError {}
            catch { message = error.transferDescription }
            connecting = false
        }
    }
}
