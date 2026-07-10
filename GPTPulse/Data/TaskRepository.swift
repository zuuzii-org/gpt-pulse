import Foundation

protocol TaskRepositoryProtocol: Sendable {
    func snapshot(now: Date) async -> TaskSnapshot
    func markViewed(_ task: PulseTask, at date: Date) async throws
}

actor TaskRepository: TaskRepositoryProtocol {
    private struct MergedMetadata: Sendable {
        let threadId: String
        var title: String
        var projectDirectory: String
        var createdAt: Date
        var updatedAt: Date
    }

    private let appServerProbe: AppServerCapabilityProbe
    private let sqliteAdapter: CodexSQLiteTaskAdapter
    private let rolloutAdapter: CodexRolloutAdapter
    private let journalReader: PluginEventJournalReader
    private let receiptStore: ReceiptStore
    private let sqliteRefreshInterval: TimeInterval
    private let runningStaleInterval: TimeInterval
    private let terminalRetentionInterval: TimeInterval
    private let terminalLimit: Int
    private var cachedSQLiteResult: SQLiteTaskReadResult?
    private var lastSQLiteRefreshAt: Date = .distantPast

    init(
        appServerProbe: AppServerCapabilityProbe,
        sqliteAdapter: CodexSQLiteTaskAdapter,
        rolloutAdapter: CodexRolloutAdapter,
        journalReader: PluginEventJournalReader,
        receiptStore: ReceiptStore,
        sqliteRefreshInterval: TimeInterval = 30,
        runningStaleInterval: TimeInterval = 24 * 60 * 60,
        terminalRetentionInterval: TimeInterval = 24 * 60 * 60,
        terminalLimit: Int = 20
    ) {
        self.appServerProbe = appServerProbe
        self.sqliteAdapter = sqliteAdapter
        self.rolloutAdapter = rolloutAdapter
        self.journalReader = journalReader
        self.receiptStore = receiptStore
        self.sqliteRefreshInterval = sqliteRefreshInterval
        self.runningStaleInterval = runningStaleInterval
        self.terminalRetentionInterval = terminalRetentionInterval
        self.terminalLimit = terminalLimit
    }

    static func live(paths: CodexPaths = .live()) -> TaskRepository {
        TaskRepository(
            appServerProbe: AppServerCapabilityProbe(
                controlSocketURL: paths.appServerControlSocketURL
            ),
            sqliteAdapter: CodexSQLiteTaskAdapter(
                codexHome: paths.codexHome
            ),
            rolloutAdapter: CodexRolloutAdapter(
                sessionsDirectory: paths.sessionsDirectory,
                sessionIndexURL: paths.sessionIndexURL
            ),
            journalReader: PluginEventJournalReader(
                journalURL: paths.pluginJournalURL
            ),
            receiptStore: ReceiptStore(databaseURL: paths.receiptsDatabaseURL)
        )
    }

    func snapshot(now: Date = .now) async -> TaskSnapshot {
        var health: [AdapterHealth] = [appServerProbe.health(now: now)]

        let receipts: ReceiptSnapshot
        do {
            receipts = try await receiptStore.snapshot(now: now)
            health.append(.healthy(.receipts, at: now))
        } catch {
            receipts = ReceiptSnapshot(baselineAt: now, viewedTaskIDs: [])
            health.append(.unavailable(.receipts, message: safeMessage(for: error)))
        }

        let sqliteResult: SQLiteTaskReadResult
        if let cachedSQLiteResult,
           now.timeIntervalSince(lastSQLiteRefreshAt) < sqliteRefreshInterval
        {
            sqliteResult = cachedSQLiteResult
            health.append(.healthy(.sqlite, at: lastSQLiteRefreshAt))
        } else {
            do {
                let freshResult = try sqliteAdapter.loadDesktopRootThreads()
                sqliteResult = freshResult
                cachedSQLiteResult = freshResult
                lastSQLiteRefreshAt = now
                health.append(.healthy(.sqlite, at: now))
            } catch {
                if let cachedSQLiteResult {
                    sqliteResult = cachedSQLiteResult
                    health.append(.degraded(
                        .sqlite,
                        message: safeMessage(for: error),
                        lastSuccessAt: lastSQLiteRefreshAt
                    ))
                } else {
                    sqliteResult = SQLiteTaskReadResult(
                        records: [],
                        unverifiedCandidateCount: 0
                    )
                    health.append(.unavailable(.sqlite, message: safeMessage(for: error)))
                }
            }
        }

        let rolloutResult: RolloutTaskReadResult
        do {
            rolloutResult = try await rolloutAdapter.loadDesktopRootTasks(
                additionalRolloutURLs: sqliteResult.records.map(\.rolloutURL),
                now: now
            )
            if rolloutResult.invalidFileCount > 0 {
                health.append(.degraded(
                    .rolloutJSONL,
                    message: "Rollout data is readable with partial metadata",
                    lastSuccessAt: now
                ))
            } else {
                health.append(.healthy(.rolloutJSONL, at: now))
            }
        } catch {
            rolloutResult = RolloutTaskReadResult(
                records: [],
                invalidFileCount: 0,
                sessionIndexAvailable: false
            )
            health.append(.unavailable(.rolloutJSONL, message: safeMessage(for: error)))
        }

        let journalResult: PluginJournalReadResult
        do {
            journalResult = try await journalReader.load(now: now)
            if journalResult.invalidLineCount > 0 {
                health.append(.degraded(
                    .pluginJournal,
                    message: "Plugin journal contains ignored invalid events",
                    lastSuccessAt: now
                ))
            } else {
                health.append(.healthy(.pluginJournal, at: now))
            }
        } catch {
            journalResult = PluginJournalReadResult(records: [], invalidLineCount: 0)
            health.append(.unavailable(.pluginJournal, message: safeMessage(for: error)))
        }

        if let sqliteNewest = sqliteResult.records.map(\.updatedAt).max(),
           let rolloutNewest = rolloutResult.records.map(\.status.updatedAt).max(),
           rolloutNewest.timeIntervalSince(sqliteNewest) > 60 * 60
        {
            replaceHealth(
                in: &health,
                with: .degraded(
                    .sqlite,
                    message: "Codex state SQLite is behind current rollout data",
                    lastSuccessAt: sqliteNewest
                )
            )
        }

        var metadataByThread: [String: MergedMetadata] = [:]
        var sqliteTokenUsageByThread: [String: TokenUsageSnapshot] = [:]
        for record in sqliteResult.records {
            metadataByThread[record.threadId] = MergedMetadata(
                threadId: record.threadId,
                title: record.title,
                projectDirectory: record.projectDirectory,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
            if let tokenUsage = record.tokenUsage {
                sqliteTokenUsageByThread[record.threadId] = tokenUsage
            }
        }

        var statusByThread: [String: TaskStatusRecord] = [:]
        var rolloutTokenUsageByThread: [String: TokenUsageSnapshot] = [:]
        for record in rolloutResult.records {
            var metadata = metadataByThread[record.metadata.threadId] ?? MergedMetadata(
                threadId: record.metadata.threadId,
                title: "",
                projectDirectory: record.metadata.projectDirectory,
                createdAt: record.metadata.createdAt,
                updatedAt: record.status.updatedAt
            )
            if let title = record.title, !title.isEmpty {
                metadata.title = title
            }
            if metadata.projectDirectory.isEmpty {
                metadata.projectDirectory = record.metadata.projectDirectory
            }
            metadata.createdAt = min(metadata.createdAt, record.metadata.createdAt)
            metadata.updatedAt = max(metadata.updatedAt, record.status.updatedAt)
            metadataByThread[record.metadata.threadId] = metadata
            statusByThread[record.metadata.threadId] = mergedStatus(
                current: statusByThread[record.metadata.threadId],
                incoming: record.status
            )
            if let tokenUsage = record.status.tokenUsage {
                let existing = rolloutTokenUsageByThread[record.metadata.threadId]
                if existing == nil || tokenUsage.totalTokens >= (existing?.totalTokens ?? 0) {
                    rolloutTokenUsageByThread[record.metadata.threadId] = tokenUsage
                }
            }
        }

        let rateLimits = consolidatedRateLimits(
            rolloutResult.records.compactMap(\.status.rateLimits),
            now: now
        )

        let verifiedThreadIDs = Set(metadataByThread.keys)
        for record in journalResult.records where verifiedThreadIDs.contains(record.threadId) {
            if var metadata = metadataByThread[record.threadId] {
                if metadata.projectDirectory.isEmpty {
                    metadata.projectDirectory = record.projectDirectory
                }
                metadata.updatedAt = max(metadata.updatedAt, record.status.updatedAt)
                metadataByThread[record.threadId] = metadata
            }
            statusByThread[record.threadId] = mergedJournalStatus(
                current: statusByThread[record.threadId],
                incoming: record.status
            )
        }

        var tasks: [PulseTask] = []
        for (threadId, status) in statusByThread {
            guard let metadata = metadataByThread[threadId] else { continue }
            if status.isStaleRunning(at: now, cutoff: runningStaleInterval) {
                continue
            }
            let completionDate = status.completedAt ?? status.updatedAt
            if status.state.isTerminal,
               now.timeIntervalSince(completionDate) > terminalRetentionInterval
            {
                continue
            }
            let taskID = PulseTask.makeID(threadId: threadId, turnId: status.turnId)
            let isUnread = status.state == .completed
                && completionDate >= receipts.baselineAt
                && !receipts.viewedTaskIDs.contains(taskID)

            let fallbackTitle = URL(fileURLWithPath: metadata.projectDirectory)
                .lastPathComponent
            let title = metadata.title.isEmpty
                ? (fallbackTitle.isEmpty ? "Codex task" : fallbackTitle)
                : metadata.title

            tasks.append(PulseTask(
                threadId: threadId,
                turnId: status.turnId,
                title: title,
                projectDirectory: metadata.projectDirectory,
                state: status.state,
                startedAt: status.startedAt,
                updatedAt: status.updatedAt,
                completedAt: status.completedAt,
                lastStatus: status.lastStatus,
                isUnread: isUnread,
                tokenUsage: rolloutTokenUsageByThread[threadId]
                    ?? sqliteTokenUsageByThread[threadId]
            ))
        }

        let retainedTerminalIDs = Set(
            tasks.lazy
                .filter { $0.state.isTerminal }
                .sorted { lhs, rhs in
                    if lhs.isUnread != rhs.isUnread { return lhs.isUnread }
                    let leftDate = lhs.completedAt ?? lhs.updatedAt
                    let rightDate = rhs.completedAt ?? rhs.updatedAt
                    if leftDate != rightDate { return leftDate > rightDate }
                    return lhs.id < rhs.id
                }
                .prefix(max(0, terminalLimit))
                .map(\.id)
        )
        tasks.removeAll { task in
            task.state.isTerminal && !retainedTerminalIDs.contains(task.id)
        }

        tasks.sort { lhs, rhs in
            let leftPriority = groupPriority(lhs.state.group)
            let rightPriority = groupPriority(rhs.state.group)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }

        return TaskSnapshot(
            tasks: tasks,
            refreshedAt: now,
            health: health,
            rateLimits: rateLimits
        )
    }

    func markViewed(_ task: PulseTask, at date: Date = .now) async throws {
        try await receiptStore.markViewed(task, at: date)
    }

    private func mergedStatus(
        current: TaskStatusRecord?,
        incoming: TaskStatusRecord
    ) -> TaskStatusRecord {
        guard let current else { return incoming }

        let sameTurn = current.turnId == incoming.turnId
            || current.turnId == nil
            || incoming.turnId == nil
        if sameTurn,
           incoming.state == .completed,
           current.state.isTerminal
        {
            return current
        }
        if sameTurn,
           current.state == .completed,
           incoming.state.isTerminal
        {
            return incoming
        }
        return incoming.updatedAt >= current.updatedAt ? incoming : current
    }

    private func mergedJournalStatus(
        current: TaskStatusRecord?,
        incoming: TaskStatusRecord
    ) -> TaskStatusRecord {
        guard let current else { return incoming }
        let sameTurn = current.turnId == incoming.turnId
            || current.turnId == nil
            || incoming.turnId == nil
        if sameTurn, current.state.isTerminal {
            return current
        }
        return incoming.updatedAt >= current.updatedAt ? incoming : current
    }

    private func groupPriority(_ group: PulseTaskGroup) -> Int {
        PulseTaskGroup.displayOrder.firstIndex(of: group) ?? Int.max
    }

    private func consolidatedRateLimits(
        _ snapshots: [RateLimitSnapshot],
        now: Date
    ) -> RateLimitSnapshot? {
        let fiveHour = mostRestrictiveWindow(
            in: snapshots,
            at: \RateLimitSnapshot.fiveHour,
            now: now
        )
        let weekly = mostRestrictiveWindow(
            in: snapshots,
            at: \RateLimitSnapshot.weekly,
            now: now
        )
        guard fiveHour != nil || weekly != nil else { return nil }

        let selectedSnapshots = [fiveHour?.snapshot, weekly?.snapshot].compactMap { $0 }
        let oldestSelectedUpdate = selectedSnapshots.map(\.updatedAt).min() ?? now
        let planType = selectedSnapshots
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap(\.planType)
            .first

        return RateLimitSnapshot(
            fiveHour: fiveHour?.window,
            weekly: weekly?.window,
            updatedAt: oldestSelectedUpdate,
            planType: planType
        )
    }

    private func mostRestrictiveWindow(
        in snapshots: [RateLimitSnapshot],
        at keyPath: KeyPath<RateLimitSnapshot, RateLimitWindowSnapshot?>,
        now: Date
    ) -> (snapshot: RateLimitSnapshot, window: RateLimitWindowSnapshot)? {
        snapshots.compactMap { snapshot in
            guard let window = snapshot[keyPath: keyPath], window.resetsAt > now else {
                return nil
            }
            return (snapshot, window)
        }
        .max { lhs, rhs in
            if lhs.window.usedPercent != rhs.window.usedPercent {
                return lhs.window.usedPercent < rhs.window.usedPercent
            }
            return lhs.snapshot.updatedAt < rhs.snapshot.updatedAt
        }
    }

    private func replaceHealth(
        in health: inout [AdapterHealth],
        with replacement: AdapterHealth
    ) {
        health.removeAll { $0.adapter == replacement.adapter }
        health.append(replacement)
    }

    private func safeMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }
        return "Adapter unavailable"
    }
}
