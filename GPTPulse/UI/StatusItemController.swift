import AppKit
import Combine

struct StatusItemPresentation: Equatable {
    let activeCount: Int
    let recentCompletedCount: Int
    let hasFailures: Bool

    init(snapshot: TaskSnapshot) {
        activeCount = snapshot.activeCount
        recentCompletedCount = snapshot.recentCompletedCount
        hasFailures = snapshot.hasFailures
    }

    var title: String {
        "● \(activeCount)\n✓ \(recentCompletedCount)"
    }

    var accessibilityLabel: String {
        var components = [
            "正在运行 \(activeCount) 个任务",
            "最近完成 \(recentCompletedCount) 个任务",
        ]
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
        if hasFailures {
            components.append("存在失败")
        }
        return "GPT Pulse · " + components.joined(separator: " · ")
    }
}

@MainActor
final class StatusItemController: NSObject {
    var onTogglePanel: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    var button: NSStatusBarButton? { statusItem.button }

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var snapshotCancellable: AnyCancellable?

    init(monitor: TaskMonitor) {
        statusItem = NSStatusBar.system.statusItem(withLength: 38)
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
        if let cell = button.cell as? NSButtonCell {
            cell.alignment = .center
            cell.usesSingleLineMode = false
            cell.wraps = true
            cell.lineBreakMode = .byClipping
        }
        button.setAccessibilityRole(.button)
    }

    private func configureMenu() {
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
    }

    private func attributedTitle(for presentation: StatusItemPresentation) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping
        paragraphStyle.minimumLineHeight = 9.5
        paragraphStyle.maximumLineHeight = 9.5
        paragraphStyle.lineSpacing = -0.5

        let title = NSMutableAttributedString(
            string: presentation.title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
                .baselineOffset: -0.5,
            ]
        )
        let fullTitle = title.string as NSString
        title.addAttribute(
            .foregroundColor,
            value: presentation.hasFailures ? NSColor.systemRed : NSColor.systemBlue,
            range: fullTitle.range(of: "●")
        )
        title.addAttribute(
            .foregroundColor,
            value: NSColor.systemGreen,
            range: fullTitle.range(of: "✓")
        )
        return title
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.minY - 4),
                in: sender
            )
        } else {
            onTogglePanel?()
        }
    }

    @objc private func openPanel() {
        onTogglePanel?()
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
