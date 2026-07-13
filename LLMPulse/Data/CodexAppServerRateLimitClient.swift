import AppKit
import Darwin
import Foundation
import Security

protocol CodexAccountRateLimitLoading: Sendable {
    func loadRateLimits() async throws -> RateLimitSnapshot
}

enum CodexAppServerRateLimitError: LocalizedError, Sendable {
    case executableUnavailable
    case launchFailed(String)
    case processExited
    case timedOut
    case malformedResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "Codex Desktop App Server executable was not found"
        case let .launchFailed(message):
            return "Codex App Server could not start: \(message)"
        case .processExited:
            return "Codex App Server exited before returning account limits"
        case .timedOut:
            return "Codex App Server account limits request timed out"
        case .malformedResponse:
            return "Codex App Server returned an unsupported account limits response"
        case let .server(message):
            return "Codex App Server account limits request failed: \(message)"
        }
    }
}

struct CodexExecutableLocator: Sendable {
    private static let trustedRequirement = """
    anchor apple generic and identifier "codex" and \
    certificate leaf[subject.OU] = "2DC432GLL2"
    """

    private let explicitURL: URL?

    init(explicitURL: URL? = nil) {
        self.explicitURL = explicitURL
    }

    func locate() -> URL? {
        if let explicitURL, FileManager.default.isExecutableFile(atPath: explicitURL.path) {
            return explicitURL
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) else {
            return nil
        }
        let executableURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path),
              isTrustedCodexExecutable(executableURL)
        else {
            return nil
        }
        return executableURL
    }

    private func isTrustedCodexExecutable(_ executableURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
            let staticCode
        else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            Self.trustedRequirement as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
            let requirement
        else {
            return false
        }

        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            requirement
        ) == errSecSuccess
    }
}

final class CodexAppServerRateLimitClient: CodexAccountRateLimitLoading, @unchecked Sendable {
    private let worker: CodexAppServerRateLimitWorker

    init(
        locator: CodexExecutableLocator = CodexExecutableLocator(),
        requestTimeout: TimeInterval = 30
    ) {
        let normalizedTimeout = requestTimeout.isFinite
            ? min(5 * 60, max(1, requestTimeout))
            : 30
        worker = CodexAppServerRateLimitWorker(
            locator: locator,
            requestTimeout: normalizedTimeout
        )
    }

    func loadRateLimits() async throws -> RateLimitSnapshot {
        try await worker.loadRateLimits()
    }
}

enum CodexAppServerRateLimitResponseParser {
    static func parse(
        _ response: [String: Any],
        observedAt: Date
    ) throws -> RateLimitSnapshot {
        if let error = response["error"] as? [String: Any] {
            let message = JSONValueSupport.string(error["message"])
                ?? "Unknown App Server error"
            throw CodexAppServerRateLimitError.server(message)
        }
        guard let result = response["result"] as? [String: Any] else {
            throw CodexAppServerRateLimitError.malformedResponse
        }
        let topLevelRateLimits = result["rateLimits"] as? [String: Any]
        let canonicalTopLevelRateLimits = topLevelRateLimits.flatMap { rateLimits in
            JSONValueSupport.string(rateLimits["limitId"])?.lowercased() == "codex"
                ? rateLimits
                : nil
        }
        let canonicalMapRateLimits = (result["rateLimitsByLimitId"] as? [String: Any])?["codex"]
            as? [String: Any]
        guard let rateLimits = canonicalTopLevelRateLimits ?? canonicalMapRateLimits else {
            throw CodexAppServerRateLimitError.malformedResponse
        }

        var fiveHour: RateLimitWindowSnapshot?
        var weekly: RateLimitWindowSnapshot?
        for key in ["primary", "secondary"] {
            guard let object = rateLimits[key] as? [String: Any],
                  let window = parseWindow(object, observedAt: observedAt)
            else {
                continue
            }
            switch window.windowMinutes {
            case RateLimitWindowDuration.legacyFiveHourMinutes:
                fiveHour = window
            case RateLimitWindowDuration.weeklyMinutes:
                weekly = window
            default:
                continue
            }
        }
        // Codex currently exposes a weekly-only account pool. Keep parsing a
        // well-formed legacy 5h window for future reuse, but never require it
        // or let a malformed/unknown legacy window invalidate weekly data.
        guard let weekly else {
            throw CodexAppServerRateLimitError.malformedResponse
        }

        return RateLimitSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            updatedAt: observedAt,
            planType: JSONValueSupport.string(rateLimits["planType"]),
            // Selection above proves this is the canonical account pool. Do
            // not propagate a contradictory/missing nested identifier from a
            // map entry keyed by `codex`.
            limitID: "codex"
        )
    }

    private static func parseWindow(
        _ object: [String: Any],
        observedAt: Date
    ) -> RateLimitWindowSnapshot? {
        guard let usedPercent = JSONValueSupport.double(object["usedPercent"]),
              usedPercent.isFinite,
              let windowMinutes = JSONValueSupport.int(object["windowDurationMins"]),
              windowMinutes > 0,
              let resetsAt = JSONValueSupport.date(object["resetsAt"])
        else {
            return nil
        }
        return RateLimitWindowSnapshot(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            observedAt: observedAt
        )
    }
}

private final class CodexAppServerRateLimitWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.zuuzii.LLMPulse.app-server-rate-limits")
    private let locator: CodexExecutableLocator
    private let requestTimeout: TimeInterval
    private var session: CodexAppServerSession?

    init(locator: CodexExecutableLocator, requestTimeout: TimeInterval) {
        self.locator = locator
        self.requestTimeout = requestTimeout
    }

    deinit {
        session?.stop()
    }

    func loadRateLimits() async throws -> RateLimitSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try loadOnQueue())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadOnQueue() throws -> RateLimitSnapshot {
        let activeSession: CodexAppServerSession
        if let session, session.isRunning {
            activeSession = session
        } else {
            guard let executableURL = locator.locate() else {
                throw CodexAppServerRateLimitError.executableUnavailable
            }
            do {
                activeSession = try CodexAppServerSession(
                    executableURL: executableURL,
                    requestTimeout: requestTimeout
                )
                session = activeSession
            } catch {
                session?.stop()
                session = nil
                throw error
            }
        }

        do {
            return try activeSession.loadRateLimits()
        } catch {
            activeSession.stop()
            session = nil
            throw error
        }
    }
}

private final class CodexAppServerSession {
    private static let maximumBufferedBytes = 4 * 1_024 * 1_024
    private static var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private let process: Process
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let requestTimeout: TimeInterval
    private var outputBuffer = Data()
    private var nextRequestID = 1

    var isRunning: Bool { process.isRunning }

    init(executableURL: URL, requestTimeout: TimeInterval) throws {
        self.requestTimeout = requestTimeout
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CodexAppServerRateLimitError.launchFailed(error.localizedDescription)
        }
        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading

        guard fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            stop()
            throw CodexAppServerRateLimitError.launchFailed(
                "Could not configure the App Server input pipe"
            )
        }

        do {
            let requestID = nextID()
            try send([
                "method": "initialize",
                "id": requestID,
                "params": [
                    "clientInfo": [
                        "name": PulseBrand.technicalIdentifier,
                        "title": PulseBrand.displayName,
                        "version": Self.applicationVersion,
                    ],
                ],
            ])
            _ = try readResponse(id: requestID)
            try send(["method": "initialized", "params": [:]])
        } catch {
            stop()
            throw error
        }
    }

    func loadRateLimits() throws -> RateLimitSnapshot {
        let requestID = nextID()
        try send(["method": "account/rateLimits/read", "id": requestID])
        let response = try readResponse(id: requestID)
        return try CodexAppServerRateLimitResponseParser.parse(
            response,
            observedAt: .now
        )
    }

    func stop() {
        try? inputHandle.close()
        try? outputHandle.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func nextID() -> Int {
        defer { nextRequestID &+= 1 }
        return nextRequestID
    }

    private func send(_ object: [String: Any]) throws {
        guard process.isRunning else {
            throw CodexAppServerRateLimitError.processExited
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        do {
            try inputHandle.write(contentsOf: data)
        } catch {
            throw CodexAppServerRateLimitError.processExited
        }
    }

    private func readResponse(id: Int) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(requestTimeout)
        while Date() < deadline {
            while let line = popLine() {
                guard let object = JSONValueSupport.object(from: line) else { continue }
                if JSONValueSupport.int(object["id"]) == id {
                    return object
                }
            }
            try readMore(until: deadline)
        }
        throw CodexAppServerRateLimitError.timedOut
    }

    private func popLine() -> Data? {
        guard let newline = outputBuffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(outputBuffer[..<newline])
        outputBuffer.removeSubrange(...newline)
        return line
    }

    private func readMore(until deadline: Date) throws {
        guard process.isRunning else {
            throw CodexAppServerRateLimitError.processExited
        }
        let remainingMilliseconds = Int32(max(
            1,
            min(Double(Int32.max), ceil(deadline.timeIntervalSinceNow * 1_000))
        ))
        var descriptor = pollfd(
            fd: outputHandle.fileDescriptor,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        let result = Darwin.poll(&descriptor, 1, remainingMilliseconds)
        if result == 0 {
            throw CodexAppServerRateLimitError.timedOut
        }
        if result < 0 {
            if errno == EINTR { return }
            throw CodexAppServerRateLimitError.processExited
        }
        guard descriptor.revents & Int16(POLLIN) != 0 else {
            throw CodexAppServerRateLimitError.processExited
        }
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        let byteCount = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(outputHandle.fileDescriptor, buffer.baseAddress, buffer.count)
        }
        if byteCount < 0 {
            if errno == EINTR { return }
            throw CodexAppServerRateLimitError.processExited
        }
        guard byteCount > 0 else {
            throw CodexAppServerRateLimitError.processExited
        }
        outputBuffer.append(contentsOf: bytes.prefix(byteCount))
        guard outputBuffer.count <= Self.maximumBufferedBytes else {
            throw CodexAppServerRateLimitError.malformedResponse
        }
    }
}
