import AppKit

/// Responder-chain actions are scoped to the focused table, leaving text fields' shortcuts intact.
@MainActor final class FileActionTableView: NSTableView, NSMenuItemValidation {
    var copyFiles: (() -> Void)?
    var pasteFiles: (() -> Void)?
    var deleteFiles: (() -> Void)?
    var permitsPaste = false
    var permitsDelete = false

    @objc func copy(_ sender: Any?) { if !selectedRowIndexes.isEmpty { copyFiles?() } }
    @objc func paste(_ sender: Any?) { if permitsPaste { pasteFiles?() } }
    @objc func delete(_ sender: Any?) { if permitsDelete && !selectedRowIndexes.isEmpty { deleteFiles?() } }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard modifiers == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": copy(nil)
        case "v": paste(nil)
        case "a": selectAll(nil)
        default:
            guard event.keyCode == 51 || event.keyCode == 117 else { return super.performKeyEquivalent(with: event) }
            delete(nil)
        }
        return true
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return !selectedRowIndexes.isEmpty
        case #selector(paste(_:)): return permitsPaste && !PaneFileActions.clipboardURLs.isEmpty
        case #selector(delete(_:)): return permitsDelete && !selectedRowIndexes.isEmpty
        case #selector(selectAll(_:)): return numberOfRows > 0
        default: return true
        }
    }
}
