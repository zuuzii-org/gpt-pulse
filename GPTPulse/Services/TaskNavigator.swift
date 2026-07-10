import AppKit
import Foundation

@MainActor
final class TaskNavigator {
    typealias OpenHandler = @MainActor (URL) -> Bool

    private let openHandler: OpenHandler

    init(openHandler: @escaping OpenHandler = { NSWorkspace.shared.open($0) }) {
        self.openHandler = openHandler
    }

    @discardableResult
    func open(threadID: String) -> Bool {
        guard let url = Self.taskURL(threadID: threadID) else { return false }
        return openHandler(url)
    }

    static func taskURL(threadID: String) -> URL? {
        let trimmedID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              !trimmedID.contains("/"),
              !trimmedID.contains("\\") else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(trimmedID)"
        return components.url
    }
}
