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
            if let message = store.recoveryMessage { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !store.orphanedTasks.isEmpty {
                HStack {
                    Text("\(store.orphanedTasks.count) 项可恢复任务（从头重新执行）").font(.caption)
                    Menu("恢复任务") {
                        ForEach(store.orphanedTasks) { saved in
                            Menu("\(saved.moving == true ? "移动 · " : "复制 · ")\((saved.source.path as NSString).lastPathComponent) → \(saved.destination.path)") {
                                Button("从头重新执行") { store.recover(saved) }
                                Button("移除任务记录", role: .destructive) { store.savedTasks.removeAll { $0.id == saved.id } }
                            }
                        }
                    }.disabled(store.deleting)
                }
            }
            if store.jobs.isEmpty {
                Text("将文件拖到另一栏，或选中文件后点击“复制到另一栏”")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.jobs) { job in
                    HStack {
                        Image(systemName: job.failed ? "exclamationmark.circle" : job.finished ? "checkmark.circle" : "arrow.right.circle")
                            .foregroundStyle(job.failed ? Color.red : Color.secondary)
                        VStack(alignment: .leading) {
                            Text("\(job.moving ? "移动" : "复制") · \(job.source.lastPathComponent)").lineLimit(1)
                            Text("→ \(job.destination.locationLabel)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            if let fraction = job.fraction {
                                ProgressView(value: fraction).frame(width: 120)
                                Text("\(Int(fraction * 100))% · \(ByteCountFormatter.string(fromByteCount: job.bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: job.totalBytes ?? 0, countStyle: .file))")
                                    .font(.caption).monospacedDigit()
                            }
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text("平均处理 \(ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max / 2), job.bytesPerSecond(at: context.date))), countStyle: .file))/秒")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }.help("按逻辑文件内容统计；FTP 暂存与提交阶段不等同于网络速度。提交完成前最多显示 99%。")
                        if !job.warnings.isEmpty {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                .help(job.warnings.joined(separator: "\n"))
                        }
                        Text(job.status).font(.caption).lineLimit(2).frame(maxWidth: 250, alignment: .trailing)
                        if job.failed || job.cancelled { Button("重新执行") { store.retry(job) } }
                    }
                }.listStyle(.plain)
            }
        }.frame(height: 220)
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
