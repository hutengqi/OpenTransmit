import SwiftUI
import AppKit

struct ServerConnectionView: View {
    let server: ServerProfile
    let pane: PaneStore
    @Environment(\.dismiss) private var dismiss
    @State private var credentials = SSHCredentials()
    @State private var keyName = "未选择私钥"
    @State private var didLoadCredentials = false
    @State private var remember = false
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
                if credentials.method == .password { RevealableSecretField(title: "密码", text: $credentials.password) }
                else {
                    HStack { Text(keyName).lineLimit(1); Spacer(); Button("选择私钥…") { chooseKey() } }
                    RevealableSecretField(title: "私钥口令（可选）", text: $credentials.passphrase)
                }
                Toggle("将密码或私钥口令保存在本机钥匙串", isOn: $remember)
                Button("清除此服务器已保存的凭据", role: .destructive) {
                    do {
                        try CredentialVault(server: server).removeAll()
                        credentials.password = ""; credentials.passphrase = ""; remember = false
                        message = "已清除保存的凭据。"
                    } catch { message = error.localizedDescription }
                }
            }.disabled(connecting)
            Text("勾选后仅在连接成功时保存；未勾选不保存新输入。私钥文件本身不保存，每次需重新选择。清除按钮可删除已有凭据。").font(.caption).foregroundStyle(.secondary)
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
        .onAppear {
            guard !didLoadCredentials else { return }
            didLoadCredentials = true
            loadSavedSecret()
        }
        .onChange(of: credentials.method) { _, _ in loadSavedSecret() }
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
            loadSavedSecret()
        } catch { message = error.transferDescription }
    }
    private func loadSavedSecret() {
        remember = false
        credentials.password = ""; credentials.passphrase = ""
        guard credentials.method == .password || credentials.privateKey != nil else { return }
        let vault = CredentialVault(server: server)
        do {
            let key = credentials.method == .password ? nil : credentials.privateKey
            if let secret = try vault.read(account: vault.account(privateKey: key)) {
                if credentials.method == .password { credentials.password = secret }
                else { credentials.passphrase = secret }
                remember = true
            }
        } catch { message = error.localizedDescription }
    }
    private func connect() {
        connecting = true; message = nil
        let credentials = self.credentials
        let trusted = SSHHostTrust.key(for: server)
        task = Task {
            do {
                let url = try await SFTPRegistry.shared.connect(server, credentials: credentials, trustedKey: trusted)
                guard !Task.isCancelled else { await SFTPRegistry.shared.disconnect(url); return }
                if remember {
                    let vault = CredentialVault(server: server)
                    do {
                        let key = credentials.method == .password ? nil : credentials.privateKey
                        try vault.save(credentials.method == .password ? credentials.password : credentials.passphrase,
                                       account: vault.account(privateKey: key))
                    } catch {
                        await SFTPRegistry.shared.disconnect(url)
                        throw error
                    }
                }
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
