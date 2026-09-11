import SwiftUI
import AppKit

/// AppKit owns desktop drag sessions; SwiftUI remains the owner of file and selection state.
struct NativeFileTable: NSViewRepresentable {
    let entries: [FileEntry]
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
        let changed = coordinator.parent.entries != entries
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        table.permitsPaste = canPaste
        table.permitsDelete = canDelete
        coordinator.updating = true
        if changed { table.reloadData() }
        let indexes = IndexSet(entries.indices.filter { selection.contains(entries[$0].url) })
        if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        coordinator.updating = false
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: NativeFileTable
        weak var table: FileActionTableView?
        var updating = false
        init(_ parent: NativeFileTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.entries.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let entry = parent.entries[row]
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
            parent.selection = Set(table.selectedRowIndexes.compactMap { parent.entries.indices.contains($0) ? parent.entries[$0].url : nil })
        }
        @objc func openRow() {
            guard let table, parent.entries.indices.contains(table.clickedRow) else { return }
            let entry = parent.entries[table.clickedRow]
            if entry.isDirectory { parent.open(entry.url) }
        }
        @objc func copyRows() { parent.copySelection() }
        @objc func pasteRows() { parent.pasteSelection() }
        @objc func deleteRows() { parent.deleteSelection() }
        @objc func copyAcross() { parent.copyToOther() }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            if table.clickedRow >= 0 && !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            }
            menu.autoenablesItems = false
            for (title, action, enabled) in [
                ("复制", #selector(copyRows), !table.selectedRowIndexes.isEmpty),
                ("粘贴", #selector(pasteRows), parent.canPaste && !PaneFileActions.clipboardURLs.isEmpty),
                ("复制到另一栏", #selector(copyAcross), parent.canCopy && !table.selectedRowIndexes.isEmpty),
                ("移到废纸篓…", #selector(deleteRows), parent.canDelete && !table.selectedRowIndexes.isEmpty)
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.isEnabled = enabled
                menu.addItem(item)
            }
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            parent.entries[row].url as NSURL
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
