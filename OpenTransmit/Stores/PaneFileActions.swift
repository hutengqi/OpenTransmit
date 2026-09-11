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
        guard urls.allSatisfy(\.isFileURL), !urls.isEmpty, !transfers.running, !transfers.deleting else { return }
        // Freeze the exact selection before opening confirmation.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "将选中的 \(urls.count) 个项目移到废纸篓？"
        let names = urls.prefix(8).map(\.lastPathComponent).joined(separator: "\n")
        alert.informativeText = names + (urls.count > 8 ? "\n…另有 \(urls.count - 8) 项" : "") + "\n\n文件夹中的内容也会一起移入废纸篓。不支持废纸篓的位置会报告失败，不会永久删除。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移到废纸篓")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        transfers.deleting = true
        Task {
            let result = await TrashService().trash(urls)
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
