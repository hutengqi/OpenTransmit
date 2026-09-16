import SwiftUI

struct DirectoryComparisonRequest: Identifiable {
    let id = UUID()
    let left: URL
    let right: URL
}

struct DirectoryComparisonView: View {
    let request: DirectoryComparisonRequest
    let transfers: TransferStore
    @Environment(\.dismiss) private var dismiss
    @State private var reversed = false
    @State private var rows: [DirectoryDifference] = []
    @State private var selected: Set<UUID> = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("目录差异预览").font(.title2.bold())
            Picker("复制方向", selection: $reversed) {
                Text("左 → 右").tag(false)
                Text("右 → 左").tag(true)
            }.pickerStyle(.segmented)
            Text("来源：\((reversed ? request.right : request.left).locationLabel)")
            Text("目标：\((reversed ? request.left : request.right).locationLabel)")
            Text("递归比较大小和修改时间（精度为秒），不校验内容。仅复制勾选项目，不删除目标独有内容；新增目录包含全部子项。执行时仍会询问同名冲突。").font(.caption).foregroundStyle(.secondary)
            if loading { ProgressView("正在比较目录…") }
            if let error { Text(error).foregroundStyle(.red) }
            List(rows) { row in
                HStack {
                    Toggle(isOn: Binding(get: { selected.contains(row.id) }, set: { enabled in
                        if enabled { selected.insert(row.id) } else { selected.remove(row.id) }
                    })) { Text(row.path).lineLimit(1).help(row.path) }
                    .disabled(!row.selectable)
                    Spacer()
                    Text(row.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !loading && error == nil && rows.isEmpty { Text("未发现大小或修改时间差异。").foregroundStyle(.secondary) }
            HStack {
                Button("全选可复制项") { selected = Set(rows.filter(\.selectable).map(\.id)) }.disabled(loading)
                Button("取消全选") { selected.removeAll() }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确认复制 \(selected.count) 项") {
                    for row in rows where row.selectable && selected.contains(row.id) {
                        transfers.enqueue([row.source], to: row.destination)
                    }
                    dismiss()
                }.disabled(loading || error != nil || selected.isEmpty || transfers.running || transfers.deleting)
            }
        }
        .padding(24).frame(width: 760, height: 520)
        .task(id: reversed) {
            loading = true; rows = []; selected = []; error = nil
            do {
                let result = try await DirectoryComparison(endpoint: SFTPRegistry.shared).compare(
                    source: reversed ? request.right : request.left,
                    destination: reversed ? request.left : request.right)
                try Task.checkCancellation()
                rows = result
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription; loading = false
            }
        }
    }
}
