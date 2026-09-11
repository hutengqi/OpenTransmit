import SwiftUI
import AppKit
import Observation

@MainActor @Observable final class PaneStore {
    var directory: URL?
    var entries: [FileEntry] = []
    var selection: Set<URL> = []
    var showHidden = false
    var loading = false
    var error: String?
    private var accessRoot: URL?
    private var history: [URL] = []
    private var generation = UUID()
    private let service = LocalFileService()

    var selectedURLs: [URL] { entries.filter { selection.contains($0.id) }.map(\.url) }
    var canGoBack: Bool { !history.isEmpty }
    var canGoUp: Bool { directory != nil && (directory?.isRemoteFile == true ? directory?.path != "/" : directory != accessRoot) }
    var isRemote: Bool { directory?.isRemoteFile == true }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "打开目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openRoot(url)
    }
    func openRoot(_ url: URL) {
        // Keep old grants until process exit: an in-flight copy may still use them.
        _ = url.startAccessingSecurityScopedResource()
        accessRoot = url
        history = []
        navigate(url, recordHistory: false)
    }
    func openRemote(_ url: URL) {
        accessRoot = nil
        history = []
        navigate(url, recordHistory: false)
    }
    func disconnect() {
        guard let url = directory, url.isRemoteFile else { return }
        generation = UUID()
        directory = nil; entries = []; selection = []; history = []; loading = false; error = nil
        Task { await SFTPRegistry.shared.disconnect(url) }
    }
    func bookmark() throws -> Data {
        guard let directory, directory.isFileURL else { throw CocoaError(.fileNoSuchFile) }
        return try directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func restore(_ data: Data) throws {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        openRoot(url)
    }
    func navigate(_ url: URL, recordHistory: Bool = true) {
        if recordHistory, let directory { history.append(directory) }
        directory = url
        selection = []
        refresh()
    }
    func back() { if let previous = history.popLast() { navigate(previous, recordHistory: false) } }
    func up() { if canGoUp, let directory { navigate(directory.deletingLastPathComponent()) } }
    func refresh() {
        guard let directory else { return }
        let token = UUID()
        generation = token
        loading = true
        error = nil
        let hidden = showHidden
        Task {
            do {
                let result: [FileEntry]
                if directory.isRemoteFile {
                    result = try await SFTPRegistry.shared.children(directory).filter { hidden || !$0.name.hasPrefix(".") }.sorted {
                        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                } else { result = try await service.list(directory, showHidden: hidden) }
                guard generation == token else { return }
                entries = result
                selection.formIntersection(Set(result.map(\.id)))
            } catch {
                guard generation == token else { return }
                self.error = error.transferDescription
                entries = []
            }
            loading = false
        }
    }
}
