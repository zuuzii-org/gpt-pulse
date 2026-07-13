import Foundation
import XCTest
@testable import LLMPulse

@MainActor
final class ModelSelectionStoreTests: XCTestCase {
    func testInitialEmptyHubPreservesPersistedSelection() {
        withDefaults { defaults in
            let secondary = secondaryIdentity()
            defaults.set(secondary.profileID.rawValue, forKey: ModelSelectionStore.preferenceKey)
            let store = ModelSelectionStore(defaults: defaults)

            store.reconcile(with: .empty)

            XCTAssertEqual(store.selectedProfileID, secondary.profileID)
            XCTAssertTrue(store.availableProfileIDs.isEmpty)
            XCTAssertEqual(
                defaults.string(forKey: ModelSelectionStore.preferenceKey),
                secondary.profileID.rawValue
            )
        }
    }

    func testMissingSelectionFallsBackToCodexEvenWhenItIsNotFirst() {
        withDefaults { defaults in
            defaults.set("missing-profile", forKey: ModelSelectionStore.preferenceKey)
            let store = ModelSelectionStore(defaults: defaults)
            let secondary = secondaryIdentity()

            store.reconcile(with: snapshot(identities: [secondary, .codex]))

            XCTAssertEqual(store.selectedProfileID, .codex)
            XCTAssertEqual(store.availableProfileIDs, [secondary.profileID, .codex])
            XCTAssertEqual(
                defaults.string(forKey: ModelSelectionStore.preferenceKey),
                ModelProfileID.codex.rawValue
            )
        }
    }

    func testMissingSelectionFallsBackToFirstProfileWhenCodexIsAbsent() {
        withDefaults { defaults in
            let max = secondaryIdentity()
            let plus = tertiaryIdentity()
            let store = ModelSelectionStore(defaults: defaults)

            store.reconcile(with: snapshot(identities: [plus, max]))

            XCTAssertEqual(store.selectedProfileID, plus.profileID)
            XCTAssertEqual(store.availableProfileIDs, [plus.profileID, max.profileID])
        }
    }

    func testSelectionPersistsAndRejectsUnavailableProfile() {
        withDefaults { defaults in
            let secondary = secondaryIdentity()
            let store = ModelSelectionStore(defaults: defaults)
            store.reconcile(with: snapshot(identities: [.codex, secondary]))

            XCTAssertTrue(store.select(secondary.profileID))
            XCTAssertEqual(store.selectedProfileID, secondary.profileID)
            XCTAssertEqual(
                defaults.string(forKey: ModelSelectionStore.preferenceKey),
                secondary.profileID.rawValue
            )

            XCTAssertFalse(store.select(ModelProfileID(rawValue: "not-available")))
            XCTAssertEqual(store.selectedProfileID, secondary.profileID)

            let reloaded = ModelSelectionStore(defaults: defaults)
            XCTAssertEqual(reloaded.selectedProfileID, secondary.profileID)
        }
    }

    func testAdjacentSelectionDoesNotWrapAtBoundaries() {
        withDefaults { defaults in
            let secondary = secondaryIdentity()
            let store = ModelSelectionStore(defaults: defaults)
            store.reconcile(with: snapshot(identities: [.codex, secondary]))

            XCTAssertFalse(store.selectAdjacent(.previous))
            XCTAssertEqual(store.selectedProfileID, .codex)
            XCTAssertTrue(store.selectAdjacent(.next))
            XCTAssertEqual(store.selectedProfileID, secondary.profileID)
            XCTAssertEqual(store.lastDirection, .next)
            XCTAssertFalse(store.selectAdjacent(.next))
            XCTAssertTrue(store.selectAdjacent(.previous))
            XCTAssertEqual(store.selectedProfileID, .codex)
            XCTAssertEqual(store.lastDirection, .previous)
        }
    }

    func testDirectSelectionTracksVisualTransitionDirection() {
        withDefaults { defaults in
            let max = secondaryIdentity()
            let plus = tertiaryIdentity()
            let store = ModelSelectionStore(defaults: defaults)
            store.reconcile(with: snapshot(identities: [.codex, max, plus]))

            XCTAssertTrue(store.select(plus.profileID))
            XCTAssertEqual(store.lastDirection, .next)
            XCTAssertTrue(store.select(max.profileID))
            XCTAssertEqual(store.lastDirection, .previous)
        }
    }

    func testDisappearingProfileFallsBackAndUpdatesAvailableOrder() {
        withDefaults { defaults in
            let secondary = secondaryIdentity()
            let plus = tertiaryIdentity()
            let store = ModelSelectionStore(defaults: defaults)
            store.reconcile(with: snapshot(identities: [.codex, secondary, plus]))
            XCTAssertTrue(store.select(plus.profileID))

            store.reconcile(with: snapshot(identities: [secondary, .codex]))

            XCTAssertEqual(store.selectedProfileID, .codex)
            XCTAssertEqual(store.availableProfileIDs, [secondary.profileID, .codex])
            XCTAssertEqual(store.lastDirection, .previous)
        }
    }

    func testFallbackRecomputesForwardTransitionDirection() {
        withDefaults { defaults in
            let secondary = secondaryIdentity()
            let plus = tertiaryIdentity()
            let store = ModelSelectionStore(defaults: defaults)
            store.reconcile(with: snapshot(identities: [.codex, secondary, plus]))
            XCTAssertTrue(store.select(secondary.profileID))
            XCTAssertTrue(store.select(.codex))
            XCTAssertEqual(store.lastDirection, .previous)

            store.reconcile(with: snapshot(identities: [secondary, plus]))

            XCTAssertEqual(store.selectedProfileID, secondary.profileID)
            XCTAssertEqual(store.lastDirection, .next)
        }
    }

    func testSelectionLockRejectsDirectAndAdjacentUserSelection() {
        withDefaults { defaults in
            let secondary = secondaryIdentity()
            let store = ModelSelectionStore(defaults: defaults)
            store.reconcile(with: snapshot(identities: [.codex, secondary]))
            store.setSelectionLocked(true)

            XCTAssertFalse(store.select(secondary.profileID))
            XCTAssertFalse(store.selectAdjacent(.next))
            XCTAssertEqual(store.selectedProfileID, .codex)

            store.setSelectionLocked(false)
            XCTAssertTrue(store.selectAdjacent(.next))
            XCTAssertEqual(store.selectedProfileID, secondary.profileID)
        }
    }

    func testSelectionLockDefersLatestReconciliationUntilUnlock() {
        withDefaults { defaults in
            let secondary = secondaryIdentity()
            let plus = tertiaryIdentity()
            let store = ModelSelectionStore(defaults: defaults)
            store.reconcile(with: snapshot(identities: [.codex, secondary, plus]))
            XCTAssertTrue(store.select(plus.profileID))

            store.setSelectionLocked(true)
            store.reconcile(with: snapshot(identities: [secondary, .codex]))
            store.reconcile(with: snapshot(identities: [.codex]))

            XCTAssertEqual(store.selectedProfileID, plus.profileID)
            XCTAssertEqual(store.availableProfileIDs, [.codex, secondary.profileID, plus.profileID])
            XCTAssertEqual(store.lastChangeOrigin, .userInitiated)

            store.setSelectionLocked(false)

            XCTAssertEqual(store.selectedProfileID, .codex)
            XCTAssertEqual(store.availableProfileIDs, [.codex])
            XCTAssertEqual(store.lastChangeOrigin, .automatic)
            XCTAssertEqual(store.lastDirection, .previous)
        }
    }

    func testPageAnnouncementPolicyRequiresVisibleUserInitiatedChange() {
        XCTAssertTrue(ModelPageAccessibility.shouldAnnouncePageChange(
            previousProfileID: .codex,
            origin: .userInitiated,
            isPanelVisible: true
        ))
        XCTAssertFalse(ModelPageAccessibility.shouldAnnouncePageChange(
            previousProfileID: .codex,
            origin: .automatic,
            isPanelVisible: true
        ))
        XCTAssertFalse(ModelPageAccessibility.shouldAnnouncePageChange(
            previousProfileID: .codex,
            origin: .userInitiated,
            isPanelVisible: false
        ))
        XCTAssertFalse(ModelPageAccessibility.shouldAnnouncePageChange(
            previousProfileID: nil,
            origin: .userInitiated,
            isPanelVisible: true
        ))
    }

    private func withDefaults(_ operation: (UserDefaults) -> Void) {
        let suiteName = "ModelSelectionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        operation(defaults)
    }

    private func snapshot(identities: [ModelIdentity]) -> PulseHubSnapshot {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return PulseHubSnapshot(
            models: identities.map {
                ModelTaskSnapshot(
                    identity: $0,
                    tasks: [],
                    health: [],
                    refreshedAt: now
                )
            },
            refreshedAt: now
        )
    }

    private func secondaryIdentity() -> ModelIdentity {
        ModelIdentity(
            runtime: AIRuntimeID(rawValue: "test-runtime"),
            provider: AIProviderID(rawValue: "test-provider"),
            modelID: "test-model",
            displayName: "Secondary3.7 Max",
            planKind: ModelPlanKind(rawValue: "test-plan-a")
        )!
    }

    private func tertiaryIdentity() -> ModelIdentity {
        ModelIdentity(
            runtime: AIRuntimeID(rawValue: "test-runtime"),
            provider: AIProviderID(rawValue: "test-provider"),
            modelID: "test-model-plus",
            displayName: "Secondary3.7 Plus",
            planKind: ModelPlanKind(rawValue: "test-plan-b")
        )!
    }
}

