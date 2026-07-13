import Foundation
import ServiceManagement

enum LaunchAtLoginRegistrationState: String, Codable, Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var shouldRemainRegistered: Bool {
        self == .enabled || self == .requiresApproval
    }
}

@MainActor
protocol LaunchAtLoginMigrationManaging: AnyObject {
    var migrationRegistrationState: LaunchAtLoginRegistrationState { get }

    func unregisterForBundleNameMigration(
        preserving previousState: LaunchAtLoginRegistrationState
    ) async throws

    func restoreAfterBundleNameMigration(
        from previousState: LaunchAtLoginRegistrationState
    ) async throws
}

@MainActor
final class LaunchAtLoginService: ObservableObject, LaunchAtLoginMigrationManaging {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    var migrationRegistrationState: LaunchAtLoginRegistrationState {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func setEnabled(_ enabled: Bool) async {
        errorMessage = nil

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        refresh()
    }

    func unregisterForBundleNameMigration(
        preserving previousState: LaunchAtLoginRegistrationState
    ) async throws {
        guard previousState.shouldRemainRegistered,
              migrationRegistrationState.shouldRemainRegistered else {
            return
        }

        try await SMAppService.mainApp.unregister()
        refresh()
    }

    func restoreAfterBundleNameMigration(
        from previousState: LaunchAtLoginRegistrationState
    ) async throws {
        guard previousState.shouldRemainRegistered else {
            refresh()
            return
        }

        refresh()
        guard !migrationRegistrationState.shouldRemainRegistered else { return }

        do {
            try SMAppService.mainApp.register()
        } catch {
            // Registration can report an error after System Settings has already
            // accepted the new path. Treat a converged status as success.
            refresh()
            guard migrationRegistrationState.shouldRemainRegistered else {
                throw error
            }
            return
        }

        refresh()
    }
}
