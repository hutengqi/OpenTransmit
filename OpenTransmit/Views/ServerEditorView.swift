import SwiftUI

struct ServerEditorView: View {
    let library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    private let isEditing: Bool
    @State private var server: ServerProfile
    init(library: LibraryStore, server: ServerProfile? = nil) {
        self.library = library
        isEditing = server != nil
        _server = State(initialValue: server ?? ServerProfile())
    }
    private var valid: Bool {
        !server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !server.host.contains("/") && (server.protocolKind == .smb || !server.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && (1...65535).contains(server.port)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isEditing ? "编辑服务器" : "保存服务器").font(.title2.bold())
            Text("SFTP、FTP 和显式 FTPS 已支持连接。FTPS 默认使用 21 端口，要求有效 TLS 证书；SMB 通过 macOS 认证并选择共享。").foregroundStyle(.secondary)
            Form {
                TextField("名称", text: $server.name)
                Picker("协议", selection: $server.protocolKind) { ForEach(ServerProtocol.allCases) { Text($0.rawValue).tag($0) } }
                    .onChange(of: server.protocolKind) { _, value in server.port = value.defaultPort }
                TextField("主机", text: $server.host, prompt: Text("example.com"))
                TextField("端口", value: $server.port, format: .number.grouping(.never))
                TextField("用户名", text: $server.username)
                TextField(server.protocolKind == .smb ? "共享路径（/ 列出共享）" : "默认路径", text: $server.directory)
            }
            Text("密码或私钥将在连接时输入，不写入服务器资料。FTP 不加密。").font(.caption).foregroundStyle(.secondary)
            if isEditing {
                Text("修改用于下次连接；当前连接和传输保持不变。工作区仍引用此服务器，已保存的工作区目录不会随默认路径改变。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存资料") {
                    server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    server.host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isEditing {
                        guard let index = library.servers.firstIndex(where: { $0.id == server.id }) else { return }
                        library.servers[index] = server
                    } else { library.servers.append(server) }
                    library.save(); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(24).frame(width: 460)
    }
}
