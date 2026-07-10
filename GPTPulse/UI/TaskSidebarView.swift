import SwiftUI

struct TaskSidebarView: View {
    @ObservedObject var monitor: TaskMonitor

    let onOpenTask: (PulseTask) -> Bool
    let onMarkViewed: (PulseTask) -> Void
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    @FocusState private var focusedTaskID: String?
    @State private var openErrorMessage: String?
    @State private var expandedTaskIDs: Set<String> = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var snapshot: TaskSnapshot { monitor.snapshot }

    private var runningTasks: [PulseTask] {
        snapshot.tasks
            .filter { !$0.state.isTerminal }
            .sorted(by: runningTaskSort)
    }

    private var recentTasks: [PulseTask] {
        snapshot.tasks
            .filter { $0.state.isTerminal }
            .sorted(by: recentTaskSort)
    }

    private var relevantTaskCount: Int {
        runningTasks.count + recentTasks.count
    }

    private var isInitialLoading: Bool {
        snapshot.refreshedAt == .distantPast && snapshot.health.isEmpty
    }

    private var unavailableHealth: [AdapterHealth] {
        snapshot.actionableHealth.filter { $0.status == .unavailable }
    }

    private var degradedHealth: [AdapterHealth] {
        snapshot.actionableHealth.filter { $0.status == .degraded }
    }

    private var hasHealthyStatusAdapter: Bool {
        snapshot.health.contains {
            ($0.adapter == .appServer
                || $0.adapter == .rolloutJSONL
                || $0.adapter == .pluginJournal)
                && $0.status == .healthy
        }
    }

    private var shouldShowHealthNotice: Bool {
        (!degradedHealth.isEmpty || !unavailableHealth.isEmpty)
            && (relevantTaskCount > 0 || hasHealthyStatusAdapter)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)

            if let openErrorMessage {
                openErrorBanner(openErrorMessage)
                Divider().opacity(0.45)
            }

            RateLimitCard(rateLimits: snapshot.rateLimits)
                .padding(.horizontal, 16)
                .padding(.top, 7)
                .padding(.bottom, 7)

            if shouldShowHealthNotice {
                healthNotice
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            Group {
                if isInitialLoading {
                    loadingState
                } else if relevantTaskCount == 0
                    && !unavailableHealth.isEmpty
                    && !hasHealthyStatusAdapter {
                    errorState
                } else if relevantTaskCount == 0 {
                    emptyState
                } else {
                    taskContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.45)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.34)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: focusFirstTask)
        .onChange(of: snapshot.tasks) { _, _ in
            preserveValidFocusAndExpansion()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GPT Pulse")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .tracking(-0.35)

                Text(statusSummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("立即刷新")
            .accessibilityLabel("刷新任务和额度")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help("关闭侧边栏")
            .accessibilityLabel("关闭侧边栏")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func openErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .padding(.top, 1)
                .accessibilityHidden(true)

            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button {
                openErrorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("关闭错误提示")
            .accessibilityLabel("关闭错误提示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.09))
        .accessibilityElement(children: .contain)
    }

    private var taskContent: some View {
        ScrollView {
            LazyVStack(spacing: 15) {
                TaskGroupSection(
                    descriptor: .running,
                    tasks: runningTasks,
                    focusedTaskID: $focusedTaskID,
                    expandedTaskIDs: expandedTaskIDs,
                    onOpenTask: openTask,
                    onToggleExpanded: toggleExpanded,
                    onMarkViewed: onMarkViewed
                )

                TaskGroupSection(
                    descriptor: .recent,
                    tasks: recentTasks,
                    focusedTaskID: $focusedTaskID,
                    expandedTaskIDs: expandedTaskIDs,
                    onOpenTask: openTask,
                    onToggleExpanded: toggleExpanded,
                    onMarkViewed: onMarkViewed
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.visible)
    }

    private var healthNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("部分数据源暂不可用")
                    .font(.caption.weight(.semibold))
                Text(healthSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.yellow.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取 Codex 任务…")
                .font(.subheadline.weight(.medium))
            Text("任务和额度数据只从本机读取")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在读取 Codex 桌面版任务和额度")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂时没有任务", systemImage: "checkmark.circle")
        } description: {
            Text("正在运行、等待操作和最近完成的任务会显示在这里。")
        } actions: {
            Button("重新检查") {
                monitor.refresh()
            }
        }
    }

    private var errorState: some View {
        ContentUnavailableView {
            Label("暂时无法读取任务", systemImage: "exclamationmark.triangle")
        } description: {
            Text(healthSummary)
        } actions: {
            Button("重试") {
                monitor.refresh()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(footerHealthColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(footerStatusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(action: onOpenSettings) {
                Label("设置", systemImage: "gearshape")
                    .font(.caption.weight(.medium))
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("打开 GPT Pulse 设置")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var statusSummary: String {
        "\(snapshot.activeCount) 个运行中 · \(snapshot.recentCompletedCount) 个最近完成"
    }

    private var healthSummary: String {
        let messages = (unavailableHealth + degradedHealth).map(\.displayMessage)
        return messages.isEmpty ? "Codex 数据源没有响应，请稍后重试。" : messages.joined(separator: "；")
    }

    private var footerHealthColor: Color {
        if !unavailableHealth.isEmpty { return .red }
        if !degradedHealth.isEmpty { return .yellow }
        return .green
    }

    private var footerStatusText: String {
        let healthText: String
        if !unavailableHealth.isEmpty {
            healthText = "数据异常"
        } else if !degradedHealth.isEmpty {
            healthText = "数据降级"
        } else {
            healthText = "数据健康"
        }

        guard snapshot.refreshedAt != .distantPast else {
            return healthText + " · 待刷新"
        }
        return healthText + " · 更新于 " + snapshot.refreshedAt.pulseRelativeDescription()
    }

    private func runningTaskSort(_ lhs: PulseTask, _ rhs: PulseTask) -> Bool {
        let leftPriority = lhs.state.activeSortPriority
        let rightPriority = rhs.state.activeSortPriority
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private func recentTaskSort(_ lhs: PulseTask, _ rhs: PulseTask) -> Bool {
        if lhs.isUnread != rhs.isUnread { return lhs.isUnread }
        let leftDate = lhs.completedAt ?? lhs.updatedAt
        let rightDate = rhs.completedAt ?? rhs.updatedAt
        if leftDate != rightDate { return leftDate > rightDate }
        return lhs.id < rhs.id
    }

    private func focusFirstTask() {
        guard focusedTaskID == nil else { return }
        focusedTaskID = (runningTasks + recentTasks).first?.id
    }

    private func preserveValidFocusAndExpansion() {
        let taskIDs = Set((runningTasks + recentTasks).map(\.id))
        if let focusedTaskID, !taskIDs.contains(focusedTaskID) {
            self.focusedTaskID = (runningTasks + recentTasks).first?.id
        }
        expandedTaskIDs.formIntersection(taskIDs)
    }

    private func toggleExpanded(_ task: PulseTask) {
        let update = {
            if expandedTaskIDs.contains(task.id) {
                expandedTaskIDs.remove(task.id)
            } else {
                expandedTaskIDs.insert(task.id)
            }
        }

        if reduceMotion {
            update()
        } else {
            withAnimation(.easeOut(duration: 0.18), update)
        }
    }

    private func openTask(_ task: PulseTask) {
        if onOpenTask(task) {
            openErrorMessage = nil
        } else {
            openErrorMessage = "无法在 Codex 中打开“\(task.title)”。请确认 Codex 桌面版已安装并可用。"
        }
    }
}

private struct RateLimitCard: View {
    let rateLimits: RateLimitSnapshot?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                QuotaWindowRow(
                    title: "5h 余额",
                    helpText: "最近 5 小时额度的剩余比例",
                    window: rateLimits?.fiveHour,
                    asOf: context.date
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 7)

                Divider()
                    .opacity(0.38)
                    .padding(.horizontal, 14)

                QuotaWindowRow(
                    title: "本周余额",
                    helpText: "本周额度的剩余比例",
                    window: rateLimits?.weekly,
                    asOf: context.date
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 7)

                Divider().opacity(0.38)

                Text(freshnessText(asOf: context.date))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
            }
        }
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func freshnessText(asOf date: Date) -> String {
        guard let rateLimits else { return "额度待刷新" }
        let hasCurrentWindow = [rateLimits.fiveHour, rateLimits.weekly]
            .compactMap { $0 }
            .contains { $0.remainingPercent(asOf: date) != nil }
        guard hasCurrentWindow else { return "额度待刷新" }
        return "更新于 " + rateLimits.updatedAt.pulseRelativeDescription(asOf: date)
    }
}

private struct QuotaWindowRow: View {
    let title: String
    let helpText: String
    let window: RateLimitWindowSnapshot?
    let asOf: Date

    private var remainingPercent: Double? {
        window?.remainingPercent(asOf: asOf)
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Image(systemName: "info.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .help(helpText)
                    .accessibilityHidden(true)
            }
            .frame(width: 72, alignment: .leading)

            ProgressView(value: remainingPercent ?? 0, total: 100)
                .tint(remainingPercent == nil ? Color.secondary.opacity(0.35) : Color.accentColor)
                .opacity(remainingPercent == nil ? 0.55 : 1)
                .accessibilityLabel(title)
                .accessibilityValue(balanceText)

            Text(balanceText)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(remainingPercent == nil ? Color.secondary : Color.accentColor)
                .frame(width: 66, alignment: .trailing)

            Text(resetText)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 84, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var balanceText: String {
        guard let remainingPercent else { return "待刷新" }
        return "\(Int(remainingPercent.rounded()))% 剩余"
    }

    private var resetText: String {
        guard remainingPercent != nil, let window else { return "—" }
        return window.resetsAt.pulseQuotaResetDescription(asOf: asOf)
    }
}

private struct TaskGroupSection: View {
    let descriptor: TaskGroupDescriptor
    let tasks: [PulseTask]
    let focusedTaskID: FocusState<String?>.Binding
    let expandedTaskIDs: Set<String>
    let onOpenTask: (PulseTask) -> Void
    let onToggleExpanded: (PulseTask) -> Void
    let onMarkViewed: (PulseTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(descriptor.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text(descriptor.title)
                    .font(.caption.weight(.semibold))

                Text("\(tasks.count)")
                    .font(.caption.weight(.semibold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)

            VStack(spacing: 0) {
                if tasks.isEmpty {
                    Text(descriptor.emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        TaskListItem(
                            task: task,
                            isExpanded: expandedTaskIDs.contains(task.id),
                            focusedTaskID: focusedTaskID,
                            onOpenTask: { onOpenTask(task) },
                            onToggleExpanded: { onToggleExpanded(task) },
                            onMarkViewed: { onMarkViewed(task) }
                        )

                        if index < tasks.index(before: tasks.endIndex) {
                            Divider()
                                .opacity(0.42)
                                .padding(.leading, 50)
                        }
                    }
                }
            }
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            }
        }
    }
}

private struct TaskListItem: View {
    let task: PulseTask
    let isExpanded: Bool
    let focusedTaskID: FocusState<String?>.Binding
    let onOpenTask: () -> Void
    let onToggleExpanded: () -> Void
    let onMarkViewed: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var canExpand: Bool {
        task.tokenUsage?.hasBreakdown == true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onOpenTask) {
                    TaskRowSummary(task: task)
                        .padding(.leading, 10)
                        .padding(.vertical, 8)
                        .padding(.trailing, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .focused(focusedTaskID, equals: task.id)
                .accessibilityLabel(task.accessibilityLabel)
                .accessibilityHint("打开 Codex 并定位到此任务")

                if canExpand {
                    Button(action: onToggleExpanded) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .frame(width: 32, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(isExpanded ? "收起 token 明细" : "展开 token 明细")
                    .accessibilityLabel(isExpanded ? "收起 token 明细" : "展开 token 明细")
                }

                if task.state == .completed, task.isUnread {
                    Button(action: onMarkViewed) {
                        Image(systemName: "eye")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 32, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                    .help("标记为已查看")
                    .accessibilityLabel("将 \(task.title) 标记为已查看")
                }
            }

            if isExpanded, let tokenUsage = task.tokenUsage {
                TokenBreakdownView(tokenUsage: tokenUsage)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(reduceMotion
                        ? .identity
                        : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            ZStack {
                if isExpanded {
                    Color.accentColor.opacity(0.085)
                }
                if isHovering {
                    Color.white.opacity(0.035)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    focusedTaskID.wrappedValue == task.id
                        ? Color.accentColor.opacity(0.82)
                        : Color.clear,
                    lineWidth: 1.5
                )
                .padding(2)
        }
        .onHover { isHovering = $0 }
    }
}

private struct TaskRowSummary: View {
    let task: PulseTask

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(task.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            stateIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(task.projectDisplayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(task.state.tintColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(task.projectDirectory.isEmpty ? "未识别项目路径" : task.projectDirectory)

                Text(task.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(task.state.tintColor)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)

                        Text(task.rowStatusText)
                            .foregroundStyle(task.state.tintColor)

                        Text("·")

                        Text(task.activityDate.pulseRelativeDescription(asOf: context.date))
                            .lineLimit(1)
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if let tokenUsage = task.tokenUsage {
                Text(tokenUsage.totalTokens > 0 ? tokenUsage.compactTotalText + " tokens" : "—")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateIcon: some View {
        ZStack {
            Circle()
                .fill(task.state.tintColor.opacity(0.13))
            Image(systemName: task.state.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(task.state.tintColor)
        }
        .frame(width: 28, height: 28)
        .symbolEffect(
            .pulse,
            options: .repeating,
            isActive: task.state == .running && !reduceMotion
        )
        .accessibilityHidden(true)
    }
}

private struct TokenBreakdownView: View {
    let tokenUsage: TokenUsageSnapshot

    private var items: [TokenBreakdownItem] {
        [
            TokenBreakdownItem(
                title: "输入",
                value: tokenUsage.inputTokens,
                subsetLabel: nil
            ),
            TokenBreakdownItem(
                title: "缓存命中",
                value: tokenUsage.cachedInputTokens,
                subsetLabel: "输入子集"
            ),
            TokenBreakdownItem(
                title: "输出",
                value: tokenUsage.outputTokens,
                subsetLabel: nil
            ),
            TokenBreakdownItem(
                title: "推理",
                value: tokenUsage.reasoningOutputTokens,
                subsetLabel: "输出子集"
            ),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                VStack(spacing: 3) {
                    Text(item.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text(TokenUsageSnapshot.compactTokenCount(item.value))
                        .font(.callout.weight(.medium))
                        .monospacedDigit()

                    Text(item.subsetLabel ?? " ")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)

                if index < items.index(before: items.endIndex) {
                    Divider()
                        .frame(height: 38)
                        .opacity(0.5)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.19), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        "Token 明细，输入 \(TokenUsageSnapshot.compactTokenCount(tokenUsage.inputTokens))，"
            + "缓存命中 \(TokenUsageSnapshot.compactTokenCount(tokenUsage.cachedInputTokens))，缓存命中属于输入子集，"
            + "输出 \(TokenUsageSnapshot.compactTokenCount(tokenUsage.outputTokens))，"
            + "推理 \(TokenUsageSnapshot.compactTokenCount(tokenUsage.reasoningOutputTokens))，推理属于输出子集"
    }
}

private struct TokenBreakdownItem {
    let title: String
    let value: Int?
    let subsetLabel: String?
}

private struct TaskGroupDescriptor {
    let title: String
    let color: Color
    let emptyMessage: String

    static let running = TaskGroupDescriptor(
        title: "正在运行",
        color: .blue,
        emptyMessage: "没有正在运行或等待操作的任务"
    )

    static let recent = TaskGroupDescriptor(
        title: "最近完成",
        color: .green,
        emptyMessage: "还没有最近完成的任务"
    )
}

private extension PulseTaskState {
    var activeSortPriority: Int {
        switch self {
        case .waitingForApproval:
            return 0
        case .waitingForAnswer:
            return 1
        case .running:
            return 2
        case .failed, .interrupted, .completed:
            return 3
        }
    }

    var tintColor: Color {
        switch self {
        case .running:
            return .blue
        case .waitingForApproval, .waitingForAnswer:
            return .orange
        case .completed:
            return .green
        case .failed, .interrupted:
            return .red
        }
    }

    var symbol: String {
        switch self {
        case .running:
            return "bolt.fill"
        case .waitingForApproval:
            return "clock.fill"
        case .waitingForAnswer:
            return "questionmark.bubble.fill"
        case .completed:
            return "checkmark"
        case .failed:
            return "xmark"
        case .interrupted:
            return "exclamationmark"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .running:
            return "正在执行"
        case .waitingForApproval:
            return "等待授权"
        case .waitingForAnswer:
            return "等待回答"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .interrupted:
            return "已中断"
        }
    }
}

private extension PulseTask {
    var activityDate: Date {
        completedAt ?? updatedAt
    }

    var rowStatusText: String {
        displayStatusText.isEmpty ? state.accessibilityDescription : displayStatusText
    }

    var accessibilityLabel: String {
        var components = [
            "项目 \(projectDisplayName)",
            "任务 \(title)",
            state.accessibilityDescription,
            activityDate.pulseRelativeDescription(),
        ]
        if isUnread {
            components.append("未查看")
        }
        if let tokenUsage {
            components.append("共 \(tokenUsage.compactTotalText) tokens")
        }
        return components.joined(separator: "，")
    }
}
