import Combine
import Foundation

@MainActor
final class TaskMonitor: ObservableObject {
    @Published private(set) var snapshot: TaskSnapshot

    private let repository: any TaskRepositoryProtocol
    private let refreshInterval: Duration
    private var pollingTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    init(
        repository: any TaskRepositoryProtocol,
        refreshInterval: Duration = .milliseconds(750),
        initialSnapshot: TaskSnapshot = .empty
    ) {
        self.repository = repository
        self.refreshInterval = refreshInterval
        snapshot = initialSnapshot
    }

    static func makeLive(
        refreshInterval: Duration = .milliseconds(750)
    ) -> TaskMonitor {
        TaskMonitor(
            repository: TaskRepository.live(),
            refreshInterval: refreshInterval
        )
    }

    func start() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.performRefresh()
                do {
                    try await Task.sleep(for: self.refreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh() {
        Task { [weak self] in
            await self?.performRefresh()
        }
    }

    func markViewed(task: PulseTask) {
        markViewed(tasks: [task])
    }

    func markViewed(tasks: [PulseTask]) {
        guard !tasks.isEmpty else { return }
        Task { [weak self] in
            _ = await self?.markViewedAndRefresh(tasks: tasks)
        }
    }

    func markViewedAndRefresh(tasks: [PulseTask]) async -> Bool {
        guard !tasks.isEmpty else { return true }
        do {
            try await repository.markViewed(tasks, at: .now)
            await performRefresh()
            return true
        } catch {
            // The next regular refresh exposes receipt-store health without
            // risking a write anywhere inside CODEX_HOME.
            return false
        }
    }

    func unmarkViewed(task: PulseTask) {
        unmarkViewed(tasks: [task])
    }

    func unmarkViewed(tasks: [PulseTask]) {
        guard !tasks.isEmpty else { return }
        Task { [weak self] in
            _ = await self?.unmarkViewedAndRefresh(tasks: tasks)
        }
    }

    func unmarkViewedAndRefresh(tasks: [PulseTask]) async -> Bool {
        guard !tasks.isEmpty else { return true }
        do {
            try await repository.unmarkViewed(tasks)
            await performRefresh()
            return true
        } catch {
            // Keep the current snapshot stable. The next regular refresh
            // reports receipt-store health after the failed mutation.
            return false
        }
    }

    private func performRefresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let nextSnapshot = await repository.snapshot(now: .now)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        snapshot = nextSnapshot
    }
}
