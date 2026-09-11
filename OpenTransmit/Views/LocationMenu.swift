import SwiftUI

/// The same destination chooser is used in the toolbar, empty pane and sidebar.
struct LocationMenu: View {
    let pane: PaneStore
    let servers: [ServerProfile]
    let transfers: TransferStore
    let title: String
    let addServer: () -> Void
    @State private var connectingServer: ServerProfile?

    var body: some View {
        Menu {
            Button("本地目录或已挂载共享…", systemImage: "folder") { pane.chooseDirectory() }
            Divider()
            Section("已保存的服务器") {
                if servers.isEmpty { Text("尚未添加服务器") }
                ForEach(servers) { server in
                    Button("\(server.name)（\(server.protocolKind.rawValue)）") { connectingServer = server }
                        .disabled(server.protocolKind != .sftp || transfers.running || transfers.deleting)
                }
                Button("添加服务器…", systemImage: "plus", action: addServer)
            }
            if pane.isRemote {
                Divider()
                Button("断开连接") { pane.disconnect() }.disabled(transfers.running || transfers.deleting)
            }
        } label: {
            Label(title, systemImage: "folder.badge.plus")
        }
        .help("选择本地目录、已挂载共享或服务器")
        .sheet(item: $connectingServer) { ServerConnectionView(server: $0, pane: pane) }
    }
}
