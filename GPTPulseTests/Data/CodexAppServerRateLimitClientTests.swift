import Foundation
import XCTest
@testable import GPTPulse

final class CodexAppServerRateLimitClientTests: XCTestCase {
    func testClosedInputPipeThrowsWithoutTerminatingTheHostProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executableURL = root.appendingPathComponent("closing-fake-codex")
        let script = """
        #!/bin/sh
        IFS= read -r line || exit 0
        exec 0<&-
        printf '{"id":1,"result":{}}\\n'
        sleep 2
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let client = CodexAppServerRateLimitClient(
            locator: CodexExecutableLocator(explicitURL: executableURL),
            requestTimeout: 2
        )

        do {
            _ = try await client.loadRateLimits()
            XCTFail("Expected the closed App Server input pipe to fail")
        } catch {
            XCTAssertNotNil(error as? CodexAppServerRateLimitError)
        }
    }

    func testClientHandshakesAndReusesOnePersistentSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executableURL = root.appendingPathComponent("fake-codex")
        let logURL = root.appendingPathComponent("requests.jsonl")
        let script = """
        #!/bin/sh
        log_path='\(logURL.path)'
        read_line() {
          IFS= read -r line || exit 0
          printf '%s\\n' "$line" >> "$log_path"
        }
        rate_response() {
          printf '{"id":%s,"result":{"rateLimits":{"limitId":"codex","planType":"pro","primary":{"usedPercent":13,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1800600000}}}}\\n' "$1"
        }
        read_line
        printf '{"id":1,"result":{}}\\n'
        read_line
        read_line
        rate_response 2
        read_line
        rate_response 3
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$log_path"
        done
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let client = CodexAppServerRateLimitClient(
            locator: CodexExecutableLocator(explicitURL: executableURL),
            requestTimeout: 3
        )
        let first = try await client.loadRateLimits()
        let second = try await client.loadRateLimits()

        XCTAssertEqual(first.limitID, "codex")
        XCTAssertEqual(second.fiveHour?.usedPercent, 13)
        let requests = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let methods = requests.compactMap { request -> String? in
            guard let object = JSONValueSupport.object(from: Data(request.utf8)) else {
                return nil
            }
            return JSONValueSupport.string(object["method"])
        }
        XCTAssertEqual(methods.filter { $0 == "initialize" }.count, 1)
        XCTAssertEqual(methods.filter { $0 == "initialized" }.count, 1)
        XCTAssertEqual(methods.filter { $0 == "account/rateLimits/read" }.count, 2)
    }

    func testTopLevelRateLimitsWinAndWindowsAreIdentifiedByDuration() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveHourReset = observedAt.addingTimeInterval(3_600)
        let weeklyReset = observedAt.addingTimeInterval(7 * 24 * 60 * 60)
        let response: [String: Any] = [
            "result": [
                "rateLimits": [
                    "limitId": "codex",
                    "planType": "pro",
                    "primary": window(
                        used: 2,
                        minutes: 10_080,
                        reset: weeklyReset
                    ),
                    "secondary": window(
                        used: 13,
                        minutes: 300,
                        reset: fiveHourReset
                    ),
                ],
                "rateLimitsByLimitId": [
                    "codex_bengalfox": [
                        "limitId": "codex_bengalfox",
                        "planType": "pro",
                        "primary": window(
                            used: 91,
                            minutes: 300,
                            reset: observedAt.addingTimeInterval(60)
                        ),
                        "secondary": window(
                            used: 88,
                            minutes: 10_080,
                            reset: observedAt.addingTimeInterval(120)
                        ),
                    ],
                ],
            ],
        ]

        let snapshot = try CodexAppServerRateLimitResponseParser.parse(
            response,
            observedAt: observedAt
        )

        XCTAssertEqual(snapshot.limitID, "codex")
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.updatedAt, observedAt)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 13)
        XCTAssertEqual(snapshot.fiveHour?.windowMinutes, 300)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, fiveHourReset)
        XCTAssertEqual(snapshot.fiveHour?.observedAt, observedAt)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 2)
        XCTAssertEqual(snapshot.weekly?.windowMinutes, 10_080)
        XCTAssertEqual(snapshot.weekly?.resetsAt, weeklyReset)
        XCTAssertEqual(snapshot.weekly?.observedAt, observedAt)
    }

    func testServerErrorResponsePreservesMessage() {
        XCTAssertThrowsError(
            try CodexAppServerRateLimitResponseParser.parse(
                ["error": ["message": "rate limits unavailable"]],
                observedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ) { error in
            guard case let CodexAppServerRateLimitError.server(message) = error else {
                return XCTFail("Expected server error, received \(error)")
            }
            XCTAssertEqual(message, "rate limits unavailable")
        }
    }

    func testMissingTopLevelRateLimitsRejectsNonCanonicalLimitMap() {
        let response: [String: Any] = [
            "result": [
                "rateLimitsByLimitId": [
                    "codex_bengalfox": [
                        "primary": window(
                            used: 10,
                            minutes: 300,
                            reset: Date(timeIntervalSince1970: 1_700_000_300)
                        ),
                    ],
                ],
            ],
        ]

        XCTAssertThrowsError(
            try CodexAppServerRateLimitResponseParser.parse(
                response,
                observedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ) { error in
            guard case CodexAppServerRateLimitError.malformedResponse = error else {
                return XCTFail("Expected malformed response, received \(error)")
            }
        }
    }

    func testCanonicalLimitMapIsSafeFallbackWhenTopLevelViewIsMissing() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let response: [String: Any] = [
            "result": [
                "rateLimitsByLimitId": [
                    "codex": [
                        "limitId": "codex",
                        "planType": "pro",
                        "primary": window(
                            used: 14,
                            minutes: 300,
                            reset: observedAt.addingTimeInterval(3_600)
                        ),
                        "secondary": window(
                            used: 3,
                            minutes: 10_080,
                            reset: observedAt.addingTimeInterval(7 * 24 * 60 * 60)
                        ),
                    ],
                ],
            ],
        ]

        let snapshot = try CodexAppServerRateLimitResponseParser.parse(
            response,
            observedAt: observedAt
        )

        XCTAssertEqual(snapshot.limitID, "codex")
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 14)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 3)
    }

    func testPartialOfficialWindowGroupIsRejected() {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let response: [String: Any] = [
            "result": [
                "rateLimits": [
                    "limitId": "codex",
                    "planType": "pro",
                    "primary": window(
                        used: 14,
                        minutes: 300,
                        reset: observedAt.addingTimeInterval(3_600)
                    ),
                ],
            ],
        ]

        XCTAssertThrowsError(
            try CodexAppServerRateLimitResponseParser.parse(
                response,
                observedAt: observedAt
            )
        ) { error in
            guard case CodexAppServerRateLimitError.malformedResponse = error else {
                return XCTFail("Expected malformed response, received \(error)")
            }
        }
    }

    private func window(
        used: Double,
        minutes: Int,
        reset: Date
    ) -> [String: Any] {
        [
            "usedPercent": used,
            "windowDurationMins": minutes,
            "resetsAt": reset.timeIntervalSince1970,
        ]
    }
}
