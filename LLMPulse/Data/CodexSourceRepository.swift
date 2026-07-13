import Foundation

struct CodexSourceRepository: ModelTaskRepositoryProtocol {
    let identity = ModelIdentity.codex

    private let repository: any TaskRepositoryProtocol

    init(repository: any TaskRepositoryProtocol) {
        self.repository = repository
    }

    func snapshot(now: Date) async -> ModelTaskSnapshot {
        ModelTaskSnapshot(codex: await repository.snapshot(now: now))
    }
}
