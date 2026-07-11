import AppKit
import Combine
import CoreText

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
    let language: AppLanguage

    init(snapshot: TaskSnapshot, language: AppLanguage = .simplifiedChinese) {
        activeCount = snapshot.activeCount
        recentCompletedCount = snapshot.recentCompletedCount
        waitingActionCount = snapshot.tasks.lazy.filter {
            $0.state == .waitingForApproval || $0.state == .waitingForAnswer
        }.count
        hasWaitingAction = waitingActionCount > 0
        hasFailures = snapshot.hasFailures
        self.language = language
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
            PulseL10n.text("正在运行 %d 个任务", language: language, activeCount),
            PulseL10n.text("最近完成 %d 个任务", language: language, recentCompletedCount),
        ]
        if hasWaitingAction {
            components.append(PulseL10n.text(
                "需要你处理 %d 个任务",
                language: language,
                waitingActionCount
            ))
        }
        if hasFailures {
            components.append(PulseL10n.text("存在失败", language: language))
        }
        if language.usesChinesePunctuation {
            return "GPT Pulse，" + components.joined(separator: "，")
        }
        return "GPT Pulse · " + components.joined(separator: " · ")
    }

    var toolTip: String {
        var components = [
            PulseL10n.text("正在运行 %d", language: language, activeCount),
            PulseL10n.text("最近完成 %d", language: language, recentCompletedCount),
        ]
        if hasWaitingAction {
            components.append(PulseL10n.text(
                "需要你处理 %d",
                language: language,
                waitingActionCount
            ))
        }
        if hasFailures {
            components.append(PulseL10n.text("存在失败", language: language))
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

    var onTogglePanel: (() -> Void)?
    var onOpenAttentionTask: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onQuit: (() -> Void)?

    var button: NSStatusBarButton? { statusItem.button }

    private let statusItem: NSStatusItem
    private let settings: PulseSettings?
    private let menuPresenter: (NSMenu, NSStatusBarButton) -> Void
    private let menu = NSMenu()
    private let statusContentView = StatusItemContentView()
    private var attentionMenuItem: NSMenuItem?
    private var snapshotCancellable: AnyCancellable?
    private var languageCancellable: AnyCancellable?
    private var latestSnapshot: TaskSnapshot

    init(
        monitor: TaskMonitor,
        settings: PulseSettings? = nil,
        menuPresenter: @escaping (NSMenu, NSStatusBarButton) -> Void = { menu, button in
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.minY - 4),
                in: button
            )
        }
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: Self.statusItemWidth)
        self.settings = settings
        latestSnapshot = monitor.snapshot
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

        languageCancellable = settings?.$appLanguage
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyButtonLocalization()
                self?.configureMenu()
                if let snapshot = self?.latestSnapshot {
                    self?.update(snapshot: snapshot)
                }
            }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // NSStatusBarButton lays out its title as a single line. A multiline
        // attributedTitle is therefore clipped differently across menu-bar
        // heights and backing scales. Keep the button title-free and place a
        // non-interactive, fixed-geometry view above the native button cell.
        button.title = ""
        button.attributedTitle = NSAttributedString()
        button.image = nil
        button.imagePosition = .noImage
        statusContentView.frame = button.bounds
        statusContentView.autoresizingMask = [.width, .height]
        button.addSubview(statusContentView)
        button.setAccessibilityRole(.button)
        applyButtonLocalization()
    }

    private func applyButtonLocalization() {
        guard let button = statusItem.button else { return }
        let language = settings?.appLanguage ?? .system
        button.setAccessibilityHelp(PulseL10n.text(
            "左键显示或隐藏任务面板；右键或“打开更多选项”操作显示菜单。",
            language: language
        ))
        button.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(
                name: PulseL10n.text("打开更多选项", language: language),
                target: self,
                selector: #selector(openMenuFromAccessibility)
            ),
        ])
    }

    private func configureMenu() {
        menu.removeAllItems()
        let language = settings?.appLanguage ?? .system
        let attentionItem = NSMenuItem(
            title: PulseL10n.text("打开下一条需处理任务", language: language),
            action: #selector(openAttentionTask),
            keyEquivalent: ""
        )
        attentionItem.target = self
        attentionItem.isHidden = true
        menu.addItem(attentionItem)
        attentionMenuItem = attentionItem

        let openItem = NSMenuItem(
            title: PulseL10n.text("打开任务面板", language: language),
            action: #selector(openPanel),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(
            title: PulseL10n.text("立即刷新", language: language),
            action: #selector(refresh),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let checkForUpdatesItem = NSMenuItem(
            title: PulseL10n.text("检查更新…", language: language),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        let settingsItem = NSMenuItem(
            title: PulseL10n.text("设置…", language: language),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: PulseL10n.text("退出 GPT Pulse", language: language),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func update(snapshot: TaskSnapshot) {
        guard let button = statusItem.button else { return }
        latestSnapshot = snapshot

        let presentation = StatusItemPresentation(
            snapshot: snapshot,
            language: settings?.appLanguage ?? .system
        )
        statusContentView.update(
            presentation: presentation,
            activeColor: indicatorColor(for: presentation.indicatorState)
        )
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        button.toolTip = presentation.toolTip
        attentionMenuItem?.isHidden = !presentation.hasWaitingAction
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

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func quit() {
        onQuit?()
    }
}

/// Fixed status-item geometry, independent from NSButtonCell's single-line
/// title layout. Returning nil from hitTest keeps all mouse handling on the
/// underlying NSStatusBarButton (including right-click and accessibility).
@MainActor
final class StatusItemContentView: NSView {
    private enum Layout {
        static let horizontalInset: CGFloat = 2
        static let iconSize = NSSize(width: 18, height: 18)
        static let iconToMetricsSpacing: CGFloat = 2
        static let metricsWidth: CGFloat = 18
    }

    private let iconView: NSImageView
    private let metricsView = StatusItemMetricsView()

    private(set) var activeTitle = "0"
    private(set) var recentCompletedTitle = "0"

    override init(frame frameRect: NSRect) {
        let icon = NSImage.statusMenuIcon
        icon.isTemplate = true
        icon.size = Layout.iconSize

        iconView = NSImageView(image: icon)
        iconView.imageAlignment = .alignCenter
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .labelColor

        super.init(frame: frameRect)
        addSubview(iconView)
        addSubview(metricsView)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()

        let iconOriginY = floor((bounds.height - Layout.iconSize.height) / 2)
        iconView.frame = NSRect(
            x: Layout.horizontalInset,
            y: iconOriginY,
            width: Layout.iconSize.width,
            height: Layout.iconSize.height
        )
        metricsView.frame = NSRect(
            x: iconView.frame.maxX + Layout.iconToMetricsSpacing,
            y: 0,
            width: Layout.metricsWidth,
            height: bounds.height
        )
    }

    func update(presentation: StatusItemPresentation, activeColor: NSColor) {
        activeTitle = presentation.activeTitle
        recentCompletedTitle = presentation.recentCompletedTitle
        metricsView.update(
            activeTitle: activeTitle,
            recentCompletedTitle: recentCompletedTitle,
            activeColor: activeColor
        )
    }

    var iconFrameForTesting: NSRect { iconView.frame }
    var metricsFrameForTesting: NSRect { metricsView.frame }
}

@MainActor
private final class StatusItemMetricsView: NSView {
    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: 8.5,
        weight: .semibold
    )

    private var activeTitle = "0"
    private var recentCompletedTitle = "0"
    private var activeColor = NSColor.systemBlue

    override var isOpaque: Bool { false }

    func update(
        activeTitle: String,
        recentCompletedTitle: String,
        activeColor: NSColor
    ) {
        self.activeTitle = activeTitle
        self.recentCompletedTitle = recentCompletedTitle
        self.activeColor = activeColor
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let font = Self.font
        let lineAdvance = font.ascender - font.descender + font.leading
        let stackHeight = lineAdvance * 2
        let bottomBaseline = ((bounds.height - stackHeight) / 2) - font.descender

        draw(
            recentCompletedTitle,
            color: .systemGreen,
            baseline: bottomBaseline
        )
        draw(
            activeTitle,
            color: activeColor,
            baseline: bottomBaseline + lineAdvance
        )
    }

    private func draw(_ title: String, color: NSColor, baseline: CGFloat) {
        let attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: Self.font,
                .foregroundColor: color,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributedTitle)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let originX = round(((bounds.width - width) / 2) * scale) / scale

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: originX, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
