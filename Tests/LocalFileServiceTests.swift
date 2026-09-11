import Foundation

@main struct LocalFileServiceTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OpenTransmitTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("hello.txt")
        let target = destination.appendingPathComponent("hello.txt")
        try Data("new".utf8).write(to: file)
        let service = LocalFileService()
        let noProgress: @Sendable (Int64) async -> Void = { _ in }
        let copied = try await service.copy(file, into: destination, conflict: { _ in fatalError("Unexpected conflict") }, progress: noProgress)
        try expect(copied && read(target) == "new", "basic copy")
        try Data("old".utf8).write(to: target)
        _ = try await service.copy(file, into: destination, conflict: { _ in .skip }, progress: noProgress)
        try expect(read(target) == "old", "skip preserves target")
        _ = try await service.copy(file, into: destination, conflict: { _ in .keepBoth }, progress: noProgress)
        _ = try await service.copy(file, into: destination, conflict: { _ in .keepBoth }, progress: noProgress)
        try expect(read(target) == "old" && read(destination.appendingPathComponent("hello 副本.txt")) == "new" && read(destination.appendingPathComponent("hello 副本 2.txt")) == "new", "unique copies")
        _ = try await service.copy(file, into: destination, conflict: { _ in .replace }, progress: noProgress)
        try expect(read(target) == "new", "replace")
        do {
            _ = try await service.copy(file, into: source, conflict: { _ in .replace }, progress: noProgress)
            throw TestFailure(message: "self copy accepted")
        } catch is TestFailure { throw TestFailure(message: "self copy accepted") } catch {}
        try expect(read(file) == "new", "self copy rejected")
        do {
            _ = try await service.copy(source, into: source, conflict: { _ in .replace }, progress: noProgress)
            throw TestFailure(message: "descendant copy accepted")
        } catch is TestFailure { throw TestFailure(message: "descendant copy accepted") } catch {}
        print("PASS descendant rejected")
        let nested = source.appendingPathComponent("folder")
        let merged = destination.appendingPathComponent("folder")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: merged, withIntermediateDirectories: true)
        try Data("child".utf8).write(to: nested.appendingPathComponent("child"))
        try Data("keep".utf8).write(to: merged.appendingPathComponent("existing"))
        _ = try await service.copy(nested, into: destination, conflict: { _ in .replace }, progress: noProgress)
        try expect(read(merged.appendingPathComponent("child")) == "child" && read(merged.appendingPathComponent("existing")) == "keep", "directory merge preserves extras")
        let link = source.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        do {
            _ = try await service.copy(link, into: destination, conflict: { _ in .replace }, progress: noProgress)
            throw TestFailure(message: "symlink accepted")
        } catch is TestFailure { throw TestFailure(message: "symlink accepted") } catch {}
        print("PASS symlink rejected")
        do {
            _ = try await service.copy(file, into: destination, conflict: { _ in .cancel }, progress: noProgress)
            throw TestFailure(message: "cancel ignored")
        } catch is CancellationError {} 
        try expect(read(target) == "new", "conflict cancellation preserves target")
        let big = source.appendingPathComponent("big.bin")
        try Data(repeating: 42, count: 4 * 1024 * 1024).write(to: big)
        let bigTarget = destination.appendingPathComponent("big.bin")
        try Data("original".utf8).write(to: bigTarget)
        let task = Task {
            try await service.copy(big, into: destination, conflict: { _ in .replace }, progress: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        do { _ = try await task.value; throw TestFailure(message: "mid-copy cancellation ignored") }
        catch is CancellationError {}
        try expect(read(bigTarget) == "original", "mid-copy cancellation preserves target")
        try expect(try fm.contentsOfDirectory(atPath: destination.path).allSatisfy { !$0.hasSuffix(".partial") }, "temporary files cleaned")
        let entries = try await service.list(source, showHidden: false)
        try expect(entries.first?.isDirectory == true, "directories sorted first")
        _ = try await service.copy(file, into: source, duplicateInPlace: true, conflict: { _ in .replace }, progress: noProgress)
        try expect(read(file) == "new" && read(source.appendingPathComponent("hello 副本.txt")) == "new", "paste in place creates copy")
        _ = try await service.copy(nested, into: source, duplicateInPlace: true, conflict: { _ in .replace }, progress: noProgress)
        try expect(read(source.appendingPathComponent("folder 副本/child")) == "child", "paste directory in place")
        let fakeTrash = root.appendingPathComponent("trash")
        try fm.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let trashService = TrashService { url in
            if url.lastPathComponent == "hello.txt" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: fakeTrash.appendingPathComponent(url.lastPathComponent))
        }
        let disposable = source.appendingPathComponent("hello 副本.txt")
        let trashResult = await trashService.trash([file, disposable, disposable, nested])
        try expect(trashResult.completed.count == 2 && trashResult.failures.count == 1, "batch trash reports partial failure and deduplicates")
        try expect(read(file) == "new", "failed trash never permanently deletes")
        try expect(read(fakeTrash.appendingPathComponent("folder/child")) == "child", "trash directory retains children")
        let missing = await trashService.trash([disposable])
        try expect(missing.failures.count == 1, "missing trash item reported")
        print("All local transfer regressions passed.")
    }
    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(message: message) }
        print("PASS \(message)")
    }
    struct TestFailure: Error { let message: String }
}
