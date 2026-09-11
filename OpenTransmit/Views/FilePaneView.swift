import SwiftUI
import UniformTypeIdentifiers

struct FilePaneView: View {
    let title: String
    @Bindable var pane: PaneStore
    let other: PaneStore
    let transfers: TransferStore
    let servers: [ServerProfile]
    let addServer: () -> Void
    @State private var isTargeted = false

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
                Text(pane.directory?.locationLabel ?? "请选择本地目录或服务器开始浏览")
                    .font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 0)
                if pane.loading { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            HStack(spacing: 12) {
                Button("复制", systemImage: "doc.on.doc") { PaneFileActions.copy(pane.selectedURLs) }
                    .disabled(pane.selection.isEmpty).help("复制所选项目（⌘C）")
                Button("粘贴", systemImage: "doc.on.clipboard") { PaneFileActions.paste(into: pane.directory, transfers: transfers) }
                    .disabled(pane.directory == nil || transfers.deleting).help("粘贴到当前目录（⌘V）")
                Button("删除", systemImage: "trash", role: .destructive) { PaneFileActions.confirmDelete(pane.selectedURLs, transfers: transfers) }
                    .disabled(pane.isRemote || pane.selection.isEmpty || transfers.running || transfers.deleting)
                    .help(pane.isRemote ? "远程删除尚未开放" : "移到废纸篓，需确认（⌘⌫）；传输期间暂不可用")
                Spacer(minLength: 0)
                if transfers.deleting { ProgressView().controlSize(.small) }
            }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            if pane.directory == nil {
                ContentUnavailableView {
                    Label("选择\(title)位置", systemImage: "folder")
                } description: {
                    Text("选择本地目录、已挂载的共享或已保存的服务器\n然后将文件拖到另一栏进行复制")
                } actions: { LocationMenu(pane: pane, servers: servers, transfers: transfers, title: "选择位置…", addServer: addServer).buttonStyle(.borderedProminent) }
                .frame(maxHeight: .infinity)
            } else if let error = pane.error {
                ContentUnavailableView("无法读取目录", systemImage: "exclamationmark.folder", description: Text(error))
                    .frame(maxHeight: .infinity)
            } else {
                NativeFileTable(entries: pane.entries, selection: $pane.selection,
                                open: { pane.navigate($0) }, copySelection: { PaneFileActions.copy(pane.selectedURLs) },
                                pasteSelection: { PaneFileActions.paste(into: pane.directory, transfers: transfers) },
                                deleteSelection: { PaneFileActions.confirmDelete(pane.selectedURLs, transfers: transfers) },
                                copyToOther: { copy(pane.selection) },
                                receive: { urls in
                                    if let directory = pane.directory { transfers.enqueue(urls, to: directory) }
                                }, canCopy: other.directory != nil && !transfers.deleting,
                                canPaste: !transfers.deleting, canDelete: !pane.isRemote && !transfers.running && !transfers.deleting)
                .overlay { if pane.entries.isEmpty && !pane.loading { Text("此目录为空").foregroundStyle(.secondary).allowsHitTesting(false) } }
            }
            Divider()
            HStack {
                Text("\(pane.entries.count) 个项目 · 已选 \(pane.selection.count) 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制到另一栏", systemImage: title == "左栏" ? "arrow.right" : "arrow.left") { copy(pane.selection) }
                    .disabled(pane.selection.isEmpty || other.directory == nil || transfers.deleting)
            }.padding(10)
        }
        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if isTargeted { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL.identifier, UTType.url.identifier], isTargeted: $isTargeted) { providers in
            guard let directory = pane.directory else { return false }
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                            continuation.resume(returning: object as? URL)
                        }
                    }
                    if let url, url.isTransferLocation { urls.append(url) }
                }
                transfers.enqueue(urls, to: directory)
            }
            return true
        }
    }
    private func copy(_ selected: Set<URL>) {
        guard let target = other.directory else { return }
        transfers.enqueue(pane.entries.filter { selected.contains($0.id) }.map(\.url), to: target)
    }
}
