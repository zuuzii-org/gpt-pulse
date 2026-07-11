import AppKit
import Foundation
import XCTest
@testable import GPTPulse

final class StatusItemPresentationTests: XCTestCase {
    func testUsesSnapshotActiveAndRecentCompletedCounts() {
        let snapshot = TaskSnapshot(
            tasks: [
                makeTask(id: "running", state: .running),
                makeTask(id: "waiting", state: .waitingForAnswer),
                makeTask(id: "completed-unread", state: .completed, isUnread: true),
                makeTask(id: "completed-viewed", state: .completed, isUnread: false),
                makeTask(id: "failed", state: .failed),
                makeTask(id: "interrupted", state: .interrupted),
            ],
            refreshedAt: .now,
            health: []
        )

        let presentation = StatusItemPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.activeCount, 2)
        XCTAssertEqual(presentation.recentCompletedCount, 4)
        XCTAssertEqual(presentation.waitingActionCount, 1)
        XCTAssertTrue(presentation.hasWaitingAction)
        XCTAssertEqual(presentation.indicatorState, .failure)
        XCTAssertEqual(presentation.title, "2\n4")
        XCTAssertTrue(presentation.hasFailures)
    }

    func testCompactCountsCapAt99PlusWithoutChangingAccessibilityCounts() {
        let tasks = (0..<100).map {
            makeTask(id: "running-\($0)", state: .running)
        } + (0..<100).map {
            makeTask(id: "completed-\($0)", state: .completed)
        }
        let presentation = StatusItemPresentation(
            snapshot: TaskSnapshot(tasks: tasks, refreshedAt: .now, health: [])
        )

        XCTAssertEqual(presentation.title, "99+\n99+")
        XCTAssertTrue(presentation.accessibilityLabel.contains("正在运行 100 个任务"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("最近完成 100 个任务"))
    }

    @MainActor
    func testMenuBarIconIsAn18PointTemplateImage() {
        let image = NSImage.statusMenuIcon

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.width, 18, accuracy: 0.01)
        XCTAssertEqual(image.size.height, 18, accuracy: 0.01)
    }

    @MainActor
    func testStatusItemRendersCompactImageLeadingLayout() throws {
        let snapshot = TaskSnapshot(
            tasks: [
                makeTask(id: "running", state: .running),
                makeTask(id: "completed", state: .completed),
            ],
            refreshedAt: .now,
            health: []
        )
        let monitor = TaskMonitor(
            repository: StatusItemRenderRepository(snapshot: snapshot),
            initialSnapshot: snapshot
        )
        let controller = StatusItemController(monitor: monitor)
        let button = try XCTUnwrap(controller.button)

        XCTAssertEqual(button.frame.width, 42, accuracy: 0.01)
        XCTAssertEqual(button.imagePosition, .imageLeading)
        XCTAssertEqual(button.imageScaling, .scaleProportionallyDown)
        XCTAssertEqual(button.attributedTitle.string, "1\n1")

        let outputBasePath = ProcessInfo.processInfo.environment["GPT_PULSE_STATUS_ITEM_QA_PATH"]
            ?? "/tmp/gpt-pulse-status-item-fixture"
        func render(_ button: NSStatusBarButton, variant: String) throws {
            for (suffix, appearanceName) in [
                ("light", NSAppearance.Name.aqua),
                ("dark", NSAppearance.Name.darkAqua),
            ] {
                button.appearance = NSAppearance(named: appearanceName)
                button.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(
                    button.bitmapImageRepForCachingDisplay(in: button.bounds)
                )
                button.cacheDisplay(in: button.bounds, to: bitmap)
                assertMetricInkHasVerticalPadding(in: bitmap, channel: .blue)
                assertMetricInkHasVerticalPadding(in: bitmap, channel: .green)
                let pngData = try XCTUnwrap(
                    bitmap.representation(using: .png, properties: [:])
                )
                XCTAssertGreaterThan(pngData.count, 500)

                let outputURL = URL(
                    fileURLWithPath: "\(outputBasePath)-\(variant)-\(suffix).png"
                )
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try pngData.write(to: outputURL, options: .atomic)
            }
        }
        try render(button, variant: "normal")

        let maxTasks = (0..<100).map {
            makeTask(id: "render-running-\($0)", state: .running)
        } + (0..<100).map {
            makeTask(id: "render-completed-\($0)", state: .completed)
        }
        let maxSnapshot = TaskSnapshot(tasks: maxTasks, refreshedAt: .now, health: [])
        let maxMonitor = TaskMonitor(
            repository: StatusItemRenderRepository(snapshot: maxSnapshot),
            initialSnapshot: maxSnapshot
        )
        let maxController = StatusItemController(monitor: maxMonitor)
        let maxButton = try XCTUnwrap(maxController.button)

        XCTAssertEqual(maxButton.frame.width, 42, accuracy: 0.01)
        XCTAssertEqual(maxButton.attributedTitle.string, "99+\n99+")
        try render(maxButton, variant: "max")
    }

    @MainActor
    func testAccessibleMenuActionUsesRightClickMenuWithoutChangingLeftClick() throws {
        let snapshot = TaskSnapshot(tasks: [], refreshedAt: .now, health: [])
        let monitor = TaskMonitor(
            repository: StatusItemRenderRepository(snapshot: snapshot),
            initialSnapshot: snapshot
        )
        var presentedMenus: [NSMenu] = []
        let controller = StatusItemController(
            monitor: monitor,
            menuPresenter: { menu, _ in
                presentedMenus.append(menu)
            }
        )
        let button = try XCTUnwrap(controller.button)
        var toggleCount = 0
        controller.onTogglePanel = { toggleCount += 1 }

        XCTAssertEqual(
            button.accessibilityHelp(),
            "左键显示或隐藏任务面板；右键或“打开更多选项”操作显示菜单。"
        )
        let customAction = try XCTUnwrap(button.accessibilityCustomActions()?.first)
        XCTAssertEqual(customAction.name, "打开更多选项")
        XCTAssertTrue(customAction.target === controller)
        XCTAssertEqual(customAction.selector, #selector(StatusItemController.openMenuFromAccessibility))

        controller.handleStatusItemActivation(eventType: .leftMouseUp, sender: button)
        XCTAssertEqual(toggleCount, 1)
        XCTAssertTrue(presentedMenus.isEmpty)

        controller.handleStatusItemActivation(eventType: .rightMouseUp, sender: button)
        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(presentedMenus.count, 1)

        XCTAssertTrue(controller.openMenuFromAccessibility())
        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(presentedMenus.count, 2)
        XCTAssertTrue(presentedMenus[0] === presentedMenus[1])
    }

    private func assertMetricInkHasVerticalPadding(
        in bitmap: NSBitmapImageRep,
        channel: StatusItemMetricChannel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var matchingRows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.05 else {
                    continue
                }
                let red = color.redComponent
                let green = color.greenComponent
                let blue = color.blueComponent
                let isMatch: Bool
                switch channel {
                case .blue:
                    isMatch = blue > 0.25 && blue > green + 0.08 && blue > red + 0.15
                case .green:
                    isMatch = green > 0.25 && green > blue + 0.08 && green > red + 0.08
                }
                if isMatch {
                    matchingRows.append(y)
                }
            }
        }

        guard let minimumRow = matchingRows.min(),
              let maximumRow = matchingRows.max() else {
            XCTFail("Missing \(channel) metric ink", file: file, line: line)
            return
        }
        let minimumPadding = max(1, bitmap.pixelsHigh / 11)
        XCTAssertGreaterThanOrEqual(
            minimumRow,
            minimumPadding,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            maximumRow,
            bitmap.pixelsHigh - 1 - minimumPadding,
            file: file,
            line: line
        )
    }

    func testWaitingActionUsesOrangePriorityAndExpandedChineseLabels() {
        let snapshot = TaskSnapshot(
            tasks: [
                makeTask(id: "running", state: .running),
                makeTask(id: "approval", state: .waitingForApproval),
                makeTask(id: "answer", state: .waitingForAnswer),
                makeTask(id: "completed", state: .completed),
            ],
            refreshedAt: .now,
            health: []
        )

        let presentation = StatusItemPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.waitingActionCount, 2)
        XCTAssertTrue(presentation.hasWaitingAction)
        XCTAssertEqual(presentation.indicatorState, .waitingAction)
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "GPT Pulse，正在运行 3 个任务，最近完成 1 个任务，需要你处理 2 个任务"
        )
        XCTAssertEqual(
            presentation.toolTip,
            "GPT Pulse · 正在运行 3 · 最近完成 1 · 需要你处理 2"
        )
    }

    func testNormalStateHasNoAttentionMessage() {
        let snapshot = TaskSnapshot(
            tasks: [
                makeTask(id: "running", state: .running),
                makeTask(id: "completed", state: .completed),
            ],
            refreshedAt: .now,
            health: []
        )

        let presentation = StatusItemPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.waitingActionCount, 0)
        XCTAssertFalse(presentation.hasWaitingAction)
        XCTAssertEqual(presentation.indicatorState, .normal)
        XCTAssertFalse(presentation.accessibilityLabel.contains("需要你处理"))
        XCTAssertFalse(presentation.toolTip.contains("需要你处理"))
    }

    func testAttentionSelectorPrioritizesApprovalThenNewestAnswer() throws {
        let tasks = [
            makeTask(id: "answer-old", state: .waitingForAnswer, updatedAt: 100),
            makeTask(id: "approval-old", state: .waitingForApproval, updatedAt: 90),
            makeTask(id: "approval-new", state: .waitingForApproval, updatedAt: 110),
            makeTask(id: "running", state: .running, updatedAt: 120),
        ]

        XCTAssertEqual(try XCTUnwrap(AttentionTaskSelector.next(in: tasks)).id, "approval-new:turn-approval-new")
        XCTAssertNil(AttentionTaskSelector.next(in: [makeTask(id: "running", state: .running)]))
    }

    private func makeTask(
        id: String,
        state: PulseTaskState,
        isUnread: Bool = false,
        updatedAt timestamp: TimeInterval = 1_700_000_000
    ) -> PulseTask {
        let now = Date(timeIntervalSince1970: timestamp)
        return PulseTask(
            threadId: id,
            turnId: "turn-\(id)",
            title: id,
            projectDirectory: "/tmp/\(id)",
            state: state,
            startedAt: now,
            updatedAt: now,
            completedAt: state == .completed ? now : nil,
            lastStatus: state.rawValue,
            isUnread: isUnread
        )
    }
}

private enum StatusItemMetricChannel {
    case blue
    case green
}

private actor StatusItemRenderRepository: TaskRepositoryProtocol {
    let snapshotValue: TaskSnapshot

    init(snapshot: TaskSnapshot) {
        snapshotValue = snapshot
    }

    func snapshot(now: Date) async -> TaskSnapshot {
        snapshotValue
    }

    func markViewed(_ task: PulseTask, at date: Date) async throws {}
    func markViewed(_ tasks: [PulseTask], at date: Date) async throws {}
    func unmarkViewed(_ task: PulseTask) async throws {}
    func unmarkViewed(_ tasks: [PulseTask]) async throws {}
}
