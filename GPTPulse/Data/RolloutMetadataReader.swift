import Foundation

struct RolloutMetadataReader: Sendable {
    private let maximumFirstLineBytes: Int

    init(maximumFirstLineBytes: Int = 4 * 1_024 * 1_024) {
        self.maximumFirstLineBytes = maximumFirstLineBytes
    }

    func readDesktopRoot(from url: URL) throws -> RolloutMetadata? {
        let line = try readFirstLine(from: url)
        guard let object = JSONValueSupport.object(from: line) else {
            throw DataAdapterError.invalidFormat(url, "first line is not a JSON object")
        }
        guard object["type"] as? String == "session_meta" else {
            throw DataAdapterError.invalidFormat(url, "first event is not session_meta")
        }
        guard let payload = object["payload"] as? [String: Any] else {
            throw DataAdapterError.invalidFormat(url, "session_meta payload is missing")
        }

        guard
            payload["originator"] as? String == "Codex Desktop",
            payload["source"] as? String == "vscode",
            payload["thread_source"] as? String == "user",
            JSONValueSupport.string(payload["parent_thread_id"]) == nil
        else {
            return nil
        }

        guard
            let threadId = JSONValueSupport.string(payload["id"])
                ?? JSONValueSupport.string(payload["session_id"])
        else {
            throw DataAdapterError.invalidFormat(url, "session id is missing")
        }

        let resourceValues = try? url.resourceValues(forKeys: [
            .creationDateKey,
            .contentModificationDateKey,
        ])
        let createdAt = JSONValueSupport.date(payload["timestamp"])
            ?? JSONValueSupport.date(object["timestamp"])
            ?? resourceValues?.creationDate
            ?? resourceValues?.contentModificationDate
            ?? .distantPast

        return RolloutMetadata(
            threadId: threadId,
            rolloutURL: url,
            projectDirectory: JSONValueSupport.string(payload["cwd"]) ?? "",
            createdAt: createdAt
        )
    }

    private func readFirstLine(from url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DataAdapterError.missingFile(url)
        }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        var accumulated = Data()
        let chunkSize = 64 * 1_024

        while accumulated.count < maximumFirstLineBytes {
            let remaining = min(chunkSize, maximumFirstLineBytes - accumulated.count)
            guard let chunk = try file.read(upToCount: remaining), !chunk.isEmpty else {
                break
            }
            accumulated.append(chunk)
            if let newline = accumulated.firstIndex(of: 0x0A) {
                return Data(accumulated[..<newline])
            }
        }

        guard !accumulated.isEmpty, accumulated.count < maximumFirstLineBytes else {
            throw DataAdapterError.invalidFormat(url, "session_meta exceeds the read limit")
        }
        return accumulated
    }
}
