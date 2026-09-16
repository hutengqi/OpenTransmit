import Foundation
import Observation

@MainActor @Observable final class TransferStore {
    private let defaults: UserDefaults
    var jobs: [TransferJob] = []
    var recoveryMessage: String?
    var savedTasks: [SavedTransferTask] = [] {
        didSet {
            do { defaults.set(try JSONEncoder().encode(savedTasks), forKey: "transferRecovery.v1") }
            catch { recoveryMessage = "无法保存任务清单：\(error.localizedDescription)" }
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "transferRecovery.v1") {
            do { savedTasks = try JSONDecoder().decode([SavedTransferTask].self, from: data) }
            catch { recoveryMessage = "无法读取待恢复任务：\(error.localizedDescription)" }
        }
    }
    var orphanedTasks: [SavedTransferTask] { savedTasks.filter { saved in !jobs.contains { $0.id == saved.id || $0.recoveryID == saved.id } } }
    private var recoveringIDs: Set<UUID> = []
    func recover(_ saved: SavedTransferTask) {
        guard !deleting, !recoveringIDs.contains(saved.id), !jobs.contains(where: { !$0.finished && ($0.id == saved.id || $0.recoveryID == saved.id) }) else { return }
        recoveringIDs.insert(saved.id)
        Task {
            defer { recoveringIDs.remove(saved.id) }
            do {
                let source = try await saved.source.resolve()
                let destination = try await saved.destination.resolve()
                guard !deleting else { return }
                enqueue([source], to: destination, duplicateInPlace: saved.duplicateInPlace, moving: saved.moving ?? false, recoveryID: saved.id)
                recoveryMessage = nil
            } catch { recoveryMessage = error.transferDescription }
        }
    }
    private func savePendingTasks() async {
        for job in jobs where !job.finished && job.recoveryID == nil && !savedTasks.contains(where: { $0.id == job.id }) {
            do {
                let source = try await SavedTransferLocation.capture(job.source)
                let destination = try await SavedTransferLocation.capture(job.destination)
                if jobs.contains(where: { $0.id == job.id && (!$0.finished || $0.failed || $0.cancelled) }), !savedTasks.contains(where: { $0.id == job.id }) {
                    savedTasks.append(SavedTransferTask(id: job.id, source: source, destination: destination, duplicateInPlace: job.duplicateInPlace, moving: job.moving))
                }
            } catch { recoveryMessage = "部分任务无法持久化，退出后不能恢复：\(error.transferDescription)" }
        }
    }
    var conflict: FileConflict?
    var applyToRemaining = false
    var running = false
    var deleting = false
    private var continuation: CheckedContinuation<ConflictChoice, Never>?
    private var batchChoice: ConflictChoice?
    private var task: Task<Void, Never>?
    private let remoteEngine = EndpointTransferEngine(endpoint: SFTPRegistry.shared)
    var onChange: (() -> Void)?

    func editItem(at location: URL, name: String, rename: Bool) async throws {
        guard !running, !deleting else { throw TransferFailure(message: "请等待传输或文件操作结束。") }
        deleting = true
        defer { deleting = false; onChange?() }
        if rename { try await SFTPRegistry.shared.renameItem(location, name: name) }
        else { try await SFTPRegistry.shared.createNamedDirectory(in: location, name: name) }
    }
    func enqueue(_ urls: [URL], to destination: URL, duplicateInPlace: Bool = false, moving: Bool = false, recoveryID: UUID? = nil) {
        guard !deleting else { return }
        for source in urls where source.isTransferLocation {
            if source.isFileURL { _ = source.startAccessingSecurityScopedResource() }
            jobs.append(TransferJob(source: source, destination: destination, duplicateInPlace: duplicateInPlace, moving: moving, recoveryID: recoveryID))
        }
        Task { await savePendingTasks() }
        guard !running, jobs.contains(where: { !$0.finished }) else { return }
        running = true
        batchChoice = nil
        task = Task { await runQueue() }
    }
    private func runQueue() async {
        await savePendingTasks()
        while let index = jobs.firstIndex(where: { !$0.finished }) {
            if Task.isCancelled { break }
            jobs[index].status = "正在统计源文件…"
            let job = jobs[index]
            do {
                let decide: @Sendable (FileConflict) async -> ConflictChoice = { [weak self] item in
                    guard let self else { return .cancel }
                    return await self.ask(item)
                }
                let progress: @Sendable (Int64) async -> Void = { [weak self] count in
                    await self?.addProgress(count, id: job.id)
                }
                jobs[index].totalBytes = try await remoteEngine.totalBytes(job.source)
                jobs[index].startedAt = Date()
                jobs[index].status = job.moving ? "移动中（写入后移除源文件）" : "传输与提交中"
                let complete = try await remoteEngine.copy(job.source, into: job.destination, duplicateInPlace: job.duplicateInPlace, moving: job.moving, conflict: decide, progress: progress, warning: { [weak self] warning in
                    await self?.addWarning(warning, id: job.id)
                })
                jobs[index].status = complete ? "已完成" : "已完成（含跳过）"
            } catch is CancellationError {
                jobs[index].cancelled = true
                jobs[index].status = "已取消（已完成的文件保留）"
            } catch {
                jobs[index].status = Task.isCancelled ? "已取消（已完成的文件保留）" : error.transferDescription
                jobs[index].failed = !Task.isCancelled
                jobs[index].cancelled = Task.isCancelled
            }
            jobs[index].finished = true
            jobs[index].endedAt = Date()
            if !jobs[index].failed && !jobs[index].cancelled { savedTasks.removeAll { $0.id == job.id || $0.id == job.recoveryID } }
            onChange?()
        }
        if Task.isCancelled {
            for index in jobs.indices where !jobs[index].finished {
                jobs[index].finished = true
                jobs[index].status = "已取消"
                jobs[index].cancelled = true
                jobs[index].endedAt = Date()
            }
        }
        running = false
        task = nil
        batchChoice = nil
    }
    private func addWarning(_ warning: String, id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].warnings.count < 20 { jobs[index].warnings.append(warning) }
    }
    private func addProgress(_ count: Int64, id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].bytes += count }
    }
    private func ask(_ item: FileConflict) async -> ConflictChoice {
        if Task.isCancelled { return .cancel }
        if let batchChoice { return batchChoice }
        applyToRemaining = false
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            conflict = item
        }
    }
    func resolve(_ choice: ConflictChoice) {
        if applyToRemaining && choice != .cancel { batchChoice = choice }
        conflict = nil
        let pending = continuation
        continuation = nil
        if choice == .cancel { task?.cancel() }
        pending?.resume(returning: choice)
    }
    func cancel() { task?.cancel(); if continuation != nil { resolve(.cancel) } }
    func retry(_ job: TransferJob) {
        guard !deleting else { return }
        if let saved = savedTasks.first(where: { $0.id == job.id || $0.id == job.recoveryID }) { recover(saved) }
        else { enqueue([job.source], to: job.destination, duplicateInPlace: job.duplicateInPlace, moving: job.moving) }
    }
}
