import Foundation

struct DirectoryDifference: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    let destination: URL
    let path: String
    let reason: String
    let selectable: Bool
}

/// Read-only comparison. Missing directories are explicit recursive-copy units.
actor DirectoryComparison {
    let endpoint: any TransferEndpoint
    init(endpoint: any TransferEndpoint) { self.endpoint = endpoint }

    func compare(source: URL, destination: URL) async throws -> [DirectoryDifference] {
        let a = try await endpoint.canonicalIdentity(source)
        let b = try await endpoint.canonicalIdentity(destination)
        guard a != b, !a.hasPrefix(b.hasSuffix("/") ? b : b + "/"), !b.hasPrefix(a.hasSuffix("/") ? a : a + "/") else {
            throw TransferFailure(message: "不能比较相同目录或互为父子的目录。")
        }
        return try await walk(source, destination, prefix: "", depth: 0)
    }

    private func walk(_ source: URL, _ target: URL, prefix: String, depth: Int) async throws -> [DirectoryDifference] {
        try Task.checkCancellation()
        guard depth < 128 else { throw TransferFailure(message: "目录层级超过比较上限。") }
        var rows: [DirectoryDifference] = []
        let sources = try await endpoint.children(source).filter { !$0.isSystemMetadata }
        let targets = try await endpoint.children(target).filter { !$0.isSystemMetadata }
        var remaining = Dictionary(targets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for item in sources.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            try Task.checkCancellation()
            let name = item.name
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                throw TransferFailure(message: "目录包含无效名称。")
            }
            let path = prefix + name
            let other = remaining.removeValue(forKey: name)
            func row(_ reason: String, enabled: Bool = true) -> DirectoryDifference {
                DirectoryDifference(source: item.url, destination: target, path: path, reason: reason, selectable: enabled)
            }
            if item.isSymbolicLink || other?.isSymbolicLink == true {
                rows.append(row("符号链接，不支持同步", enabled: false))
            } else if let other {
                if item.isDirectory != other.isDirectory {
                    rows.append(row("文件与目录类型冲突，请先手动处理", enabled: false))
                } else if item.isDirectory {
                    rows += try await walk(item.url, other.url, prefix: path + "/", depth: depth + 1)
                } else if item.size != other.size || item.modified == nil || other.modified == nil || abs(item.modified!.timeIntervalSince(other.modified!)) >= 1 {
                    rows.append(row("大小或修改时间不同"))
                }
            } else {
                // Validate the whole subtree before offering a recursive copy.
                if item.isDirectory { _ = try await EndpointTransferEngine(endpoint: endpoint).totalBytes(item.url) }
                rows.append(row(item.isDirectory ? "新增目录（复制全部子项）" : "新增文件"))
            }
        }
        for item in remaining.values.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            rows.append(DirectoryDifference(source: item.url, destination: target, path: prefix + item.name,
                                            reason: "仅目标存在，保留", selectable: false))
        }
        return rows
    }
}
