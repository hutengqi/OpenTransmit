import Foundation
import Observation

@MainActor @Observable final class TransferStore {
    var jobs: [TransferJob] = []
    var conflict: FileConflict?
    var applyToRemaining = false
    var running = false
    var deleting = false
    private var continuation: CheckedContinuation<ConflictChoice, Never>?
    private var batchChoice: ConflictChoice?
    private var task: Task<Void, Never>?
    private let service = LocalFileService()
    private let remoteEngine = EndpointTransferEngine(endpoint: SFTPRegistry.shared)
    var onChange: (() -> Void)?

    func enqueue(_ urls: [URL], to destination: URL, duplicateInPlace: Bool = false) {
        guard !deleting else { return }
        for source in urls where source.isTransferLocation {
            if source.isFileURL { _ = source.startAccessingSecurityScopedResource() }
            jobs.append(TransferJob(source: source, destination: destination, duplicateInPlace: duplicateInPlace))
        }
        guard !running, jobs.contains(where: { !$0.finished }) else { return }
        running = true
        batchChoice = nil
        task = Task { await runQueue() }
    }
    private func runQueue() async {
        while let index = jobs.firstIndex(where: { !$0.finished }) {
            if Task.isCancelled { break }
            jobs[index].status = "正在复制"
            let job = jobs[index]
            do {
                let decide: @Sendable (FileConflict) async -> ConflictChoice = { [weak self] item in
                    guard let self else { return .cancel }
                    return await self.ask(item)
                }
                let progress: @Sendable (Int64) async -> Void = { [weak self] count in
                    await self?.addProgress(count, id: job.id)
                }
                let complete: Bool
                if job.source.isFileURL && job.destination.isFileURL {
                    complete = try await service.copy(job.source, into: job.destination, duplicateInPlace: job.duplicateInPlace, conflict: decide, progress: progress)
                } else {
                    complete = try await remoteEngine.copy(job.source, into: job.destination, duplicateInPlace: job.duplicateInPlace, conflict: decide, progress: progress)
                }
                jobs[index].status = complete ? "已完成" : "已完成（含跳过）"
            } catch is CancellationError {
                jobs[index].status = "已取消（已完成的文件保留）"
            } catch {
                jobs[index].status = Task.isCancelled ? "已取消（已完成的文件保留）" : error.transferDescription
                jobs[index].failed = !Task.isCancelled
            }
            jobs[index].finished = true
            onChange?()
        }
        if Task.isCancelled {
            for index in jobs.indices where !jobs[index].finished {
                jobs[index].finished = true
                jobs[index].status = "已取消"
            }
        }
        running = false
        task = nil
        batchChoice = nil
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
    func retry(_ job: TransferJob) { enqueue([job.source], to: job.destination, duplicateInPlace: job.duplicateInPlace) }
}
