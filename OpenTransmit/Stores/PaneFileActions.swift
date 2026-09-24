import AppKit

@MainActor enum PaneFileActions {
    static var clipboardURLs: [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []).filter(\.isTransferLocation)
    }
    static func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
    }
    static func paste(into directory: URL?, transfers: TransferStore) {
        guard let directory, !transfers.deleting else { return }
        transfers.enqueue(clipboardURLs, to: directory, duplicateInPlace: true)
    }
    static func confirmDelete(_ urls: [URL], transfers: TransferStore) {
        guard urls.allSatisfy(\.isTransferLocation), !urls.isEmpty, !transfers.installingApplicationUpdate, !transfers.running, !transfers.deleting else { return }
        let remote = urls.contains { $0.isRemoteFile }
        // Freeze the exact selection before opening confirmation.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = remote ? "永久删除选中的 \(urls.count) 个远程项目？" : "将选中的 \(urls.count) 个项目移到废纸篓？"
        let names = urls.prefix(8).map { remote ? $0.locationLabel : $0.lastPathComponent }.joined(separator: "\n")
        alert.informativeText = names + (urls.count > 8 ? "\n…另有 \(urls.count - 8) 项" : "") + (remote ? "\n\n目录及其全部内容将永久删除，无法通过本机废纸篓恢复。符号链接仅删除链接本身。操作失败时可能已有部分内容被删除。" : "\n\n文件夹中的内容也会一起移入废纸篓。不支持废纸篓的位置会报告失败，不会永久删除。")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: remote ? "永久删除" : "移到废纸篓")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn,
              !transfers.installingApplicationUpdate, !transfers.running, !transfers.deleting else { return }
        transfers.deleting = true
        Task {
            var result = await TrashService().trash(urls.filter(\.isFileURL))
            let remoteResult = await SFTPRegistry.shared.delete(urls.filter(\.isRemoteFile))
            result.completed += remoteResult.completed
            result.failures += remoteResult.failures
            transfers.deleting = false
            transfers.onChange?()
            if !result.failures.isEmpty {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = "已删除 \(result.completed.count) 项，\(result.failures.count) 项失败"
                failure.informativeText = result.failures.joined(separator: "\n")
                failure.runModal()
            }
        }
    }
}
