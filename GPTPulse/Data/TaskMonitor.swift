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
        Task { [weak self, repository] in
            do {
                try await repository.markViewed(task, at: .now)
                await self?.performRefresh()
            } catch {
                // The next regular refresh exposes receipt-store health without
                // risking a write anywhere inside CODEX_HOME.
            }
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
