import Foundation

struct TrashResult: Sendable {
    var completed: [URL] = []
    var failures: [String] = []
}

actor TrashService {
    // Injectable operation lets regressions verify partial failure without touching the user's Trash.
    private let move: @Sendable (URL) throws -> Void
    init(move: @escaping @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) { self.move = move }

    func trash(_ urls: [URL]) -> TrashResult {
        var result = TrashResult()
        var seen: Set<URL> = []
        for url in urls where seen.insert(url.standardizedFileURL).inserted {
            do {
                guard url.isFileURL, url.standardizedFileURL.path != "/" else { throw CocoaError(.fileWriteNoPermission) }
                try move(url)
                result.completed.append(url)
            } catch { result.failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        return result
    }
}
