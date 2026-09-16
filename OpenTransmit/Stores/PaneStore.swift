import SwiftUI
import AppKit
import Observation

@MainActor @Observable final class PaneStore {
    var directory: URL?
    var serverProfile: ServerProfile?
    var pendingConnection: ServerProfile?
    var restorationMessage: String?
    private var restorationTask: Task<Void, Never>?
    var entries: [FileEntry] = []
    var selection: Set<URL> = []
    var showHidden = false
    var searchQuery = ""
    var sort: FileSort = .name
    var ascending = true
    var foldersFirst = true
    var visibleEntries: [FileEntry] { DirectoryListing.entries(entries, query: searchQuery, sort: sort, ascending: ascending, foldersFirst: foldersFirst) }
    var loading = false
    var error: String?
    private var accessRoots: [URL] = []
    private var history: [URL] = []
    private var generation = UUID()
    private let service = LocalFileService()

    var selectedURLs: [URL] { visibleEntries.filter { selection.contains($0.id) }.map(\.url) }
    var canGoBack: Bool { !history.isEmpty }
    /// All sources expose their full ancestor chain, independently of local access grants.
    var breadcrumbURLs: [URL] {
        guard var current = directory else { return [] }
        var result = [current]
        while current.path != "/" {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            result.append(parent)
            current = parent
        }
        return result.reversed()
    }
    var canGoUp: Bool { breadcrumbURLs.count > 1 }
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
        restorationTask?.cancel(); restorationTask = nil; restorationMessage = nil
        serverProfile = nil; pendingConnection = nil
        // Keep old grants until process exit: an in-flight copy may still use them.
        _ = url.startAccessingSecurityScopedResource()
        accessRoots.append(url.standardizedFileURL)
        history = []
        navigate(url, recordHistory: false)
    }
    func openRemote(_ url: URL, server: ServerProfile? = nil) {
        restorationTask?.cancel(); restorationTask = nil; restorationMessage = nil
        serverProfile = server; pendingConnection = nil
        history = []
        navigate(url, recordHistory: false)
    }
    func disconnect() {
        restorationTask?.cancel(); restorationTask = nil
        pendingConnection = nil; restorationMessage = nil; loading = false
        guard let url = directory, url.isRemoteFile else { return }
        generation = UUID()
        directory = nil; entries = []; selection = []; history = []; loading = false; error = nil
        Task { await SFTPRegistry.shared.disconnect(url) }
    }
    func restoreSavedConnection() {
        guard let server = pendingConnection, server.protocolKind == .sftp || server.protocolKind == .ftps else { return }
        restorationTask?.cancel()
        loading = true
        restorationMessage = nil
        restorationTask = Task {
            do {
                let vault = CredentialVault(server: server)
                guard let password = try vault.read(account: vault.account(privateKey: nil), allowInteraction: false, useSessionCache: true) else {
                    loading = false
                    restorationMessage = "未找到已保存的密码，请手动连接。"
                    return
                }
                try Task.checkCancellation()
                var credentials = SSHCredentials()
                credentials.password = password
                let url = try await SFTPRegistry.shared.connect(server, credentials: credentials, trustedKey: SSHHostTrust.key(for: server))
                if Task.isCancelled {
                    await SFTPRegistry.shared.disconnect(url)
                    return
                }
                openRemote(url, server: server)
            } catch {
                guard !Task.isCancelled else { return }
                loading = false
                restorationMessage = "自动连接未完成，请手动连接：\(error.transferDescription)"
            }
        }
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
        if url.isFileURL && !hasLocalAccess(to: url) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = url
            panel.prompt = "授权并打开"
            panel.message = "请选择当前要打开的目录，以允许访问该目录及其子目录。"
            guard panel.runModal() == .OK, let granted = panel.url else { return }
            guard granted.standardizedFileURL.path == url.standardizedFileURL.path else {
                error = "请选择要跳转的目录：\(url.path)"
                return
            }
            _ = granted.startAccessingSecurityScopedResource()
            accessRoots.append(granted.standardizedFileURL)
        }
        if recordHistory, let directory { history.append(directory) }
        directory = url
        searchQuery = ""
        selection = []
        refresh()
    }
    private func hasLocalAccess(to url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return accessRoots.contains { root in
            let rootPath = root.path
            return rootPath == "/" || path == rootPath || path.hasPrefix(rootPath + "/")
        }
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
