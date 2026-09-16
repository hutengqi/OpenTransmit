import Foundation

enum FileSort: String, CaseIterable, Identifiable {
    case name = "名称", size = "大小", modified = "修改时间"
    var id: String { rawValue }
}

enum DirectoryListing {
    static func entries(_ entries: [FileEntry], query: String, sort: FileSort, ascending: Bool, foldersFirst: Bool) -> [FileEntry] {
        entries.filter { query.isEmpty || $0.name.localizedStandardContains(query) }.sorted { a, b in
            if foldersFirst && a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: ComparisonResult
            switch sort {
            case .name: order = a.name.localizedStandardCompare(b.name)
            case .size: order = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .modified:
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                order = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            }
            let resolved = order == .orderedSame ? a.name.localizedStandardCompare(b.name) : order
            return ascending ? resolved == .orderedAscending : resolved == .orderedDescending
        }
    }
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw TransferFailure(message: "名称不能为空、. 或 ..，也不能包含路径分隔符或控制字符。")
        }
    }
    static func location(_ input: String, relativeTo current: URL) throws -> URL {
        guard !input.isEmpty, !input.contains("://"), !input.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw TransferFailure(message: "请输入当前文件源中的目录路径，而非服务器地址。")
        }
        let path = current.isFileURL ? (input as NSString).expandingTildeInPath : input
        let absolute = path.hasPrefix("/") ? path : (current.path as NSString).appendingPathComponent(path)
        let normalized = (absolute as NSString).standardizingPath
        if current.isFileURL { return URL(fileURLWithPath: normalized, isDirectory: true) }
        var parts = URLComponents(url: current, resolvingAgainstBaseURL: false)!
        parts.path = normalized
        guard let url = parts.url else { throw TransferFailure(message: "目录路径无效。") }
        return url
    }
}
