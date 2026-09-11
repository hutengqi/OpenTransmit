import SwiftUI

struct ServerEditorView: View {
    let library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var server = ServerProfile()
    private var valid: Bool {
        !server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !server.host.contains("/") && !server.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...65535).contains(server.port)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("保存服务器").font(.title2.bold())
            Text("SFTP 已支持连接。保存后，从单栏连接菜单或服务器右键菜单选择目标栏。其他协议当前仅保存资料。").foregroundStyle(.secondary)
            Form {
                TextField("名称", text: $server.name)
                Picker("协议", selection: $server.protocolKind) { ForEach(ServerProtocol.allCases) { Text($0.rawValue).tag($0) } }
                    .onChange(of: server.protocolKind) { _, value in server.port = value.defaultPort }
                TextField("主机", text: $server.host, prompt: Text("example.com"))
                TextField("端口", value: $server.port, format: .number.grouping(.never))
                TextField("用户名", text: $server.username)
                TextField("默认路径", text: $server.directory)
            }
            Text("密码或私钥将在连接时输入，不写入服务器资料。FTP 不加密。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存资料") {
                    server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    server.host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
                    library.servers.append(server); library.save(); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(24).frame(width: 460)
    }
}
