import Foundation

extension PulseTask {
    var projectDisplayName: String {
        ProjectDirectoryIdentityResolver.resolve(projectDirectory)
    }

    var projectIdentityDirectory: String {
        ProjectDirectoryIdentityResolver.identityDirectory(projectDirectory)
    }

    var displayStatusText: String {
        switch lastStatus {
        case "running":
            return "正在执行"
        case "waitingForApproval":
            return "等待你授权"
        case "waitingForAnswer":
            return "等待你回答"
        case "finalizing":
            return "正在整理结果"
        case "completed":
            return "已完成"
        case "failed":
            return "执行失败"
        case "interrupted":
            return "已中断"
        default:
            return lastStatus
        }
    }
}

extension TokenUsageSnapshot {
    var compactTotalText: String {
        Self.compactTokenCount(totalTokens)
    }

    var hasBreakdown: Bool {
        inputTokens != nil
            || cachedInputTokens != nil
            || outputTokens != nil
            || reasoningOutputTokens != nil
    }

    static func compactTokenCount(_ count: Int?) -> String {
        guard let count else { return "—" }

        let value = max(0, count)
        if value < 1_000 { return "\(value)" }

        let suffixes = ["", "k", "m", "b"]
        var scaled = Double(value)
        var unitIndex = 0
        while scaled >= 1_000, unitIndex < suffixes.count - 1 {
            scaled /= 1_000
            unitIndex += 1
        }

        var rounded = (scaled * 10).rounded() / 10
        if rounded >= 1_000, unitIndex < suffixes.count - 1 {
            rounded /= 1_000
            unitIndex += 1
        }
        return compactDecimal(rounded) + suffixes[unitIndex]
    }

    private static func compactDecimal(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

extension RateLimitWindowSnapshot {
    func remainingPercent(asOf date: Date = .now) -> Double? {
        guard resetsAt > date else { return nil }
        return min(100, max(0, 100 - usedPercent))
    }
}

extension Date {
    func pulseQuotaResetDescription(
        asOf _: Date = .now,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "重置 " + formatter.string(from: self)
    }
}

enum ProjectDirectoryIdentityResolver {
    private final class CachedResolution: NSObject {
        let identityDirectory: String
        let displayName: String

        init(identityDirectory: String, displayName: String) {
            self.identityDirectory = identityDirectory
            self.displayName = displayName
        }
    }

    // SwiftUI can ask for a task's presentation several times per render pass.
    // Cache the filesystem-backed Git-root lookup by cwd so row rendering stays
    // a cheap in-memory operation after the first resolution.
    // NSCache is documented as safe for concurrent access. Swift does not
    // currently model that guarantee with Sendable, so keep the escape hatch
    // narrowly scoped to this immutable cache reference.
    nonisolated(unsafe) private static let cache = NSCache<NSString, CachedResolution>()

    static func resolve(_ projectDirectory: String) -> String {
        resolution(for: projectDirectory).displayName
    }

    static func identityDirectory(_ projectDirectory: String) -> String {
        resolution(for: projectDirectory).identityDirectory
    }

    private static func resolution(for projectDirectory: String) -> CachedResolution {
        let cacheKey = projectDirectory as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let identity = resolveIdentityDirectory(projectDirectory)
        let lastPathComponent = identity.isEmpty
            ? ""
            : URL(fileURLWithPath: identity).lastPathComponent
        let displayName = lastPathComponent.isEmpty ? "未识别项目" : lastPathComponent
        let result = CachedResolution(
            identityDirectory: identity,
            displayName: displayName
        )
        cache.setObject(result, forKey: cacheKey)
        return result
    }

    private static func resolveIdentityDirectory(_ projectDirectory: String) -> String {
        guard !projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }

        let standardized = URL(fileURLWithPath: projectDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var candidate = standardized
        guard candidate.path != "/" else { return "" }

        while true {
            let gitMarker = candidate.appendingPathComponent(".git", isDirectory: false)
            if FileManager.default.fileExists(atPath: gitMarker.path),
               !candidate.lastPathComponent.isEmpty {
                return candidate.path
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }

        return standardized.path
    }
}

extension AdapterHealth {
    var displayMessage: String {
        switch adapter {
        case .appServer:
            return "Codex 本地协议暂不可用，当前使用兼容数据源"
        case .sqlite:
            return "无法读取 Codex 本地任务索引"
        case .rolloutJSONL:
            return "无法读取 Codex 任务事件记录"
        case .pluginJournal:
            return "插件事件日志尚未生成，当前使用兼容数据源"
        case .receipts:
            return "未查看状态暂时无法保存"
        }
    }
}

extension Date {
    func pulseRelativeDescription(asOf now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(self)))

        if seconds < 10 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟前" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }

        let days = hours / 24
        if days < 30 { return "\(days) 天前" }

        return formatted(
            .dateTime
                .year()
                .month()
                .day()
                .locale(Locale(identifier: "zh_CN"))
        )
    }
}
