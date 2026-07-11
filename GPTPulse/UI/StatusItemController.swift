import AppKit
import Combine

enum StatusItemIndicatorState: Equatable {
    case normal
    case waitingAction
    case failure
}

enum AttentionTaskSelector {
    static func next(in tasks: [PulseTask]) -> PulseTask? {
        tasks.filter {
            $0.state == .waitingForApproval || $0.state == .waitingForAnswer
        }
        .sorted {
            if $0.state != $1.state {
                return $0.state == .waitingForApproval
            }
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.id < $1.id
        }
        .first
    }
}

struct StatusItemPresentation: Equatable {
    let activeCount: Int
    let recentCompletedCount: Int
    let waitingActionCount: Int
    let hasWaitingAction: Bool
    let hasFailures: Bool

    init(snapshot: TaskSnapshot) {
        activeCount = snapshot.activeCount
        recentCompletedCount = snapshot.recentCompletedCount
        waitingActionCount = snapshot.tasks.lazy.filter {
            $0.state == .waitingForApproval || $0.state == .waitingForAnswer
        }.count
        hasWaitingAction = waitingActionCount > 0
        hasFailures = snapshot.hasFailures
    }

    var indicatorState: StatusItemIndicatorState {
        if hasFailures { return .failure }
        if hasWaitingAction { return .waitingAction }
        return .normal
    }

    var title: String {
        "\(activeTitle)\n\(recentCompletedTitle)"
    }

    var activeTitle: String {
        Self.compactCount(activeCount)
    }

    var recentCompletedTitle: String {
        Self.compactCount(recentCompletedCount)
    }

    var accessibilityLabel: String {
        var components = [
            "正在运行 \(activeCount) 个任务",
            "最近完成 \(recentCompletedCount) 个任务",
        ]
        if hasWaitingAction {
            components.append("需要你处理 \(waitingActionCount) 个任务")
        }
        if hasFailures {
            components.append("存在失败")
        }
        return "GPT Pulse，" + components.joined(separator: "，")
    }

    var toolTip: String {
        var components = [
            "正在运行 \(activeCount)",
            "最近完成 \(recentCompletedCount)",
        ]
        if hasWaitingAction {
            components.append("需要你处理 \(waitingActionCount)")
        }
        if hasFailures {
            components.append("存在失败")
        }
        return "GPT Pulse · " + components.joined(separator: " · ")
    }

    private static func compactCount(_ count: Int) -> String {
        let normalizedCount = max(0, count)
        return normalizedCount > 99 ? "99+" : String(normalizedCount)
    }
}

@MainActor
final class StatusItemController: NSObject {
    private static let statusItemWidth: CGFloat = 42
    private static let menuIconSize = NSSize(width: 18, height: 18)
    private static let countFontSize: CGFloat = 9
    private static let countLineHeight: CGFloat = 9.5
    private static let countBaselineOffset: CGFloat = 8

    var onTogglePanel: (() -> Void)?
    var onOpenAttentionTask: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    var button: NSStatusBarButton? { statusItem.button }

    private let statusItem: NSStatusItem
    private let menuPresenter: (NSMenu, NSStatusBarButton) -> Void
    private let menu = NSMenu()
    private var attentionMenuItem: NSMenuItem?
    private var snapshotCancellable: AnyCancellable?

    init(
        monitor: TaskMonitor,
        menuPresenter: @escaping (NSMenu, NSStatusBarButton) -> Void = { menu, button in
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.minY - 4),
                in: button
            )
        }
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: Self.statusItemWidth)
        self.menuPresenter = menuPresenter
        super.init()

        configureButton()
        configureMenu()
        update(snapshot: monitor.snapshot)

        snapshotCancellable = monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.update(snapshot: snapshot)
            }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let image = NSImage.statusMenuIcon
        image.isTemplate = true
        image.size = Self.menuIconSize
        button.image = image
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        if let cell = button.cell as? NSButtonCell {
            cell.alignment = .center
            cell.usesSingleLineMode = false
            cell.wraps = true
            cell.lineBreakMode = .byClipping
        }
        button.setAccessibilityRole(.button)
        button.setAccessibilityHelp(
            "左键显示或隐藏任务面板；右键或“打开更多选项”操作显示菜单。"
        )
        button.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(
                name: "打开更多选项",
                target: self,
                selector: #selector(openMenuFromAccessibility)
            ),
        ])
    }

    private func configureMenu() {
        let attentionItem = NSMenuItem(
            title: "打开下一条需处理任务",
            action: #selector(openAttentionTask),
            keyEquivalent: ""
        )
        attentionItem.target = self
        attentionItem.isHidden = true
        menu.addItem(attentionItem)
        attentionMenuItem = attentionItem

        let openItem = NSMenuItem(
            title: "打开任务面板",
            action: #selector(openPanel),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(
            title: "立即刷新",
            action: #selector(refresh),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "退出 GPT Pulse",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func update(snapshot: TaskSnapshot) {
        guard let button = statusItem.button else { return }

        let presentation = StatusItemPresentation(snapshot: snapshot)
        button.attributedTitle = attributedTitle(for: presentation)
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        button.toolTip = presentation.toolTip
        attentionMenuItem?.isHidden = !presentation.hasWaitingAction
    }

    private func attributedTitle(for presentation: StatusItemPresentation) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping
        paragraphStyle.minimumLineHeight = Self.countLineHeight
        paragraphStyle.maximumLineHeight = Self.countLineHeight
        paragraphStyle.lineSpacing = -0.5

        let title = NSMutableAttributedString(
            string: presentation.title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: Self.countFontSize,
                    weight: .medium
                ),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
                // NSStatusBarButton reserves vertical title metrics for a
                // single line. Lift the compact two-line stack so the lower
                // glyphs retain optical padding instead of being cell-clipped.
                .baselineOffset: Self.countBaselineOffset,
            ]
        )
        title.addAttribute(
            .foregroundColor,
            value: indicatorColor(for: presentation.indicatorState),
            range: NSRange(location: 0, length: (presentation.activeTitle as NSString).length)
        )
        title.addAttribute(
            .foregroundColor,
            value: NSColor.systemGreen,
            range: NSRange(
                location: (presentation.activeTitle as NSString).length + 1,
                length: (presentation.recentCompletedTitle as NSString).length
            )
        )
        return title
    }

    private func indicatorColor(for state: StatusItemIndicatorState) -> NSColor {
        switch state {
        case .normal:
            return .systemBlue
        case .waitingAction:
            return .systemOrange
        case .failure:
            return .systemRed
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        handleStatusItemActivation(eventType: NSApp.currentEvent?.type, sender: sender)
    }

    func handleStatusItemActivation(
        eventType: NSEvent.EventType?,
        sender: NSStatusBarButton
    ) {
        if eventType == .rightMouseUp {
            presentMenu(relativeTo: sender)
        } else {
            onTogglePanel?()
        }
    }

    @objc func openMenuFromAccessibility() -> Bool {
        guard let button = statusItem.button else { return false }
        presentMenu(relativeTo: button)
        return true
    }

    private func presentMenu(relativeTo sender: NSStatusBarButton) {
        menuPresenter(menu, sender)
    }

    @objc private func openPanel() {
        onTogglePanel?()
    }

    @objc private func openAttentionTask() {
        onOpenAttentionTask?()
    }

    @objc private func refresh() {
        onRefresh?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
