import SwiftUI

struct TransferQueueView: View {
    @Bindable var store: TransferStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("传输队列", systemImage: "arrow.left.arrow.right").font(.headline)
                Text("\(store.jobs.filter { !$0.finished }.count) 项待完成").foregroundStyle(.secondary)
                Spacer()
                if store.running { ProgressView().controlSize(.small); Button("取消全部", role: .destructive) { store.cancel() } }
                Button("清除已结束") { store.jobs.removeAll { $0.finished } }.disabled(store.running || store.jobs.isEmpty)
            }.padding(12)
            if store.jobs.isEmpty {
                Text("将文件拖到另一栏，或选中文件后点击“复制到另一栏”")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.jobs) { job in
                    HStack {
                        Image(systemName: job.failed ? "exclamationmark.circle" : job.finished ? "checkmark.circle" : "arrow.right.circle")
                            .foregroundStyle(job.failed ? Color.red : Color.secondary)
                        VStack(alignment: .leading) {
                            Text(job.source.lastPathComponent).lineLimit(1)
                            Text("→ \(job.destination.locationLabel)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: job.bytes, countStyle: .file)).monospacedDigit().foregroundStyle(.secondary)
                        Text(job.status).font(.caption).lineLimit(2).frame(maxWidth: 250, alignment: .trailing)
                        if job.failed { Button("重试") { store.retry(job) } }
                    }
                }.listStyle(.plain)
            }
        }.frame(height: 180)
    }
}

struct ConflictView: View {
    let conflict: FileConflict
    @Bindable var store: TransferStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("目标已存在同名项目", systemImage: "doc.on.doc").font(.title2.bold())
            Text(conflict.destination.lastPathComponent).font(.headline)
            detail("来源", conflict.source, entry: conflict.sourceEntry)
            detail("目标", conflict.destination, entry: conflict.destinationEntry)
            Text("替换仅适用于文件；同名目录会合并。保留两者将自动添加“副本”后缀。").font(.callout).foregroundStyle(.secondary)
            Toggle("对本轮队列后续冲突应用此选择", isOn: $store.applyToRemaining)
            HStack {
                Button("取消传输", role: .cancel) { store.resolve(.cancel) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("跳过") { store.resolve(.skip) }
                Button("替换", role: .destructive) { store.resolve(.replace) }
                Button("保留两者") { store.resolve(.keepBoth) }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560)
    }
    private func detail(_ label: String, _ url: URL, entry: FileEntry?) -> some View {
        let values = url.isFileURL ? try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) : nil
        let isDirectory = entry?.isDirectory ?? values?.isDirectory ?? false
        let size = entry?.size ?? Int64(values?.fileSize ?? 0)
        let modified = entry?.modified ?? values?.contentModificationDate
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(label)：\(url.locationLabel)").lineLimit(2).truncationMode(.middle)
            Text("\(isDirectory ? "目录" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) · \(modified?.formatted() ?? "未知修改时间")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
