import SwiftUI

struct FilePaneView: View {
    let title: String
    @Bindable var pane: PaneStore
    let other: PaneStore
    let transfers: TransferStore
    let servers: [ServerProfile]
    let addServer: () -> Void
    @State private var editing: FileEditRequest?
    @State private var restoringServer: ServerProfile?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: pane.isRemote ? "server.rack" : "internaldrive").font(.headline)
                Spacer()
                LocationMenu(pane: pane, servers: servers, transfers: transfers, title: "选择位置…", addServer: addServer)
                Button("返回", systemImage: "chevron.left") { pane.back() }.disabled(!pane.canGoBack).labelStyle(.iconOnly)
                Button("上级目录", systemImage: "arrow.up") { pane.up() }.disabled(!pane.canGoUp).labelStyle(.iconOnly)
                Button("刷新", systemImage: "arrow.clockwise") { pane.refresh() }.labelStyle(.iconOnly)
                Toggle("显示隐藏文件", systemImage: "eye", isOn: $pane.showHidden).toggleStyle(.button).labelStyle(.iconOnly)
                    .onChange(of: pane.showHidden) { _, _ in pane.refresh() }
            }.padding(12)
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                if pane.directory != nil {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(pane.breadcrumbURLs, id: \.self) { url in
                                    if url != pane.breadcrumbURLs.first {
                                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Button {
                                        if url != pane.directory { pane.navigate(url) }
                                    } label: {
                                        Text(url.path == "/" ? (url.isRemoteFile ? "\(url.user ?? "服务器") /" : "/") : url.lastPathComponent)
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(url == pane.directory)
                                    .help(url.locationLabel)
                                    .accessibilityLabel("跳转到 \(url.locationLabel)")
                                    .id(url)
                                }
                            }.font(.callout)
                        }.scrollIndicators(.hidden)
                        .onAppear { if let url = pane.directory { proxy.scrollTo(url, anchor: .trailing) } }
                        .onChange(of: pane.directory) { _, url in
                            if let url { proxy.scrollTo(url, anchor: .trailing) }
                        }
                    }
                } else {
                    Text("请选择本地目录或服务器开始浏览").font(.callout)
                }
                Spacer(minLength: 0)
                if let directory = pane.directory {
                    Button("输入路径…", systemImage: "pencil") { editing = FileEditRequest(kind: .path, location: directory) }
                        .labelStyle(.iconOnly)
                }
                if pane.loading { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            HStack(spacing: 8) {
                TextField("查找当前目录中的名称", text: $pane.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: pane.searchQuery) { _, _ in
                        pane.selection.formIntersection(Set(pane.visibleEntries.map(\.url)))
                    }

            }.padding(.horizontal, 12).padding(.bottom, 10)
            HStack(spacing: 12) {
                Button("复制", systemImage: "doc.on.doc") { PaneFileActions.copy(pane.selectedURLs) }
                    .disabled(pane.selection.isEmpty).help("复制所选项目（⌘C）")
                Button("粘贴", systemImage: "doc.on.clipboard") { PaneFileActions.paste(into: pane.directory, transfers: transfers) }
                    .disabled(pane.directory == nil || transfers.deleting).help("粘贴到当前目录（⌘V）")
                Button("删除", systemImage: "trash", role: .destructive) { PaneFileActions.confirmDelete(pane.selectedURLs, transfers: transfers) }
                    .disabled(pane.selection.isEmpty || transfers.running || transfers.deleting)
                    .help(pane.isRemote ? "永久删除远程项目，需确认（⌘⌫）" : "移到废纸篓，需确认（⌘⌫）；传输期间暂不可用")
                Spacer(minLength: 0)
                if transfers.deleting { ProgressView().controlSize(.small) }
            }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            if pane.directory == nil {
                ContentUnavailableView {
                    Label(pane.pendingConnection == nil ? "选择\(title)位置" : "恢复远程目录", systemImage: pane.pendingConnection == nil ? "folder" : "server.rack")
                } description: {
                    if let server = pane.pendingConnection {
                        VStack(spacing: 6) {
                            Text(server.name).font(.headline).lineLimit(2)
                            Text(server.directory)
                                .lineLimit(3).truncationMode(.middle)
                                .textSelection(.enabled).help(server.directory)
                            if pane.loading {
                                ProgressView("正在恢复连接…").controlSize(.small)
                            } else {
                                Text(pane.restorationMessage ?? "连接服务器后，恢复此工作区保存的目录。")
                            }
                        }
                        .frame(maxWidth: 280)
                    } else {
                        Text("选择本地目录、已挂载的共享或已保存的服务器\n然后将文件拖到另一栏进行复制")
                    }
                } actions: {
                    VStack(spacing: 12) {
                        if let server = pane.pendingConnection {
                            Button("连接并恢复", systemImage: "arrow.clockwise") { restoringServer = server }
                                .buttonStyle(.borderedProminent).disabled(pane.loading)
                            LocationMenu(pane: pane, servers: servers, transfers: transfers, title: "选择其他位置…", addServer: addServer)
                                .buttonStyle(.bordered)
                        } else {
                            LocationMenu(pane: pane, servers: servers, transfers: transfers, title: "选择位置…", addServer: addServer)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            } else if let error = pane.error {
                ContentUnavailableView("无法读取目录", systemImage: "exclamationmark.folder", description: Text(error))
                    .frame(maxHeight: .infinity)
            } else {
                NativeFileTable(entries: pane.visibleEntries, canGoUp: pane.canGoUp, goUp: { pane.up() }, selection: $pane.selection,
                                open: { pane.navigate($0) }, copySelection: { PaneFileActions.copy(pane.selectedURLs) },
                                pasteSelection: { PaneFileActions.paste(into: pane.directory, transfers: transfers) },
                                deleteSelection: { PaneFileActions.confirmDelete(pane.selectedURLs, transfers: transfers) },
                                copyToOther: { copy(pane.selection) },
                                receive: { urls, folder, moving in
                                    if let directory = folder ?? pane.directory { transfers.enqueue(urls, to: directory, moving: moving) }
                                }, canCopy: other.directory != nil && !transfers.deleting,
                                canPaste: !pane.loading && !transfers.deleting, canDelete: !transfers.running && !transfers.deleting,
                                sort: $pane.sort, ascending: $pane.ascending, foldersFirst: $pane.foldersFirst,
                                canEdit: !pane.loading && !transfers.running && !transfers.deleting,
                                createDirectory: {
                                    if let directory = pane.directory { editing = FileEditRequest(kind: .createDirectory, location: directory) }
                                }, rename: { url in editing = FileEditRequest(kind: .rename, location: url) })
                .overlay { if pane.visibleEntries.isEmpty && !pane.loading { Text(pane.searchQuery.isEmpty ? "此目录为空" : "没有匹配的项目").foregroundStyle(.secondary).allowsHitTesting(false) } }
            }
            Divider()
            HStack {
                Text("\(pane.visibleEntries.count) / \(pane.entries.count) 个项目 · 已选 \(pane.selection.count) 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制到另一栏", systemImage: title == "左栏" ? "arrow.right" : "arrow.left") { copy(pane.selection) }
                    .disabled(pane.selection.isEmpty || other.directory == nil || transfers.deleting)
            }.padding(10)
        }
        .sheet(item: $editing) { request in
            FileNameSheet(request: request) { name in
                if request.kind == .path {
                    let destination = try DirectoryListing.location(name, relativeTo: request.location)
                    pane.navigate(destination)
                } else {
                    try await transfers.editItem(at: request.location, name: name, rename: request.kind == .rename)
                }
            }
        }
        .sheet(item: $restoringServer) { ServerConnectionView(server: $0, pane: pane) }
        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)

    }
    private func copy(_ selected: Set<URL>) {
        guard let target = other.directory else { return }
        transfers.enqueue(pane.visibleEntries.filter { selected.contains($0.id) }.map(\.url), to: target)
    }
}
