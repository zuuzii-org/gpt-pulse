import Foundation

extension PulseTask {
    var projectDisplayName: String {
        ProjectDisplayNameResolver.resolve(projectDirectory)
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
    func pulseQuotaResetDescription(asOf now: Date = .now) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone

        if calendar.isDate(self, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if self <= now.addingTimeInterval(7 * 24 * 60 * 60) {
            formatter.dateFormat = "EEE HH:mm"
        } else {
            formatter.dateFormat = "M月d日"
        }
        return "重置 " + formatter.string(from: self)
    }
}

private enum ProjectDisplayNameResolver {
    static func resolve(_ projectDirectory: String) -> String {
        guard !projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "未识别项目"
        }

        var candidate = URL(fileURLWithPath: projectDirectory).standardizedFileURL
        guard candidate.path != "/" else { return "未识别项目" }
        let fallbackName = candidate.lastPathComponent

        while true {
            let gitMarker = candidate.appendingPathComponent(".git", isDirectory: false)
            if FileManager.default.fileExists(atPath: gitMarker.path),
               !candidate.lastPathComponent.isEmpty {
                return candidate.lastPathComponent
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }

        return fallbackName.isEmpty ? "未识别项目" : fallbackName
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
