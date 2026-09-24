import SwiftUI

struct ContentView: View {
    @Bindable var library: LibraryStore
    @State private var tabs = [WorkspaceTab()]
    @State private var selectedTabID: UUID?
    private var activeTab: WorkspaceTab { tabs.first { $0.id == selectedTabID } ?? tabs[0] }
    private var left: PaneStore { activeTab.left }
    private var right: PaneStore { activeTab.right }
    @Bindable var transfers: TransferStore
    @ObservedObject var updates: AppUpdateStore
    @State private var showServer = false
    @State private var comparison: DirectoryComparisonRequest?
    @State private var editingServer: ServerProfile?
    @State private var workspaceDirection: TransferDirection = .unspecified
    @State private var showWorkspace = false
    @State private var workspaceName = ""
    @State private var savingTabID: UUID?
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
                        .help("右键选择连接到左栏或右栏")
                        .contextMenu {
                            Button("连接到左栏") { connectLeft = true; connectingServer = server }.disabled(transfers.running || transfers.deleting)
                            Button("连接到右栏") { connectLeft = false; connectingServer = server }.disabled(transfers.running || transfers.deleting)
                            Divider()
                            Button("编辑服务器…", systemImage: "pencil") { editingServer = server }
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
                WorkspaceTabBar(tabs: tabs, selectedID: activeTab.id, canClose: !transfers.running && !transfers.deleting, select: { selectedTabID = $0 }, add: addTab, close: closeTab, save: beginSave)
                Divider()
                if activeTab.direction != .unspecified {
                    HStack {
                        Text("默认方向：\(activeTab.direction.title)").foregroundStyle(.secondary)
                        Spacer()
                        Button("传输所选文件（\(activeTab.direction.title)）", systemImage: activeTab.direction == .leftToRight ? "arrow.right" : "arrow.left") {
                            transferInDefaultDirection()
                        }
                        .disabled(defaultSource.selectedURLs.isEmpty || defaultTarget.directory == nil || defaultSource.loading || defaultTarget.loading || transfers.deleting)
                    }.font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
                    Divider()
                }
                HSplitView {
                    FilePaneView(title: "左栏", pane: left, other: right, transfers: transfers, servers: library.servers, addServer: { showServer = true })
                    FilePaneView(title: "右栏", pane: right, other: left, transfers: transfers, servers: library.servers, addServer: { showServer = true })
                }
                .id(activeTab.id)
                Divider()
                if updates.waitingForFileOperations {
                    Label("更新已就绪，文件操作结束后将自动重启。", systemImage: "arrow.down.circle")
                        .font(.callout).padding(8)
                }
                if let message = updates.startupError {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(8)
                }
                TransferQueueView(store: transfers)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("新建标签页", systemImage: "plus.rectangle.on.rectangle", action: addTab)
                    .keyboardShortcut("t", modifiers: .command)
                Button("添加服务器", systemImage: "server.rack") { showServer = true }
                Button("保存工作区", systemImage: "bookmark") { beginSave(activeTab.id) }
                    .disabled(left.directory == nil || right.directory == nil)
                    .help("保存左右栏的本地目录或服务器位置")
                Button("比较目录…", systemImage: "arrow.left.arrow.right") {
                    if let a = left.directory, let b = right.directory {
                        comparison = DirectoryComparisonRequest(left: a, right: b)
                    }
                }.disabled(left.directory == nil || right.directory == nil || left.loading || right.loading || transfers.running || transfers.deleting)
                Button(updates.availableVersion.map { "更新至 \($0)…" } ?? "检查更新…", systemImage: "arrow.down.circle") {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
                .help("检查 GitHub 上的新版本，确认后下载并安装")
                Button("刷新两栏", systemImage: "arrow.clockwise") { left.refresh(); right.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .sheet(item: $comparison) { DirectoryComparisonView(request: $0, transfers: transfers) }
        .sheet(item: $connectingServer) { ServerConnectionView(server: $0, pane: connectLeft ? left : right) }
        .sheet(item: $editingServer) { ServerEditorView(library: library, server: $0) }
        .sheet(isPresented: $showServer) { ServerEditorView(library: library) }
        .sheet(isPresented: $showWorkspace) {
            VStack(alignment: .leading, spacing: 18) {
                Text("保存工作区").font(.title2.bold())
                Text("保存左右目录。恢复时使用已保存密码连接远程服务器，不会自动传输文件。").foregroundStyle(.secondary)
                TextField("工作区名称", text: $workspaceName)
                Picker("默认传输方向", selection: $workspaceDirection) {
                    ForEach(TransferDirection.allCases) { Text($0.title).tag($0) }
                }
                Text("方向仅用于快捷传输按钮；拖拽和两栏复制仍按实际操作执行。").font(.caption).foregroundStyle(.secondary)
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
        .disabled(transfers.installingApplicationUpdate)
        .onAppear { transfers.onChange = { for tab in tabs { tab.left.refresh(); tab.right.refresh() } } }
    }
    private var defaultSource: PaneStore { activeTab.direction == .rightToLeft ? right : left }
    private var defaultTarget: PaneStore { activeTab.direction == .rightToLeft ? left : right }
    private func transferInDefaultDirection() {
        guard activeTab.direction != .unspecified, !transfers.deleting,
              !defaultSource.loading, !defaultTarget.loading,
              let destination = defaultTarget.directory else { return }
        transfers.enqueue(defaultSource.selectedURLs, to: destination)
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
    private func beginSave(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        savingTabID = id
        workspaceName = tab.title
        workspaceDirection = tab.direction
        showWorkspace = true
    }
    private func saveWorkspace() {
        do {
            guard let tab = tabs.first(where: { $0.id == savingTabID }) else { return }
            var workspace = Workspace(name: workspaceName.trimmingCharacters(in: .whitespacesAndNewlines))
            func remote(_ pane: PaneStore) throws -> WorkspaceRemote {
                guard let server = pane.serverProfile, let url = pane.directory,
                      library.servers.contains(where: { $0.id == server.id }) else {
                    throw TransferFailure(message: "服务器配置已不存在，请先保存服务器并重新连接。")
                }
                return WorkspaceRemote(serverID: server.id, path: url.path)
            }
            if tab.left.isRemote { workspace.leftRemote = try remote(tab.left) }
            else { workspace.leftBookmark = try tab.left.bookmark() }
            if tab.right.isRemote { workspace.rightRemote = try remote(tab.right) }
            else { workspace.rightBookmark = try tab.right.bookmark() }
            workspace.direction = workspaceDirection
            tab.direction = workspaceDirection
            library.workspaces.append(workspace)
            library.save()
            workspaceName = ""
            showWorkspace = false
        } catch { self.error = error.localizedDescription; showWorkspace = false }
    }
    private func restore(_ workspace: Workspace) {
        do {
            let tab = WorkspaceTab(name: workspace.name)
            tab.direction = workspace.direction ?? .unspecified
            func restorePane(_ pane: PaneStore, bookmark: Data?, remote: WorkspaceRemote?) throws {
                if let remote {
                    guard var server = library.servers.first(where: { $0.id == remote.serverID }) else {
                        throw TransferFailure(message: "工作区引用的服务器配置已被删除，请重新保存工作区。")
                    }
                    server.directory = remote.path
                    pane.pendingConnection = server
                } else if let bookmark { try pane.restore(bookmark) }
                else { throw TransferFailure(message: "工作区缺少目录资料。") }
            }
            try restorePane(tab.left, bookmark: workspace.leftBookmark, remote: workspace.leftRemote)
            try restorePane(tab.right, bookmark: workspace.rightBookmark, remote: workspace.rightRemote)
            tabs.append(tab); selectedTabID = tab.id
            tab.left.restoreSavedConnection(); tab.right.restoreSavedConnection()
        }
        catch { self.error = "无法恢复工作区：\(error.localizedDescription)" }
    }
}
