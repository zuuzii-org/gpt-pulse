import Foundation

struct CodexPaths: Sendable {
    let codexHome: URL
    let stateDatabaseCandidates: [URL]
    let appServerControlSocketURL: URL
    let sessionsDirectory: URL
    let sessionIndexURL: URL
    let pluginJournalURL: URL
    let receiptsDatabaseURL: URL

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexPaths {
        let codexHome: URL
        if let configuredHome = environment["CODEX_HOME"], !configuredHome.isEmpty {
            codexHome = URL(fileURLWithPath: configuredHome, isDirectory: true)
        } else {
            codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }

        let applicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support/GPT Pulse", isDirectory: true)

        let stateDatabaseCandidates = discoverStateDatabases(in: codexHome)

        return CodexPaths(
            codexHome: codexHome,
            stateDatabaseCandidates: stateDatabaseCandidates,
            appServerControlSocketURL: codexHome
                .appendingPathComponent("app-server-control", isDirectory: true)
                .appendingPathComponent("app-server-control.sock"),
            sessionsDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true),
            sessionIndexURL: codexHome.appendingPathComponent("session_index.jsonl"),
            pluginJournalURL: applicationSupport
                .appendingPathComponent("events", isDirectory: true)
                .appendingPathComponent("events.jsonl"),
            receiptsDatabaseURL: applicationSupport.appendingPathComponent("receipts.sqlite")
        )
    }

    static func discoverStateDatabases(in codexHome: URL) -> [URL] {
        let fileManager = FileManager.default
        let directories = [
            codexHome.appendingPathComponent("sqlite", isDirectory: true),
            codexHome,
        ]

        let matches = directories.flatMap { directory -> [(version: Int, url: URL)] in
            let urls = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            return urls.compactMap { url in
                guard let version = stateDatabaseVersion(for: url.lastPathComponent) else {
                    return nil
                }
                return (version, url)
            }
        }

        return matches
            .sorted {
                if $0.version == $1.version {
                    let leftActivity = databaseActivityDate(for: $0.url)
                    let rightActivity = databaseActivityDate(for: $1.url)
                    if leftActivity != rightActivity { return leftActivity > rightActivity }
                    return $0.url.path < $1.url.path
                }
                return $0.version > $1.version
            }
            .map(\.url)
    }

    private static func databaseActivityDate(for url: URL) -> Date {
        let fileManager = FileManager.default
        let relatedPaths = [url.path, url.path + "-wal", url.path + "-shm"]
        return relatedPaths.compactMap { path in
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            return attributes?[.modificationDate] as? Date
        }.max() ?? .distantPast
    }

    private static func stateDatabaseVersion(for filename: String) -> Int? {
        guard filename.hasPrefix("state_"), filename.hasSuffix(".sqlite") else {
            return nil
        }
        let start = filename.index(filename.startIndex, offsetBy: "state_".count)
        let end = filename.index(filename.endIndex, offsetBy: -".sqlite".count)
        return Int(filename[start..<end])
    }
}
