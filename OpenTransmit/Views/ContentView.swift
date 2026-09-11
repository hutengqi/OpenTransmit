import SwiftUI

struct ContentView: View {
    @Bindable var library: LibraryStore
    @State private var tabs = [WorkspaceTab()]
    @State private var selectedTabID: UUID?
    private var activeTab: WorkspaceTab { tabs.first { $0.id == selectedTabID } ?? tabs[0] }
    private var left: PaneStore { activeTab.left }
    private var right: PaneStore { activeTab.right }
    @State private var transfers = TransferStore()
    @State private var showServer = false
    @State private var showWorkspace = false
    @State private var workspaceName = ""
    @State private var connectingServer: ServerProfile?
    @State private var connectLeft = false
    @State private var error: String?

    var body: some View {
        NavigationSplitView {
            List {
                Section("位置") {
                    Label("本地文件", systemImage: "internaldrive")
                    LocationMenu(pane: left, servers: library.servers, transfers: transfers, title: "选择左栏位置…", addServer: { showServer = true })
                    LocationMenu(pane: right, servers: library.servers, transfers: transfers, title: "选择右栏位置…", addServer: { showServer = true })
                }
                Section("服务器") {
                    ForEach(library.servers) { server in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(server.name, systemImage: "server.rack")
                            Text("\(server.protocolKind.rawValue) · \(server.host)").font(.caption).foregroundStyle(.secondary)
                        }
                        .help(server.protocolKind == .sftp ? "右键选择连接到左栏或右栏" : "该协议连接尚未实现")
                        .contextMenu {
                            Button("连接到左栏") { connectLeft = true; connectingServer = server }.disabled(server.protocolKind != .sftp || transfers.running)
                            Button("连接到右栏") { connectLeft = false; connectingServer = server }.disabled(server.protocolKind != .sftp || transfers.running)
                            Divider()
                            Button("删除服务器配置", role: .destructive) {
                                library.deleteServer(server)
                            }
                        }
                    }
                    Button("添加服务器…", systemImage: "plus") { showServer = true }
                }
                Section("工作区") {
                    ForEach(library.workspaces) { workspace in
                        Button { restore(workspace) } label: { Label(workspace.name, systemImage: "rectangle.split.2x1") }
                            .contextMenu {
                                Button("删除工作区", role: .destructive) {
                                    library.workspaces.removeAll { $0.id == workspace.id }; library.save()
                                }
                            }
                    }
                    if library.workspaces.isEmpty { Text("保存常用的左右目录组合").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            VStack(spacing: 0) {
                WorkspaceTabBar(tabs: tabs, selectedID: activeTab.id, canClose: !transfers.running && !transfers.deleting, select: { selectedTabID = $0 }, add: addTab, close: closeTab)
                Divider()
                HSplitView {
                    FilePaneView(title: "左栏", pane: left, other: right, transfers: transfers, servers: library.servers, addServer: { showServer = true })
                    FilePaneView(title: "右栏", pane: right, other: left, transfers: transfers, servers: library.servers, addServer: { showServer = true })
                }
                .id(activeTab.id)
                Divider()
                TransferQueueView(store: transfers)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("新建标签页", systemImage: "plus.rectangle.on.rectangle", action: addTab)
                    .keyboardShortcut("t", modifiers: .command)
                Button("添加服务器", systemImage: "server.rack") { showServer = true }
                Button("保存工作区", systemImage: "bookmark") { showWorkspace = true }
                    .disabled(left.directory == nil || right.directory == nil || left.isRemote || right.isRemote)
                    .help("当前工作区保存仅支持两端均为本地目录")
                Button("刷新两栏", systemImage: "arrow.clockwise") { left.refresh(); right.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .sheet(item: $connectingServer) { ServerConnectionView(server: $0, pane: connectLeft ? left : right) }
        .sheet(isPresented: $showServer) { ServerEditorView(library: library) }
        .sheet(isPresented: $showWorkspace) {
            VStack(alignment: .leading, spacing: 18) {
                Text("保存工作区").font(.title2.bold())
                Text("保存左右目录。再次打开时恢复位置，不会自动复制。").foregroundStyle(.secondary)
                TextField("工作区名称", text: $workspaceName)
                HStack {
                    Spacer()
                    Button("取消") { showWorkspace = false }.keyboardShortcut(.cancelAction)
                    Button("保存") { saveWorkspace() }.keyboardShortcut(.defaultAction)
                        .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 420)
        }
        .sheet(item: $transfers.conflict) { conflict in
            ConflictView(conflict: conflict, store: transfers).interactiveDismissDisabled()
        }
        .alert("操作未完成", isPresented: Binding(get: { error != nil || library.error != nil }, set: { if !$0 { error = nil; library.error = nil } })) {
            Button("好") { error = nil; library.error = nil }
        } message: { Text(error ?? library.error ?? "") }
        .onAppear { transfers.onChange = { for tab in tabs { tab.left.refresh(); tab.right.refresh() } } }
    }
    private func addTab() {
        let tab = WorkspaceTab()
        tabs.append(tab)
        selectedTabID = tab.id
    }
    private func closeTab(_ id: UUID) {
        guard !transfers.running, !transfers.deleting, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[index]
        closing.left.disconnect(); closing.right.disconnect()
        let wasSelected = activeTab.id == id
        tabs.remove(at: index)
        if tabs.isEmpty { tabs.append(WorkspaceTab()) }
        if wasSelected { selectedTabID = tabs[min(index, tabs.count - 1)].id }
    }
    private func saveWorkspace() {
        do {
            library.workspaces.append(Workspace(name: workspaceName.trimmingCharacters(in: .whitespacesAndNewlines), leftBookmark: try left.bookmark(), rightBookmark: try right.bookmark()))
            library.save()
            workspaceName = ""
            showWorkspace = false
        } catch { self.error = error.localizedDescription; showWorkspace = false }
    }
    private func restore(_ workspace: Workspace) {
        do {
            let tab = WorkspaceTab(name: workspace.name)
            try tab.left.restore(workspace.leftBookmark); try tab.right.restore(workspace.rightBookmark)
            tabs.append(tab); selectedTabID = tab.id
        }
        catch { self.error = "无法恢复目录，请重新选择目录并保存工作区。\n\(error.localizedDescription)" }
    }
}
