import Foundation
import XCTest
@testable import GPTPulse

final class CodexRolloutAdapterTests: XCTestCase {
    func testIncrementalGrowthPreservesTurnStartBeyondTailWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rolloutURL = root.appendingPathComponent("rollout.jsonl")
        let now = Date.now
        let sessionStart = now.addingTimeInterval(-100)
        let turnStart = now.addingTimeInterval(-10)

        try writeJSONLines([
            metadata(timestamp: sessionStart),
            event("task_started", timestamp: turnStart, payload: [
                "turn_id": "turn-1",
                "started_at": turnStart.timeIntervalSince1970,
            ]),
        ], to: rolloutURL)

        let adapter = CodexRolloutAdapter(
            sessionsDirectory: root,
            sessionIndexURL: root.appendingPathComponent("missing-index.jsonl"),
            tailParser: RolloutJSONLTailParser(maximumTailBytes: 256),
            lookback: 60 * 60,
            discoveryInterval: 0
        )
        var result = try await adapter.loadDesktopRootTasks(now: now)
        XCTAssertEqual(
            try XCTUnwrap(result.records.first?.status.startedAt).timeIntervalSince1970,
            turnStart.timeIntervalSince1970,
            accuracy: 1
        )

        let activity = (0..<50).map { index in
            event(
                "agent_reasoning",
                timestamp: now.addingTimeInterval(Double(index) / 100),
                payload: ["text": String(repeating: "x", count: 80)]
            )
        }
        try appendJSONLines(activity, to: rolloutURL)

        result = try await adapter.loadDesktopRootTasks(now: now.addingTimeInterval(1))
        XCTAssertEqual(result.records.first?.status.state, .running)
        XCTAssertEqual(
            try XCTUnwrap(result.records.first?.status.startedAt).timeIntervalSince1970,
            turnStart.timeIntervalSince1970,
            accuracy: 1
        )
        let stableResult = try await adapter.loadDesktopRootTasks(
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(stableResult.records.first?.status, result.records.first?.status)
    }

    private func metadata(timestamp: Date) -> [String: Any] {
        [
            "type": "session_meta",
            "timestamp": timestamp.ISO8601Format(),
            "payload": [
                "id": "thread-1",
                "originator": "Codex Desktop",
                "source": "vscode",
                "thread_source": "user",
                "cwd": "/tmp/project",
                "timestamp": timestamp.ISO8601Format(),
            ],
        ]
    }

    private func event(
        _ type: String,
        timestamp: Date,
        payload: [String: Any]
    ) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp.ISO8601Format(),
            "payload": payload.merging(["type": type]) { current, _ in current },
        ]
    }

    private func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        try jsonLines(objects).write(to: url)
    }

    private func appendJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: jsonLines(objects))
    }

    private func jsonLines(_ objects: [[String: Any]]) throws -> Data {
        try objects.reduce(into: Data()) { result, object in
            result.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            result.append(0x0A)
        }
    }
}
