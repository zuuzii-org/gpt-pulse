import Combine
import Foundation

enum ModelSelectionDirection: Equatable, Sendable {
    case previous
    case next

    fileprivate var offset: Int {
        switch self {
        case .previous: -1
        case .next: 1
        }
    }
}

enum ModelSelectionOrigin: Equatable, Sendable {
    case userInitiated
    case automatic
}

@MainActor
final class ModelSelectionStore: ObservableObject {
    static let preferenceKey = "selectedModelProfileID"

    @Published private(set) var selectedProfileID: ModelProfileID?
    @Published private(set) var isSelectionLocked = false
    private(set) var availableProfileIDs: [ModelProfileID] = []
    private(set) var lastDirection: ModelSelectionDirection = .next
    private(set) var lastChangeOrigin: ModelSelectionOrigin = .automatic

    private let defaults: UserDefaults
    private let preferenceKey: String
    private var deferredSnapshot: PulseHubSnapshot?

    init(
        defaults: UserDefaults = .standard,
        preferenceKey: String = ModelSelectionStore.preferenceKey
    ) {
        self.defaults = defaults
        self.preferenceKey = preferenceKey
        selectedProfileID = defaults.string(forKey: preferenceKey).flatMap { rawValue in
            rawValue.isEmpty ? nil : ModelProfileID(rawValue: rawValue)
        }
    }

    /// Reconciles persisted selection against the current Hub model order.
    /// An empty initial snapshot deliberately leaves the persisted value alone.
    func reconcile(with snapshot: PulseHubSnapshot) {
        guard !isSelectionLocked else {
            deferredSnapshot = snapshot
            return
        }
        let previousProfileIDs = availableProfileIDs
        let previousSelection = selectedProfileID
        let profileIDs = snapshot.models.map(\.identity.profileID)
        availableProfileIDs = profileIDs
        guard !profileIDs.isEmpty else { return }

        if let selectedProfileID, profileIDs.contains(selectedProfileID) {
            return
        }

        let fallback = profileIDs.contains(.codex) ? ModelProfileID.codex : profileIDs[0]
        updateFallbackDirection(
            from: previousSelection,
            to: fallback,
            previousProfileIDs: previousProfileIDs
        )
        updateSelection(fallback, origin: .automatic)
    }

    /// Temporarily prevents user selection and defers Hub reconciliation so a
    /// receipt mutation can finish against one stable profile.
    func setSelectionLocked(_ isLocked: Bool) {
        guard isSelectionLocked != isLocked else { return }
        isSelectionLocked = isLocked
        guard !isLocked, let deferredSnapshot else { return }
        self.deferredSnapshot = nil
        reconcile(with: deferredSnapshot)
    }

    @discardableResult
    func select(
        _ profileID: ModelProfileID,
        origin: ModelSelectionOrigin = .userInitiated
    ) -> Bool {
        guard !isSelectionLocked else { return false }
        guard availableProfileIDs.contains(profileID) else { return false }
        if let selectedProfileID,
           let currentIndex = availableProfileIDs.firstIndex(of: selectedProfileID),
           let targetIndex = availableProfileIDs.firstIndex(of: profileID),
           currentIndex != targetIndex {
            lastDirection = targetIndex < currentIndex ? .previous : .next
        }
        updateSelection(profileID, origin: origin)
        return true
    }

    /// Selects an adjacent profile without wrapping at either boundary.
    @discardableResult
    func selectAdjacent(_ direction: ModelSelectionDirection) -> Bool {
        guard !isSelectionLocked else { return false }
        guard !availableProfileIDs.isEmpty else { return false }
        guard let selectedProfileID,
              let currentIndex = availableProfileIDs.firstIndex(of: selectedProfileID)
        else {
            let fallback = availableProfileIDs.contains(.codex)
                ? ModelProfileID.codex
                : availableProfileIDs[0]
            updateSelection(fallback, origin: .userInitiated)
            return true
        }

        let targetIndex = currentIndex + direction.offset
        guard availableProfileIDs.indices.contains(targetIndex) else { return false }
        lastDirection = direction
        updateSelection(availableProfileIDs[targetIndex], origin: .userInitiated)
        return true
    }

    private func updateFallbackDirection(
        from previousSelection: ModelProfileID?,
        to fallback: ModelProfileID,
        previousProfileIDs: [ModelProfileID]
    ) {
        guard let previousSelection,
              previousSelection != fallback,
              let previousIndex = previousProfileIDs.firstIndex(of: previousSelection)
        else {
            return
        }

        if let fallbackIndex = previousProfileIDs.firstIndex(of: fallback) {
            lastDirection = fallbackIndex < previousIndex ? .previous : .next
            return
        }

        guard let fallbackIndex = availableProfileIDs.firstIndex(of: fallback) else {
            return
        }
        let projectedPreviousIndex = min(previousIndex, availableProfileIDs.count - 1)
        if fallbackIndex != projectedPreviousIndex {
            lastDirection = fallbackIndex < projectedPreviousIndex ? .previous : .next
        } else if previousIndex >= availableProfileIDs.count {
            lastDirection = .previous
        }
    }

    private func updateSelection(
        _ profileID: ModelProfileID,
        origin: ModelSelectionOrigin
    ) {
        guard selectedProfileID != profileID else { return }
        lastChangeOrigin = origin
        selectedProfileID = profileID
        defaults.set(profileID.rawValue, forKey: preferenceKey)
    }
}
