import Foundation
import SQLite3

protocol CodexAgentActivityObserving: Sendable {
    func observations(
        rootStates: [String: PulseTaskState],
        now: Date
    ) async -> [String: AgentActivityObservation]
}

actor CodexAgentActivityObserver: CodexAgentActivityObserving {
    fileprivate enum DatabaseSource: Sendable {
        case codexHome(URL)
        case candidates([URL])
    }

    private let databaseSource: DatabaseSource
    private let refreshInterval: TimeInterval
    private let provisionalInterval: TimeInterval

    private var cachedObservations: [String: AgentActivityObservation] = [:]
    private var cachedRootStates: [String: PulseTaskState] = [:]
    private var graphCache: AgentGraphCache?
    private var rolloutCache: [URL: AgentRolloutCacheEntry] = [:]
    private var refreshTask: Task<Void, Never>?
    private var lastRefreshStartedAt = Date.distantPast

    init(
        codexHome: URL,
        refreshInterval: TimeInterval = 1,
        provisionalInterval: TimeInterval = 10
    ) {
        databaseSource = .codexHome(codexHome)
        self.refreshInterval = max(0, refreshInterval)
        self.provisionalInterval = max(0, provisionalInterval)
    }

    init(
        databaseCandidates: [URL],
        refreshInterval: TimeInterval = 1,
        provisionalInterval: TimeInterval = 10
    ) {
        databaseSource = .candidates(databaseCandidates)
        self.refreshInterval = max(0, refreshInterval)
        self.provisionalInterval = max(0, provisionalInterval)
    }

    func observations(
        rootStates: [String: PulseTaskState],
        now: Date = .now
    ) async -> [String: AgentActivityObservation] {
        let requestedIDs = Set(rootStates.keys)
        cachedObservations = cachedObservations.filter { requestedIDs.contains($0.key) }

        var rootsChanged = Set(cachedRootStates.keys) != requestedIDs
        for (threadID, state) in rootStates where cachedRootStates[threadID] != state {
            rootsChanged = true
            cachedObservations[threadID] = AgentActivityObservation(
                activeCount: nil,
                confidence: .provisional,
                observedAt: now
            )
        }
        cachedRootStates = rootStates

        for threadID in requestedIDs where cachedObservations[threadID] == nil {
            cachedObservations[threadID] = AgentActivityObservation(
                activeCount: nil,
                confidence: .provisional,
                observedAt: now
            )
        }

        let intervalElapsed = now.timeIntervalSince(lastRefreshStartedAt) >= refreshInterval
        if refreshTask == nil, rootsChanged || intervalElapsed {
            startRefresh(rootStates: rootStates, now: now)
        }

        return Dictionary(uniqueKeysWithValues: requestedIDs.map { threadID in
            (
                threadID,
                cachedObservations[threadID] ?? AgentActivityObservation(
                    activeCount: nil,
                    confidence: .unavailable,
                    observedAt: now
                )
            )
        })
    }

    func waitForCurrentRefreshForTesting() async {
        let task = refreshTask
        await task?.value
    }

    private func startRefresh(
        rootStates: [String: PulseTaskState],
        now: Date
    ) {
        lastRefreshStartedAt = now
        let source = databaseSource
        let priorGraphCache = graphCache
        let priorRolloutCache = rolloutCache
        let provisionalInterval = provisionalInterval

        refreshTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try AgentActivityLoader.load(
                    databaseSource: source,
                    rootStates: rootStates,
                    now: now,
                    provisionalInterval: provisionalInterval,
                    graphCache: priorGraphCache,
                    rolloutCache: priorRolloutCache
                )
                await self?.finishRefresh(result, requestedRootStates: rootStates)
            } catch {
                await self?.failRefresh(
                    requestedRootStates: rootStates,
                    failedAt: now
                )
            }
        }
    }

    private func finishRefresh(
        _ result: AgentActivityLoadResult,
        requestedRootStates: [String: PulseTaskState]
    ) {
        graphCache = result.graphCache
        rolloutCache = result.rolloutCache

        for (threadID, requestedState) in requestedRootStates {
            guard cachedRootStates[threadID] == requestedState else { continue }
            let incoming = result.observations[threadID] ?? AgentActivityObservation(
                activeCount: nil,
                confidence: .unavailable,
                observedAt: result.observedAt
            )
            cachedObservations[threadID] = mergedObservation(
                current: cachedObservations[threadID],
                incoming: incoming
            )
        }
        refreshTask = nil
    }

    private func failRefresh(
        requestedRootStates: [String: PulseTaskState],
        failedAt: Date
    ) {
        for (threadID, requestedState) in requestedRootStates {
            guard cachedRootStates[threadID] == requestedState else { continue }
            if let current = cachedObservations[threadID],
               let count = current.activeCount
            {
                cachedObservations[threadID] = AgentActivityObservation(
                    activeCount: count,
                    confidence: .stale,
                    observedAt: current.observedAt
                )
            } else {
                cachedObservations[threadID] = AgentActivityObservation(
                    activeCount: nil,
                    confidence: .unavailable,
                    observedAt: failedAt
                )
            }
        }
        refreshTask = nil
    }

    private func mergedObservation(
        current: AgentActivityObservation?,
        incoming: AgentActivityObservation
    ) -> AgentActivityObservation {
        guard incoming.confidence == .unavailable,
              let current,
              let count = current.activeCount
        else {
            return incoming
        }
        return AgentActivityObservation(
            activeCount: count,
            confidence: .stale,
            observedAt: current.observedAt
        )
    }

}

private struct AgentActivityLoadResult: Sendable {
    let observations: [String: AgentActivityObservation]
    let observedAt: Date
    let graphCache: AgentGraphCache
    let rolloutCache: [URL: AgentRolloutCacheEntry]
}

private struct AgentGraphCache: Sendable {
    let databaseURL: URL
    let signature: AgentDatabaseSignature
    let graph: AgentGraph
    let loadedAt: Date
}

private struct AgentGraph: Sendable {
    struct Edge: Sendable {
        let childThreadID: String
        let status: String
    }

    struct Thread: Sendable {
        let rolloutURL: URL?
        let createdAt: Date?
        let createdAtIsPrecise: Bool
    }

    let childrenByParent: [String: [Edge]]
    let threadsByID: [String: Thread]
}

private struct AgentFileSignature: Equatable, Sendable {
    let size: Int64
    let modifiedAt: Date
}

private struct AgentDatabaseSignature: Equatable, Sendable {
    let database: AgentFileSignature
    let wal: AgentFileSignature?
}

private enum AgentLifecycleKind: Equatable, Sendable {
    case active
    case inactive
}

private struct AgentLifecycleEvent: Sendable {
    let kind: AgentLifecycleKind
    let occurredAt: Date?
}

private struct AgentParentActivity: Sendable {
    var firstStartedAt: Date?
    var latestInterruptedAt: Date?
}

private struct AgentRolloutIdentity: Sendable {
    let threadID: String
    let parentThreadID: String?
    let isSubagent: Bool
}

private struct AgentRolloutCacheEntry: Sendable {
    let signature: AgentFileSignature
    let parsedByteCount: Int
    let identity: AgentRolloutIdentity?
    let lastLifecycle: AgentLifecycleEvent?
    let lastErrorAt: Date?
    let latestActivityAt: Date?
    let activityByChild: [String: AgentParentActivity]
    let hasInvalidJSONLine: Bool
    let hasUnscannedGrowth: Bool
    let lastAccessedAt: Date
}

private struct AgentLoadBudget {
    private(set) var remainingNodes = 4_096
    private(set) var remainingFiles = 4_096
    private(set) var remainingBytes = 32 * 1_024 * 1_024
    private let deadline = Date().addingTimeInterval(0.5)

    mutating func consumeNodes(_ count: Int) -> Bool {
        guard count >= 0, count <= remainingNodes, Date() <= deadline else { return false }
        remainingNodes -= count
        return true
    }

    mutating func consumeFileRead(byteCount: Int) -> Bool {
        guard byteCount >= 0,
              remainingFiles > 0,
              byteCount <= remainingBytes,
              Date() <= deadline
        else {
            return false
        }
        remainingFiles -= 1
        remainingBytes -= byteCount
        return true
    }
}

private enum AgentActivityLoader {
    private static let initialTailBytes = 64 * 1_024
    private static let maximumTailBytes = 1 * 1_024 * 1_024
    private static let errorQuietPeriod: TimeInterval = 3
    private static let maximumDepth = 64
    private static let maximumDescendants = 2_048

    static func load(
        databaseSource: CodexAgentActivityObserver.DatabaseSource,
        rootStates: [String: PulseTaskState],
        now: Date,
        provisionalInterval: TimeInterval,
        graphCache: AgentGraphCache?,
        rolloutCache: [URL: AgentRolloutCacheEntry]
    ) throws -> AgentActivityLoadResult {
        let loadedGraph = try loadGraph(
            databaseSource: databaseSource,
            graphCache: graphCache,
            now: now
        )
        var nextRolloutCache = rolloutCache
        var observations: [String: AgentActivityObservation] = [:]
        var budget = AgentLoadBudget()

        for rootThreadID in rootStates.keys.sorted() {
            guard let rootState = rootStates[rootThreadID] else { continue }
            observations[rootThreadID] = observation(
                rootThreadID: rootThreadID,
                rootState: rootState,
                graph: loadedGraph.graph,
                now: now,
                provisionalInterval: provisionalInterval,
                rolloutCache: &nextRolloutCache,
                budget: &budget
            )
        }

        return AgentActivityLoadResult(
            observations: observations,
            observedAt: now,
            graphCache: loadedGraph,
            rolloutCache: prunedRolloutCache(nextRolloutCache)
        )
    }

    private static func observation(
        rootThreadID: String,
        rootState: PulseTaskState,
        graph: AgentGraph,
        now: Date,
        provisionalInterval: TimeInterval,
        rolloutCache: inout [URL: AgentRolloutCacheEntry],
        budget: inout AgentLoadBudget
    ) -> AgentActivityObservation {
        let traversal = descendants(of: rootThreadID, in: graph)
        guard graph.threadsByID[rootThreadID] != nil,
              traversal.isComplete,
              budget.consumeNodes(traversal.descendants.count + 1)
        else {
            return AgentActivityObservation(
                activeCount: nil,
                confidence: .unavailable,
                observedAt: now
            )
        }

        var activeCount = rootState.isTerminal ? 0 : 1
        var hasProvisionalState = false
        var hasUnknownState = false

        for descendant in traversal.descendants {
            guard let child = graph.threadsByID[descendant.childThreadID] else {
                hasUnknownState = true
                continue
            }

            let state = descendantState(
                descendant: descendant,
                child: child,
                graph: graph,
                now: now,
                provisionalInterval: provisionalInterval,
                rolloutCache: &rolloutCache,
                budget: &budget
            )
            switch state {
            case .activeExact:
                activeCount += 1
            case .activeProvisional:
                activeCount += 1
                hasProvisionalState = true
            case .inactive:
                break
            case .unknown:
                hasUnknownState = true
            }
        }

        if hasUnknownState {
            return AgentActivityObservation(
                activeCount: nil,
                confidence: .unavailable,
                observedAt: now
            )
        }
        return AgentActivityObservation(
            activeCount: activeCount,
            confidence: hasProvisionalState ? .provisional : .exact,
            observedAt: now
        )
    }

    private struct Descendant: Sendable {
        let parentThreadID: String
        let childThreadID: String
    }

    private static func descendants(
        of rootThreadID: String,
        in graph: AgentGraph
    ) -> (descendants: [Descendant], isComplete: Bool) {
        var result: [Descendant] = []
        var visited: Set<String> = [rootThreadID]
        var stack: [(parent: String, edge: AgentGraph.Edge, depth: Int)] =
            (graph.childrenByParent[rootThreadID] ?? []).map {
                (parent: rootThreadID, edge: $0, depth: 1)
            }

        while let item = stack.popLast() {
            let normalizedStatus = item.edge.status.lowercased()
            if normalizedStatus == "closed" { continue }
            guard normalizedStatus == "open" else { return (result, false) }
            guard item.depth <= maximumDepth, result.count < maximumDescendants else {
                return (result, false)
            }

            let childThreadID = item.edge.childThreadID
            if visited.contains(childThreadID) {
                return (result, false)
            }
            visited.insert(childThreadID)
            result.append(Descendant(
                parentThreadID: item.parent,
                childThreadID: childThreadID
            ))

            for childEdge in graph.childrenByParent[childThreadID] ?? [] {
                stack.append((
                    parent: childThreadID,
                    edge: childEdge,
                    depth: item.depth + 1
                ))
            }
        }
        return (result, true)
    }

    private enum DescendantState {
        case activeExact
        case activeProvisional
        case inactive
        case unknown
    }

    private static func descendantState(
        descendant: Descendant,
        child: AgentGraph.Thread,
        graph: AgentGraph,
        now: Date,
        provisionalInterval: TimeInterval,
        rolloutCache: inout [URL: AgentRolloutCacheEntry],
        budget: inout AgentLoadBudget
    ) -> DescendantState {
        var parentSummary: AgentRolloutCacheEntry?
        var parentActivity: AgentParentActivity?
        if let parentURL = graph.threadsByID[descendant.parentThreadID]?.rolloutURL {
            parentSummary = try? rolloutSummary(
                at: parentURL,
                requiredChildThreadID: descendant.childThreadID,
                requireLifecycle: false,
                now: now,
                cache: &rolloutCache,
                budget: &budget
            )
            parentActivity = parentSummary?.activityByChild[descendant.childThreadID]
        }

        let rolloutModifiedAt = child.rolloutURL.flatMap {
            (try? fileSignature(for: $0))?.modifiedAt
        }
        let recentReference = [child.createdAt, rolloutModifiedAt]
            .compactMap { $0 }
            .max()
        let isRecent = recentReference.map {
            let age = now.timeIntervalSince($0)
            return age >= -60 && age <= provisionalInterval
        } ?? false

        guard let childURL = child.rolloutURL else {
            return isRecent ? .activeProvisional : .unknown
        }

        let summary: AgentRolloutCacheEntry
        do {
            summary = try rolloutSummary(
                at: childURL,
                requiredChildThreadID: nil,
                requireLifecycle: true,
                now: now,
                cache: &rolloutCache,
                budget: &budget
            )
        } catch {
            return isRecent ? .activeProvisional : .unknown
        }

        guard let identity = summary.identity,
              identity.threadID == descendant.childThreadID,
              identity.isSubagent,
              identity.parentThreadID == descendant.parentThreadID,
              !summary.hasInvalidJSONLine
        else {
            return .unknown
        }

        let boundary = parentActivity?.firstStartedAt
            ?? (child.createdAtIsPrecise ? child.createdAt : nil)
        if isRecent, boundary == nil {
            return .activeProvisional
        }

        guard let lifecycle = summary.lastLifecycle else {
            return isRecent ? .activeProvisional : .unknown
        }
        if let interruptedAt = parentActivity?.latestInterruptedAt {
            guard let lifecycleAt = lifecycle.occurredAt,
                  lifecycleAt > interruptedAt
            else {
                return .inactive
            }
        }

        if let boundary {
            guard let occurredAt = lifecycle.occurredAt,
                  occurredAt >= boundary.addingTimeInterval(-0.001)
            else {
                return isRecent ? .activeProvisional : .unknown
            }
        } else if lifecycle.kind == .active {
            return isRecent ? .activeProvisional : .unknown
        }

        switch lifecycle.kind {
        case .active:
            guard let parentSummary else {
                return isRecent ? .activeProvisional : .unknown
            }
            if parentSummary.hasUnscannedGrowth || parentSummary.hasInvalidJSONLine {
                return isRecent ? .activeProvisional : .unknown
            }
            guard let occurredAt = lifecycle.occurredAt else {
                return isRecent ? .activeProvisional : .unknown
            }
            let age = now.timeIntervalSince(occurredAt)
            guard age >= -60 else { return .unknown }
            if let lastErrorAt = summary.lastErrorAt,
               lastErrorAt >= occurredAt,
               lastErrorAt >= (summary.latestActivityAt ?? lastErrorAt),
               now.timeIntervalSince(lastErrorAt) >= errorQuietPeriod
            {
                return .inactive
            }
            return .activeExact
        case .inactive:
            return .inactive
        }
    }

    private static func loadGraph(
        databaseSource: CodexAgentActivityObserver.DatabaseSource,
        graphCache: AgentGraphCache?,
        now: Date
    ) throws -> AgentGraphCache {
        let candidates: [URL]
        switch databaseSource {
        case let .codexHome(codexHome):
            candidates = CodexPaths.discoverStateDatabases(in: codexHome)
        case let .candidates(configured):
            candidates = configured
        }
        guard !candidates.isEmpty else {
            throw DataAdapterError.sqlite("No state_*.sqlite database was found")
        }

        var lastError: Error?
        for databaseURL in candidates {
            do {
                if let graphCache,
                   graphCache.databaseURL == databaseURL,
                   now.timeIntervalSince(graphCache.loadedAt) >= 0,
                   now.timeIntervalSince(graphCache.loadedAt) < 2
                {
                    return graphCache
                }
                let signature = try databaseSignature(for: databaseURL)
                if let graphCache,
                   graphCache.databaseURL == databaseURL,
                   graphCache.signature == signature
                {
                    return graphCache
                }
                return AgentGraphCache(
                    databaseURL: databaseURL,
                    signature: signature,
                    graph: try readGraph(from: databaseURL),
                    loadedAt: now
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? DataAdapterError.sqlite("No compatible state database was found")
    }

    private static func readGraph(from databaseURL: URL) throws -> AgentGraph {
        let connection = try SQLiteConnection(
            url: databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        )
        try connection.execute("PRAGMA query_only = ON")
        try connection.execute("BEGIN")
        defer { try? connection.execute("ROLLBACK") }

        let tables = try tableNames(in: connection)
        guard tables.contains("threads"), tables.contains("thread_spawn_edges") else {
            throw DataAdapterError.sqlite(
                "The selected state database has no agent relationship tables"
            )
        }

        let threadColumns = try columnNames(in: "threads", connection: connection)
        let edgeColumns = try columnNames(in: "thread_spawn_edges", connection: connection)
        guard threadColumns.contains("id"), threadColumns.contains("rollout_path") else {
            throw DataAdapterError.sqlite("Unsupported threads schema for Agent observation")
        }
        let requiredEdgeColumns: Set<String> = [
            "parent_thread_id", "child_thread_id", "status",
        ]
        guard requiredEdgeColumns.isSubset(of: edgeColumns) else {
            throw DataAdapterError.sqlite("Unsupported thread_spawn_edges schema")
        }

        let createdExpression: String
        if threadColumns.contains("created_at_ms") {
            createdExpression = "created_at_ms"
        } else if threadColumns.contains("created_at") {
            createdExpression = "created_at * 1000"
        } else {
            createdExpression = "NULL"
        }
        let createdAtIsPrecise = threadColumns.contains("created_at_ms")

        var threadsByID: [String: AgentGraph.Thread] = [:]
        let graphDeadline = Date().addingTimeInterval(0.5)
        try connection.withStatement(
            "SELECT id, rollout_path, \(createdExpression) FROM threads"
        ) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw DataAdapterError.sqlite("Failed while reading Agent threads")
                }
                guard let threadID = connection.string(at: 0, in: statement) else { continue }
                guard threadsByID.count < 100_000, Date() <= graphDeadline else {
                    throw DataAdapterError.sqlite("Agent thread graph exceeds safety limit")
                }
                let rolloutURL = connection.string(at: 1, in: statement).map {
                    URL(fileURLWithPath: $0)
                }
                let createdAt = connection.int64(at: 2, in: statement).map {
                    Date(timeIntervalSince1970: Double($0) / 1_000)
                }
                threadsByID[threadID] = AgentGraph.Thread(
                    rolloutURL: rolloutURL,
                    createdAt: createdAt,
                    createdAtIsPrecise: createdAtIsPrecise && createdAt != nil
                )
            }
        }

        var childrenByParent: [String: [AgentGraph.Edge]] = [:]
        var edgeCount = 0
        try connection.withStatement(
            "SELECT parent_thread_id, child_thread_id, status FROM thread_spawn_edges"
        ) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw DataAdapterError.sqlite("Failed while reading Agent relationships")
                }
                guard let parent = connection.string(at: 0, in: statement),
                      let child = connection.string(at: 1, in: statement),
                      let status = connection.string(at: 2, in: statement)
                else {
                    continue
                }
                guard edgeCount < 100_000, Date() <= graphDeadline else {
                    throw DataAdapterError.sqlite("Agent relationship graph exceeds safety limit")
                }
                childrenByParent[parent, default: []].append(AgentGraph.Edge(
                    childThreadID: child,
                    status: status
                ))
                edgeCount += 1
            }
        }

        return AgentGraph(
            childrenByParent: childrenByParent,
            threadsByID: threadsByID
        )
    }

    private static func rolloutSummary(
        at url: URL,
        requiredChildThreadID: String?,
        requireLifecycle: Bool,
        now: Date,
        cache: inout [URL: AgentRolloutCacheEntry],
        budget: inout AgentLoadBudget
    ) throws -> AgentRolloutCacheEntry {
        let signature = try fileSignature(for: url)
        let prior = cache[url]
        let sameFileVersion = prior?.signature == signature
        let initialBytes = min(initialTailBytes, max(0, Int(signature.size)))

        var entry: AgentRolloutCacheEntry
        if sameFileVersion, let prior {
            var identity = prior.identity
            if identity == nil, budget.consumeFileRead(byteCount: 256 * 1_024) {
                identity = try? readRolloutIdentity(at: url)
            }
            entry = AgentRolloutCacheEntry(
                signature: prior.signature,
                parsedByteCount: prior.parsedByteCount,
                identity: identity,
                lastLifecycle: prior.lastLifecycle,
                lastErrorAt: prior.lastErrorAt,
                latestActivityAt: prior.latestActivityAt,
                activityByChild: prior.activityByChild,
                hasInvalidJSONLine: prior.hasInvalidJSONLine,
                hasUnscannedGrowth: prior.hasUnscannedGrowth,
                lastAccessedAt: now
            )
        } else {
            let identity: AgentRolloutIdentity?
            if let priorIdentity = prior?.identity {
                identity = priorIdentity
            } else if budget.consumeFileRead(byteCount: 256 * 1_024) {
                identity = try? readRolloutIdentity(at: url)
            } else {
                identity = nil
            }
            guard budget.consumeFileRead(byteCount: initialBytes) else {
                throw DataAdapterError.invalidFormat(url, "Agent observation budget exceeded")
            }
            entry = try parseRolloutTail(
                at: url,
                signature: signature,
                byteCount: initialBytes,
                identity: identity,
                prior: prior,
                now: now
            )
        }

        let lacksLifecycle = requireLifecycle && entry.lastLifecycle == nil
        let lacksChildActivity = requiredChildThreadID.map {
            entry.activityByChild[$0]?.firstStartedAt == nil
        } ?? false
        if (lacksLifecycle || lacksChildActivity || entry.hasUnscannedGrowth),
           entry.parsedByteCount < min(maximumTailBytes, Int(signature.size))
        {
            let expandedByteCount = min(maximumTailBytes, Int(signature.size))
            guard budget.consumeFileRead(byteCount: expandedByteCount) else {
                throw DataAdapterError.invalidFormat(url, "Agent observation budget exceeded")
            }
            entry = try parseRolloutTail(
                at: url,
                signature: signature,
                byteCount: expandedByteCount,
                identity: entry.identity,
                prior: prior,
                now: now
            )
        }
        cache[url] = entry
        return entry
    }

    private static func parseRolloutTail(
        at url: URL,
        signature: AgentFileSignature,
        byteCount: Int,
        identity: AgentRolloutIdentity?,
        prior: AgentRolloutCacheEntry?,
        now: Date
    ) throws -> AgentRolloutCacheEntry {
        let data = try readTail(at: url, fileSize: signature.size, byteCount: byteCount)
        var lastLifecycle: AgentLifecycleEvent?
        var lastErrorAt: Date?
        var latestActivityAt: Date?
        var activityByChild: [String: AgentParentActivity] = [:]
        var hasInvalidJSONLine = false

        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let isTrailingPartialLine = index == lines.index(before: lines.endIndex)
                && data.last != 0x0A
            guard let envelope = JSONValueSupport.object(from: Data(line)) else {
                if !isTrailingPartialLine { hasInvalidJSONLine = true }
                continue
            }
            guard let topLevelType = envelope["type"] as? String,
                  let payload = envelope["payload"] as? [String: Any]
            else {
                continue
            }
            let occurredAt = eventDate(
                envelope: envelope,
                payload: payload
            )
            if (topLevelType == "event_msg" || topLevelType == "response_item"),
               let occurredAt
            {
                latestActivityAt = max(latestActivityAt ?? occurredAt, occurredAt)
            }
            guard topLevelType == "event_msg",
                  let eventType = payload["type"] as? String
            else {
                continue
            }
            switch eventType {
            case "task_started":
                lastLifecycle = AgentLifecycleEvent(kind: .active, occurredAt: occurredAt)
            case "task_complete", "task_failed", "turn_failed", "turn_aborted",
                 "shutdown_complete":
                lastLifecycle = AgentLifecycleEvent(kind: .inactive, occurredAt: occurredAt)
            case "error":
                if let occurredAt {
                    lastErrorAt = max(lastErrorAt ?? occurredAt, occurredAt)
                }
            case "sub_agent_activity":
                guard let childThreadID = payload["agent_thread_id"] as? String,
                      let kind = payload["kind"] as? String
                else {
                    continue
                }
                var activity = activityByChild[childThreadID] ?? AgentParentActivity()
                if kind == "started", let occurredAt {
                    activity.firstStartedAt = min(activity.firstStartedAt ?? occurredAt, occurredAt)
                }
                if kind == "interrupted", let occurredAt {
                    activity.latestInterruptedAt = max(
                        activity.latestInterruptedAt ?? occurredAt,
                        occurredAt
                    )
                }
                activityByChild[childThreadID] = activity
            default:
                continue
            }
        }

        let fileGrew = prior.map { signature.size >= $0.signature.size } ?? false
        let growth = prior.map { max(0, signature.size - $0.signature.size) } ?? 0
        let hasUnscannedGrowth = (prior?.hasUnscannedGrowth ?? false)
            || growth > Int64(byteCount)
        if fileGrew, let prior {
            if lastLifecycle == nil, !hasUnscannedGrowth {
                lastLifecycle = prior.lastLifecycle
            }
            if let priorErrorAt = prior.lastErrorAt {
                lastErrorAt = max(lastErrorAt ?? priorErrorAt, priorErrorAt)
            }
            if let priorActivityAt = prior.latestActivityAt {
                latestActivityAt = max(latestActivityAt ?? priorActivityAt, priorActivityAt)
            }
            activityByChild = mergeActivities(
                prior.activityByChild,
                activityByChild
            )
        }

        return AgentRolloutCacheEntry(
            signature: signature,
            parsedByteCount: byteCount,
            identity: identity,
            lastLifecycle: lastLifecycle,
            lastErrorAt: lastErrorAt,
            latestActivityAt: latestActivityAt,
            activityByChild: activityByChild,
            hasInvalidJSONLine: hasInvalidJSONLine || prior?.hasInvalidJSONLine == true,
            hasUnscannedGrowth: hasUnscannedGrowth,
            lastAccessedAt: now
        )
    }

    private static func readTail(
        at url: URL,
        fileSize: Int64,
        byteCount: Int
    ) throws -> Data {
        guard fileSize >= 0 else { throw DataAdapterError.invalidFormat(url, "Invalid size") }
        let requestedStart = max(0, fileSize - Int64(max(0, byteCount)))
        let readStart = requestedStart > 0 ? requestedStart - 1 : 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(readStart))
        let data = try handle.read(upToCount: max(0, byteCount) + 1) ?? Data()
        guard requestedStart > 0 else { return data }

        guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
        let next = data.index(after: newline)
        return Data(data[next...])
    }

    private static func readRolloutIdentity(at url: URL) throws -> AgentRolloutIdentity {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 256 * 1_024) ?? Data()
        guard let newline = data.firstIndex(of: 0x0A) else {
            throw DataAdapterError.invalidFormat(url, "Missing session metadata line")
        }
        guard let envelope = JSONValueSupport.object(from: Data(data[..<newline])),
              envelope["type"] as? String == "session_meta",
              let payload = envelope["payload"] as? [String: Any],
              let threadID = JSONValueSupport.string(payload["id"])
        else {
            throw DataAdapterError.invalidFormat(url, "Invalid session metadata")
        }

        let source = payload["source"] as? [String: Any]
        let subagent = source?["subagent"] as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any]
        let parentThreadID = JSONValueSupport.string(payload["parent_thread_id"])
            ?? JSONValueSupport.string(spawn?["parent_thread_id"])
        let threadSource = JSONValueSupport.string(payload["thread_source"])
        return AgentRolloutIdentity(
            threadID: threadID,
            parentThreadID: parentThreadID,
            isSubagent: threadSource == "subagent" || subagent != nil
        )
    }

    private static func eventDate(
        envelope: [String: Any],
        payload: [String: Any]
    ) -> Date? {
        if let occurredAt = JSONValueSupport.date(payload["occurred_at_ms"]) {
            return occurredAt
        }
        for key in ["started_at", "completed_at", "failed_at", "aborted_at"] {
            if let date = JSONValueSupport.date(payload[key]) {
                return date
            }
        }
        return JSONValueSupport.date(envelope["timestamp"])
    }

    private static func mergeActivities(
        _ prior: [String: AgentParentActivity],
        _ incoming: [String: AgentParentActivity]
    ) -> [String: AgentParentActivity] {
        var result = prior
        for (threadID, incomingActivity) in incoming {
            var merged = result[threadID] ?? AgentParentActivity()
            if let incomingStarted = incomingActivity.firstStartedAt {
                merged.firstStartedAt = min(
                    merged.firstStartedAt ?? incomingStarted,
                    incomingStarted
                )
            }
            if let incomingInterrupted = incomingActivity.latestInterruptedAt {
                merged.latestInterruptedAt = max(
                    merged.latestInterruptedAt ?? incomingInterrupted,
                    incomingInterrupted
                )
            }
            result[threadID] = merged
        }
        return result
    }

    private static func prunedRolloutCache(
        _ cache: [URL: AgentRolloutCacheEntry]
    ) -> [URL: AgentRolloutCacheEntry] {
        let limit = 2_048
        guard cache.count > limit else { return cache }
        let retained = cache
            .sorted { lhs, rhs in lhs.value.lastAccessedAt > rhs.value.lastAccessedAt }
            .prefix(limit)
        return Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
    }

    private static func databaseSignature(for url: URL) throws -> AgentDatabaseSignature {
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        return AgentDatabaseSignature(
            database: try fileSignature(for: url),
            wal: try? fileSignature(for: walURL)
        )
    }

    private static func fileSignature(for url: URL) throws -> AgentFileSignature {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modifiedAt = attributes[.modificationDate] as? Date
        else {
            throw DataAdapterError.invalidFormat(url, "Missing file metadata")
        }
        return AgentFileSignature(size: size, modifiedAt: modifiedAt)
    }

    private static func tableNames(in connection: SQLiteConnection) throws -> Set<String> {
        var names: Set<String> = []
        try connection.withStatement(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = connection.string(at: 0, in: statement) {
                    names.insert(name)
                }
            }
        }
        return names
    }

    private static func columnNames(
        in table: String,
        connection: SQLiteConnection
    ) throws -> Set<String> {
        var names: Set<String> = []
        try connection.withStatement("PRAGMA table_info(\(table))") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = connection.string(at: 1, in: statement) {
                    names.insert(name)
                }
            }
        }
        return names
    }
}
