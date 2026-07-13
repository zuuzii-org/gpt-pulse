import Foundation

actor CodexRolloutAdapter {
    private struct CachedRollout: Sendable {
        let fileSize: Int
        let modificationDate: Date
        let metadata: RolloutMetadata?
        let status: TaskStatusRecord?
        let wasInvalid: Bool
    }

    private let sessionsDirectory: URL
    private let sessionIndexURL: URL
    private let metadataReader: RolloutMetadataReader
    private let tailParser: RolloutJSONLTailParser
    private let sessionIndexReader: SessionIndexReader
    private let lookback: TimeInterval
    private let discoveryInterval: TimeInterval

    private var cachedRollouts: [URL: CachedRollout] = [:]
    private var discoveredURLs: Set<URL> = []
    private var lastDiscoveryAt: Date = .distantPast
    private var cachedTitles: [String: String] = [:]
    private var sessionIndexModificationDate: Date?

    init(
        sessionsDirectory: URL,
        sessionIndexURL: URL,
        metadataReader: RolloutMetadataReader = RolloutMetadataReader(),
        tailParser: RolloutJSONLTailParser = RolloutJSONLTailParser(),
        sessionIndexReader: SessionIndexReader = SessionIndexReader(),
        lookback: TimeInterval = 30 * 24 * 60 * 60,
        discoveryInterval: TimeInterval = 5
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.sessionIndexURL = sessionIndexURL
        self.metadataReader = metadataReader
        self.tailParser = tailParser
        self.sessionIndexReader = sessionIndexReader
        self.lookback = lookback
        self.discoveryInterval = discoveryInterval
    }

    func loadDesktopRootTasks(
        additionalRolloutURLs: [URL] = [],
        now: Date = .now
    ) throws -> RolloutTaskReadResult {
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else {
            throw DataAdapterError.missingFile(sessionsDirectory)
        }

        if now.timeIntervalSince(lastDiscoveryAt) >= discoveryInterval {
            discoveredURLs = try discoverRecentRollouts(now: now)
            lastDiscoveryAt = now
        }

        let titlesAvailable = refreshTitlesIfNeeded()
        let candidates = discoveredURLs.union(additionalRolloutURLs)
        var records: [RolloutTaskRecord] = []
        var invalidFileCount = 0

        for url in candidates {
            guard url.pathExtension == "jsonl" else { continue }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch {
                invalidFileCount += 1
                continue
            }

            let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
            let cached: CachedRollout

            if let existing = cachedRollouts[url],
               existing.fileSize == fileSize,
               existing.modificationDate == modificationDate
            {
                cached = CachedRollout(
                    fileSize: existing.fileSize,
                    modificationDate: existing.modificationDate,
                    metadata: existing.metadata,
                    status: tailParser.reevaluate(
                        existing.status,
                        fileModificationDate: modificationDate,
                        now: now
                    ),
                    wasInvalid: existing.wasInvalid
                )
            } else if let existing = cachedRollouts[url],
                      fileSize > existing.fileSize,
                      !existing.wasInvalid
            {
                do {
                    if let metadata = existing.metadata {
                        let growth = fileSize - existing.fileSize
                        let maximumIncrement = 64 * 1_024 * 1_024
                        let fallbackTail = 16 * 1_024 * 1_024
                        let offset = growth <= maximumIncrement
                            ? existing.fileSize
                            : max(existing.fileSize, fileSize - fallbackTail)
                        let appendedData = try readData(
                            from: url,
                            offset: offset,
                            discardPartialFirstLine: offset != existing.fileSize
                        )
                        let status = tailParser.parse(
                            threadId: metadata.threadId,
                            defaultStartedAt: metadata.createdAt,
                            tail: appendedData,
                            fileModificationDate: modificationDate,
                            now: now,
                            initialStatus: existing.status
                        )
                        cached = CachedRollout(
                            fileSize: fileSize,
                            modificationDate: modificationDate,
                            metadata: metadata,
                            status: status,
                            wasInvalid: false
                        )
                    } else {
                        cached = CachedRollout(
                            fileSize: fileSize,
                            modificationDate: modificationDate,
                            metadata: nil,
                            status: nil,
                            wasInvalid: false
                        )
                    }
                } catch {
                    cached = CachedRollout(
                        fileSize: existing.fileSize,
                        modificationDate: existing.modificationDate,
                        metadata: existing.metadata,
                        status: existing.status,
                        wasInvalid: false
                    )
                }
            } else {
                do {
                    let metadata = try metadataReader.readDesktopRoot(from: url)
                    let status = try metadata.flatMap {
                        try tailParser.parse(
                            threadId: $0.threadId,
                            defaultStartedAt: $0.createdAt,
                            from: url,
                            now: now
                        )
                    }
                    cached = CachedRollout(
                        fileSize: fileSize,
                        modificationDate: modificationDate,
                        metadata: metadata,
                        status: status,
                        wasInvalid: false
                    )
                } catch {
                    cached = CachedRollout(
                        fileSize: fileSize,
                        modificationDate: modificationDate,
                        metadata: nil,
                        status: nil,
                        wasInvalid: true
                    )
                }
            }
            cachedRollouts[url] = cached

            if cached.wasInvalid {
                invalidFileCount += 1
            }
            guard let metadata = cached.metadata, let status = cached.status else {
                continue
            }

            records.append(RolloutTaskRecord(
                metadata: metadata,
                title: cachedTitles[metadata.threadId],
                status: status
            ))
        }

        return RolloutTaskReadResult(
            records: records,
            invalidFileCount: invalidFileCount,
            sessionIndexAvailable: titlesAvailable
        )
    }

    private func readData(
        from url: URL,
        offset: Int,
        discardPartialFirstLine: Bool
    ) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        let data = try file.readToEnd() ?? Data()

        guard discardPartialFirstLine,
              let newline = data.firstIndex(of: 0x0A)
        else {
            return data
        }
        return Data(data[data.index(after: newline)...])
    }

    private func discoverRecentRollouts(now: Date) throws -> Set<URL> {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw DataAdapterError.missingFile(sessionsDirectory)
        }

        let cutoff = now.addingTimeInterval(-lookback)
        var urls: Set<URL> = []

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
            ]) else {
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard (values.contentModificationDate ?? .distantPast) >= cutoff else { continue }
            urls.insert(url)
        }

        return urls
    }

    @discardableResult
    private func refreshTitlesIfNeeded() -> Bool {
        guard FileManager.default.fileExists(atPath: sessionIndexURL.path) else {
            cachedTitles = [:]
            sessionIndexModificationDate = nil
            return false
        }

        let attributes = try? FileManager.default.attributesOfItem(
            atPath: sessionIndexURL.path
        )
        let modificationDate = attributes?[.modificationDate] as? Date
        if modificationDate == sessionIndexModificationDate, !cachedTitles.isEmpty {
            return true
        }

        do {
            cachedTitles = try sessionIndexReader.readTitles(from: sessionIndexURL)
            sessionIndexModificationDate = modificationDate
            return true
        } catch {
            cachedTitles = [:]
            sessionIndexModificationDate = nil
            return false
        }
    }
}
