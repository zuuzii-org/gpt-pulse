import Foundation

struct ModelSourceID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(singleProfile profileID: ModelProfileID) {
        rawValue = "model-profile:\(profileID.rawValue)"
    }
}

struct ModelSourceSnapshot: Equatable, Sendable {
    let sourceID: ModelSourceID
    let models: [ModelTaskSnapshot]
    let refreshedAt: Date
}

protocol ModelSnapshotSourceProtocol: Sendable {
    var sourceID: ModelSourceID { get }

    /// Stable identities that can represent this source before its first
    /// successful refresh. Dynamic sources may leave this empty.
    var fallbackIdentities: [ModelIdentity] { get }

    func snapshot(now: Date) async -> ModelSourceSnapshot
}

extension ModelSnapshotSourceProtocol {
    var fallbackIdentities: [ModelIdentity] { [] }
}

protocol ModelTaskRepositoryProtocol: Sendable {
    var identity: ModelIdentity { get }
    func snapshot(now: Date) async -> ModelTaskSnapshot
}

extension ModelTaskRepositoryProtocol {
    var profileID: ModelProfileID { identity.profileID }
}

struct SingleModelSourceAdapter: ModelSnapshotSourceProtocol {
    let sourceID: ModelSourceID
    let fallbackIdentities: [ModelIdentity]

    private let repository: any ModelTaskRepositoryProtocol
    private let identity: ModelIdentity

    init(
        repository: any ModelTaskRepositoryProtocol,
        sourceID: ModelSourceID? = nil
    ) {
        self.repository = repository
        identity = repository.identity
        self.sourceID = sourceID ?? ModelSourceID(
            singleProfile: repository.identity.profileID
        )
        fallbackIdentities = [repository.identity]
    }

    func snapshot(now: Date) async -> ModelSourceSnapshot {
        let model = await repository.snapshot(now: now)
        let validatedModel: ModelTaskSnapshot
        if model.identity == identity {
            validatedModel = model
        } else {
            validatedModel = ModelTaskSnapshot(
                identity: identity,
                tasks: [],
                health: [.unavailable(
                    .runtimeSource,
                    message: "Model source returned an unexpected identity"
                )],
                refreshedAt: now
            )
        }
        return ModelSourceSnapshot(
            sourceID: sourceID,
            models: [validatedModel],
            refreshedAt: validatedModel.refreshedAt
        )
    }
}

protocol PulseHubRepositoryProtocol: Sendable {
    func snapshot(now: Date) async -> PulseHubSnapshot
    func markViewed(_ tasks: [PulseTask], at date: Date) async throws
    func unmarkViewed(_ tasks: [PulseTask]) async throws
}
