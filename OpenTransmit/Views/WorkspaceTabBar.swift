import SwiftUI

@MainActor @Observable final class WorkspaceTab: Identifiable {
    let id = UUID()
    let name: String?
    var direction: TransferDirection = .unspecified
    let left = PaneStore()
    let right = PaneStore()

    init(name: String? = nil) { self.name = name }
    var title: String {
        let leftURL = left.directory
        let rightURL = right.directory
        if let leftURL, let rightURL, leftURL.isRemoteFile && rightURL.isRemoteFile {
            return "\(leftURL.user ?? "SFTP") ↔ \(rightURL.user ?? "SFTP")"
        }
        if let remote = [leftURL, rightURL].compactMap({ $0 }).first(where: { $0.isRemoteFile }) {
            return remote.path.isEmpty ? "/" : remote.path
        }
        if let name { return name }
        func label(_ pane: PaneStore) -> String {
            guard let url = pane.directory else { return "未选择" }
            return url.isRemoteFile ? url.locationLabel : (url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent)
        }
        if left.directory == nil && right.directory == nil { return "新工作区" }
        return "\(label(left)) ↔ \(label(right))"
    }
}

struct WorkspaceTabBar: View {
    let tabs: [WorkspaceTab]
    let selectedID: UUID
    let canClose: Bool
    let select: (UUID) -> Void
    let add: () -> Void
    let close: (UUID) -> Void
    let save: (UUID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        HStack(spacing: 6) {
                            Button { select(tab.id) } label: {
                                Label(tab.title, systemImage: "rectangle.split.2x1")
                                    .lineLimit(1).frame(maxWidth: 220)
                            }
                            .buttonStyle(.plain)
                            .help(tab.title)
                            .accessibilityAddTraits(tab.id == selectedID ? .isSelected : [])
                            Button { close(tab.id) } label: { Image(systemName: "xmark").font(.caption) }
                                .buttonStyle(.borderless)
                                .disabled(!canClose)
                                .help(canClose ? "关闭标签页" : "传输或删除期间暂不可关闭标签页")
                                .accessibilityLabel("关闭标签页：\(tab.title)")
                        }
                        .contextMenu {
                            Button("保存工作区…", systemImage: "bookmark") { save(tab.id) }
                                .disabled(tab.left.directory == nil || tab.right.directory == nil)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(tab.id == selectedID ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            Button("新建标签页", systemImage: "plus", action: add).labelStyle(.iconOnly).help("新建工作区标签页（⌘T）")
        }.padding(8)
    }
}
