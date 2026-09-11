import Foundation

@main struct SFTPIntegrationTests {
    struct Configuration: Decodable {
        let portA: Int; let portB: Int; let hostKeyA: String; let hostKeyB: String
        let password: String; let privateKey: String; let root: String
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let localRoot = URL(fileURLWithPath: config.root)
        let registry = SFTPRegistry.shared
        let engine = EndpointTransferEngine(endpoint: registry)
        var a = ServerProfile(); a.name = "fixture-A"; a.host = "127.0.0.1"; a.port = config.portA; a.username = "test"; a.directory = "/"
        var b = a; b.id = UUID(); b.name = "fixture-B"; b.port = config.portB
        var password = SSHCredentials(); password.password = config.password
        do {
            _ = try await registry.connect(a, credentials: password, trustedKey: nil)
            throw TransferFailure(message: "Untrusted host was accepted")
        } catch let challenge as HostKeyChallenge { check(!challenge.changed && challenge.key == config.hostKeyA, "unknown host rejected before trust") }
        do {
            _ = try await registry.connect(a, credentials: password, trustedKey: config.hostKeyB)
            throw TransferFailure(message: "Changed host accepted")
        } catch let challenge as HostKeyChallenge { check(challenge.changed, "changed host rejected") }
        var wrong = password; wrong.password = "incorrect-fixture-password"
        do {
            _ = try await registry.connect(a, credentials: wrong, trustedKey: config.hostKeyA)
            fatalError("Wrong password accepted")
        } catch { print("PASS wrong password rejected") }
        let remoteA = try await registry.connect(a, credentials: password, trustedKey: config.hostKeyA)
        var key = SSHCredentials(); key.method = .ed25519; key.privateKey = try String(contentsOfFile: config.privateKey, encoding: .utf8)
        let remoteB = try await registry.connect(b, credentials: key, trustedKey: config.hostKeyB)
        print("PASS password and Ed25519 authentication")
        let source = localRoot.appendingPathComponent("source")
        let output = localRoot.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = source.appendingPathComponent("中文 空格 % # 目录")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Data((0..<(180 * 1024)).map { UInt8($0 % 251) })
        try payload.write(to: directory.appendingPathComponent("内容 ' \" %.bin"))
        try Data().write(to: directory.appendingPathComponent("empty"))
        let replace: @Sendable (FileConflict) async -> ConflictChoice = { _ in .replace }
        let progress: @Sendable (Int64) async -> Void = { _ in }
        _ = try await engine.copy(directory, into: remoteA, conflict: replace, progress: progress)
        let aDirectory = remoteA.appendingPathComponent(directory.lastPathComponent)
        let listed = try await registry.children(aDirectory)
        check(listed.count == 2, "upload directory and list special filenames")
        _ = try await engine.copy(aDirectory, into: output, conflict: replace, progress: progress)
        check(try Data(contentsOf: output.appendingPathComponent(directory.lastPathComponent).appendingPathComponent("内容 ' \" %.bin")) == payload, "download byte equality")
        _ = try await engine.copy(aDirectory, into: remoteB, conflict: replace, progress: progress)
        let bDirectory = remoteB.appendingPathComponent(directory.lastPathComponent)
        let secondOutput = localRoot.appendingPathComponent("relay-download")
        try FileManager.default.createDirectory(at: secondOutput, withIntermediateDirectories: true)
        _ = try await engine.copy(bDirectory, into: secondOutput, conflict: replace, progress: progress)
        check(try Data(contentsOf: secondOutput.appendingPathComponent(directory.lastPathComponent).appendingPathComponent("内容 ' \" %.bin")) == payload, "server A to B streamed relay byte equality")
        let file = directory.appendingPathComponent("empty")
        _ = try await engine.copy(file, into: remoteA, conflict: replace, progress: progress)
        try Data("replacement".utf8).write(to: file)
        _ = try await engine.copy(file, into: remoteA, conflict: { _ in .skip }, progress: progress)
        check(try await registry.entry(remoteA.appendingPathComponent("empty"))?.size == 0, "remote skip preserves file")
        _ = try await engine.copy(file, into: remoteA, conflict: { _ in .keepBoth }, progress: progress)
        check(try await registry.entry(remoteA.appendingPathComponent("empty 副本"))?.size == 11, "remote keep both")
        _ = try await engine.copy(file, into: remoteA, conflict: replace, progress: progress)
        check(try await registry.entry(remoteA.appendingPathComponent("empty"))?.size == 11, "staged remote replacement")
        let rootItems = try await registry.children(remoteA)
        check(!rootItems.contains { $0.name.hasPrefix(".opentransmit-") }, "remote staging and backup cleanup")
        // A different session to the same host must still reject copying a directory into itself.
        let aliasA = try await registry.connect(a, credentials: password, trustedKey: config.hostKeyA)
        do {
            _ = try await engine.copy(aDirectory, into: aliasA, conflict: replace, progress: progress)
            fatalError("same server alias copied into itself")
        } catch { print("PASS same server separate session self-copy rejected") }
        let many = try await registry.children(remoteA.appendingPathComponent("many"))
        check(many.count == 150, "multi-packet directory listing")
        do {
            _ = try await engine.copy(remoteA.appendingPathComponent("link"), into: output, conflict: replace, progress: progress)
            fatalError("symlink transferred")
        } catch { print("PASS remote symlink rejected") }
        do {
            _ = try await engine.copy(file, into: remoteA.appendingPathComponent("denied"), conflict: replace, progress: progress)
            fatalError("permission failure swallowed")
        } catch { print("PASS permission denied reported") }
        let failCommit = source.appendingPathComponent("fail-commit")
        try Data("new-data".utf8).write(to: failCommit)
        do {
            _ = try await engine.copy(failCommit, into: remoteA, conflict: replace, progress: progress)
            fatalError("commit failure ignored")
        } catch { print("PASS failed remote commit reported") }
        _ = try await engine.copy(remoteA.appendingPathComponent("fail-commit"), into: output, conflict: replace, progress: progress)
        check(try String(contentsOf: output.appendingPathComponent("fail-commit"), encoding: .utf8) == "original-backup", "remote commit rollback preserves original")
        let afterRollback = try await registry.children(remoteA)
        check(!afterRollback.contains { $0.name.hasPrefix(".opentransmit-") }, "rollback cleans staging and backup")
        let cancelSource = source.appendingPathComponent("cancel.bin")
        try Data(repeating: 3, count: 4 * 1024 * 1024).write(to: cancelSource)
        do {
            _ = try await engine.copy(cancelSource, into: remoteB, conflict: replace, progress: { _ in withUnsafeCurrentTask { $0?.cancel() } })
            fatalError("cancellation ignored")
        } catch { print("PASS mid-stream cancellation") }
        // Cancellation above affects the current task; cleanup and assertions run in an independent task.
        try await Task.detached {
            let items = try await registry.children(remoteB)
            check(!items.contains { $0.name == "cancel.bin" }, "cancel never publishes partial target")
            check(!items.contains { $0.name.hasPrefix(".opentransmit-") }, "cancel cleans remote staging")
            await registry.disconnect(remoteA); await registry.disconnect(remoteB); await registry.disconnect(aliasA)
        }.value
        print("All SFTP integration checks passed.")
    }
    static func check(_ success: Bool, _ label: String) {
        precondition(success, label)
        print("PASS \(label)")
    }
}
