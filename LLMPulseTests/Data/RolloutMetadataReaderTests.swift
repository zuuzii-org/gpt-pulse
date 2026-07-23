import Foundation
import XCTest
@testable import LLMPulse

final class RolloutMetadataReaderTests: XCTestCase {
    func testAcceptsSupportedCodexDesktopUserRootsOnly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let desktopURL = directory.appendingPathComponent("desktop.jsonl")
        try writeMetadata(
            to: desktopURL,
            id: "desktop",
            originator: "Codex Desktop",
            source: "vscode",
            threadSource: "user"
        )

        let reader = RolloutMetadataReader()
        XCTAssertEqual(try reader.readDesktopRoot(from: desktopURL)?.threadId, "desktop")

        let currentDesktopURL = directory.appendingPathComponent("current-desktop.jsonl")
        try writeMetadata(
            to: currentDesktopURL,
            id: "current-desktop",
            originator: "codex_work_desktop",
            source: "vscode",
            threadSource: "user"
        )
        XCTAssertEqual(
            try reader.readDesktopRoot(from: currentDesktopURL)?.threadId,
            "current-desktop"
        )

        let vscodeURL = directory.appendingPathComponent("vscode.jsonl")
        try writeMetadata(
            to: vscodeURL,
            id: "vscode",
            originator: "Codex VS Code",
            source: "vscode",
            threadSource: "user"
        )
        XCTAssertNil(try reader.readDesktopRoot(from: vscodeURL))

        let subagentURL = directory.appendingPathComponent("subagent.jsonl")
        try writeMetadata(
            to: subagentURL,
            id: "subagent",
            originator: "Codex Desktop",
            source: ["subagent": ["depth": 1]],
            threadSource: "subagent",
            parentThreadId: "desktop"
        )
        XCTAssertNil(try reader.readDesktopRoot(from: subagentURL))
    }

    private func writeMetadata(
        to url: URL,
        id: String,
        originator: String,
        source: Any,
        threadSource: String,
        parentThreadId: String? = nil
    ) throws {
        var payload: [String: Any] = [
            "id": id,
            "originator": originator,
            "source": source,
            "thread_source": threadSource,
            "cwd": "/tmp/project",
            "timestamp": "2026-07-10T10:00:00Z",
        ]
        if let parentThreadId {
            payload["parent_thread_id"] = parentThreadId
        }
        let object: [String: Any] = [
            "type": "session_meta",
            "timestamp": "2026-07-10T10:00:00Z",
            "payload": payload,
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try data.write(to: url)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
