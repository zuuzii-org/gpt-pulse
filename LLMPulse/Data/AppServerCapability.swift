import Foundation

protocol CodexAppServerTaskProviding: Sendable {
    func loadDesktopRootTasks() async throws -> [RolloutTaskRecord]
}

struct AppServerCapabilityProbe: Sendable {
    let controlSocketURL: URL

    func health(now: Date = .now) -> AdapterHealth {
        guard FileManager.default.fileExists(atPath: controlSocketURL.path) else {
            return .unavailable(
                .appServer,
                message: "Codex Desktop has no managed app-server control socket"
            )
        }

        let attributes = try? FileManager.default.attributesOfItem(
            atPath: controlSocketURL.path
        )
        guard attributes?[.type] as? FileAttributeType == .typeSocket else {
            return .degraded(
                .appServer,
                message: "The app-server control path is not a Unix socket"
            )
        }

        return .degraded(
            .appServer,
            message: "Control socket detected; read-only proxy transport is not negotiated"
        )
    }
}
