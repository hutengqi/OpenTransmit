import SwiftUI
import AppKit

/// AppKit owns desktop drag sessions; SwiftUI remains the owner of file and selection state.
struct NativeFileTable: NSViewRepresentable {
    let entries: [FileEntry]
    let canGoUp: Bool
    let goUp: () -> Void
    @Binding var selection: Set<URL>
    let open: (URL) -> Void
    let copySelection: () -> Void
    let pasteSelection: () -> Void
    let deleteSelection: () -> Void
    let copyToOther: () -> Void
    let receive: ([URL]) -> Void
    let canCopy: Bool
    let canPaste: Bool
    let canDelete: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let table = FileActionTableView(frame: scroll.bounds)
        for (id, title, width) in [("name", "名称", 230.0), ("size", "大小", 80.0), ("date", "修改时间", 150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 120 : 70
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 26
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openRow)
        table.registerForDraggedTypes([.fileURL, .URL])
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        context.coordinator.table = table
        table.copyFiles = { [weak coordinator = context.coordinator] in coordinator?.parent.copySelection() }
        table.pasteFiles = { [weak coordinator = context.coordinator] in coordinator?.parent.pasteSelection() }
        table.deleteFiles = { [weak coordinator = context.coordinator] in coordinator?.parent.deleteSelection() }
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.parent.entries != entries || coordinator.parent.canGoUp != canGoUp
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        table.permitsPaste = canPaste
        table.permitsDelete = canDelete
        coordinator.updating = true
        if changed { table.reloadData() }
        let indexes = IndexSet(entries.indices.filter { selection.contains(entries[$0].url) }.map { $0 + coordinator.offset })
        if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        coordinator.updating = false
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: NativeFileTable
        weak var table: FileActionTableView?
        var updating = false
        init(_ parent: NativeFileTable) { self.parent = parent }
        var offset: Int { parent.canGoUp ? 1 : 0 }
        func entry(at row: Int) -> FileEntry? {
            let index = row - offset
            return parent.entries.indices.contains(index) ? parent.entries[index] : nil
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.entries.count + offset }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { entry(at: row) != nil }
        func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
            IndexSet(proposedSelectionIndexes.filter { entry(at: $0) != nil })
        }
        @objc func goUp() { parent.goUp() }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if parent.canGoUp && row == 0 {
                guard tableColumn?.identifier.rawValue == "name" else { return NSTextField(labelWithString: "") }
                let button = NSButton(title: "..", target: self, action: #selector(goUp))
                button.isBordered = false
                button.alignment = .left
                button.image = NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: nil)
                button.imagePosition = .imageLeading
                button.toolTip = "返回上一级目录"
                button.setAccessibilityLabel(".. 返回上一级目录")
                return button
            }
            guard let entry = entry(at: row) else { return nil }
            let identifier = tableColumn?.identifier.rawValue ?? "name"
            let text: String
            switch identifier {
            case "size": text = entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
            case "date": text = entry.modified?.formatted(date: .numeric, time: .shortened) ?? "—"
            default: text = entry.name
            }
            let field = NSTextField(labelWithString: text)
            field.lineBreakMode = .byTruncatingMiddle
            field.textColor = identifier == "name" ? .labelColor : .secondaryLabelColor
            if identifier != "name" { return field }
            let icon = NSImageView(image: NSImage(systemSymbolName: entry.isDirectory ? "folder.fill" : "doc", accessibilityDescription: entry.isDirectory ? "文件夹" : "文件")!)
            icon.contentTintColor = entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let stack = NSStackView(views: [icon, field])
            stack.spacing = 7
            return stack
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap { entry(at: $0)?.url })
        }
        @objc func openRow() {
            guard let table, let entry = entry(at: table.clickedRow) else { return }
            if entry.isDirectory { parent.open(entry.url) }
        }
        @objc func copyRows() { parent.copySelection() }
        @objc func pasteRows() { parent.pasteSelection() }
        @objc func deleteRows() { parent.deleteSelection() }
        @objc func copyAcross() { parent.copyToOther() }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            if parent.canGoUp && table.clickedRow == 0 {
                let item = NSMenuItem(title: "返回上一级目录", action: #selector(goUp), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
                return
            }
            if table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            }
            menu.autoenablesItems = false
            for (title, action, enabled) in [
                ("复制", #selector(copyRows), !table.selectedRowIndexes.isEmpty),
                ("粘贴", #selector(pasteRows), parent.canPaste && !PaneFileActions.clipboardURLs.isEmpty),
                ("复制到另一栏", #selector(copyAcross), parent.canCopy && !table.selectedRowIndexes.isEmpty),
                (parent.entries.first?.url.isRemoteFile == true ? "永久删除…" : "移到废纸篓…", #selector(deleteRows), parent.canDelete && !table.selectedRowIndexes.isEmpty)
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.isEnabled = enabled
                menu.addItem(item)
            }
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            entry(at: row)?.url as NSURL?
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty, urls.allSatisfy(\.isTransferLocation) else { return false }
            parent.receive(urls)
            return true
        }
    }
}
