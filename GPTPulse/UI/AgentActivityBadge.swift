import SwiftUI

struct AgentActivityBadge: View {
    let observation: AgentActivityObservation
    let taskState: PulseTaskState
    let now: Date

    private var presentation: AgentActivityBadgePresentation {
        AgentActivityBadgePresentation(
            observation: observation,
            taskState: taskState,
            now: now
        )
    }

    var body: some View {
        if presentation.isVisible {
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                    .accessibilityHidden(true)

                Text(presentation.displayText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if presentation.showsFreshnessWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(backgroundColor, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(borderColor, lineWidth: 1)
            }
            .help(presentation.helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
        }
    }

    private var foregroundColor: Color {
        switch presentation.emphasis {
        case .neutral:
            return .secondary
        case .warning:
            return .orange
        case .unavailable:
            return .secondary
        }
    }

    private var backgroundColor: Color {
        switch presentation.emphasis {
        case .neutral:
            return Color.white.opacity(0.055)
        case .warning:
            return Color.orange.opacity(0.10)
        case .unavailable:
            return Color.white.opacity(0.035)
        }
    }

    private var borderColor: Color {
        switch presentation.emphasis {
        case .neutral:
            return Color.white.opacity(0.065)
        case .warning:
            return Color.orange.opacity(0.18)
        case .unavailable:
            return Color.white.opacity(0.05)
        }
    }
}

struct AgentActivityBadgePresentation: Equatable, Sendable {
    enum Emphasis: Equatable, Sendable {
        case neutral
        case warning
        case unavailable
    }

    let isVisible: Bool
    let displayText: String
    let emphasis: Emphasis
    let showsFreshnessWarning: Bool
    let helpText: String
    let accessibilityLabel: String

    private init(
        isVisible: Bool,
        displayText: String,
        emphasis: Emphasis,
        showsFreshnessWarning: Bool,
        helpText: String,
        accessibilityLabel: String
    ) {
        self.isVisible = isVisible
        self.displayText = displayText
        self.emphasis = emphasis
        self.showsFreshnessWarning = showsFreshnessWarning
        self.helpText = helpText
        self.accessibilityLabel = accessibilityLabel
    }

    init(
        observation: AgentActivityObservation,
        taskState: PulseTaskState,
        now: Date
    ) {
        let count = observation.activeCount.map { max(0, $0) }

        if taskState.isTerminal, count == 0, observation.confidence != .unavailable {
            self = Self.hidden
            return
        }

        switch observation.confidence {
        case .exact:
            guard let count else {
                self = Self.unavailable
                return
            }
            let isActiveZeroAnomaly = !taskState.isTerminal && count == 0
            let hasActiveAgentAfterTerminal = taskState.isTerminal && count > 0
            let emphasis: Emphasis = isActiveZeroAnomaly || hasActiveAgentAfterTerminal
                ? .warning
                : .neutral
            let helpText: String

            if isActiveZeroAnomaly {
                helpText = "当前观测到 0 个活跃 Agent；活动任务通常至少包含主 Agent，请稍后刷新。"
            } else if hasActiveAgentAfterTerminal {
                helpText = "主任务已结束，但仍有 \(count) 个 Agent 未结束。"
            } else {
                helpText = Self.currentHelpText(count: count)
            }

            self.init(
                isVisible: true,
                displayText: "Agent \(count)",
                emphasis: emphasis,
                showsFreshnessWarning: false,
                helpText: helpText,
                accessibilityLabel: helpText
            )

        case .provisional:
            guard let count else {
                self.init(
                    isVisible: true,
                    displayText: "Agent …",
                    emphasis: .neutral,
                    showsFreshnessWarning: false,
                    helpText: "正在确认该任务的 Agent 状态。",
                    accessibilityLabel: "正在确认该任务的 Agent 状态"
                )
                return
            }
            let hasActiveAgentAfterTerminal = taskState.isTerminal && count > 0
            let helpText = hasActiveAgentAfterTerminal
                ? "主任务已结束，但观测到约 \(count) 个 Agent 仍未结束；数据仍在确认中。"
                : "当前约有 \(count) 个活跃 Agent，数据仍在确认中；等待授权或回答也计入。"
            self.init(
                isVisible: true,
                displayText: "Agent ~\(count)",
                emphasis: hasActiveAgentAfterTerminal ? .warning : .neutral,
                showsFreshnessWarning: false,
                helpText: helpText,
                accessibilityLabel: helpText
            )

        case .stale:
            guard let count else {
                self.init(
                    isVisible: true,
                    displayText: "Agent —",
                    emphasis: .warning,
                    showsFreshnessWarning: true,
                    helpText: "Agent 数据已过期，且没有可用的历史观测值。",
                    accessibilityLabel: "Agent 状态不可用，数据已过期"
                )
                return
            }
            let ageText = observation.observedAt.pulseRelativeDescription(asOf: now)
            let helpText = "上次观测到 \(count) 个活跃 Agent，更新于 \(ageText)；当前数据可能已过期。"
            self.init(
                isVisible: true,
                displayText: "Agent \(count)",
                emphasis: .warning,
                showsFreshnessWarning: true,
                helpText: helpText,
                accessibilityLabel: helpText
            )

        case .unavailable:
            self = Self.unavailable
        }
    }

    private static let hidden = AgentActivityBadgePresentation(
        isVisible: false,
        displayText: "",
        emphasis: .neutral,
        showsFreshnessWarning: false,
        helpText: "",
        accessibilityLabel: ""
    )

    private static let unavailable = AgentActivityBadgePresentation(
        isVisible: true,
        displayText: "Agent —",
        emphasis: .unavailable,
        showsFreshnessWarning: false,
        helpText: "暂时无法读取该任务的 Agent 状态。",
        accessibilityLabel: "Agent 状态暂时不可用"
    )

    private static func currentHelpText(count: Int) -> String {
        if count == 0 {
            return "当前没有未结束的 Agent。"
        }
        return "当前有 \(count) 个活跃 Agent，包含主 Agent 和所有层级子 Agent；等待授权或回答也计入。"
    }
}
