import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class TaskPanelController: NSObject, NSWindowDelegate {
    private let panel: PulsePanel
    private let width: CGFloat
    private let dismissDelay: TimeInterval

    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var dismissTimer: Timer?
    private weak var outsideDismissExcludedView: NSView?
    private(set) var isVisible = false
    private var presentationGeneration: UInt64 = 0
    var preventsAutomaticDismiss = false

    init<Content: View>(
        width: CGFloat,
        dismissDelay: TimeInterval,
        rootView: Content
    ) {
        self.width = width
        self.dismissDelay = dismissDelay
        panel = PulsePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
        panel.contentView = NSHostingView(rootView: rootView)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.title = "GPT Pulse"
        panel.setAccessibilityLabel("GPT Pulse 任务侧边栏")
    }

    func setOutsideDismissExcludedView(_ view: NSView?) {
        outsideDismissExcludedView = view
    }

    func toggle(on screen: NSScreen) {
        if isVisible {
            hide()
        } else {
            show(on: screen)
        }
    }

    func show(on screen: NSScreen) {
        presentationGeneration &+= 1
        cancelDismissTimer()
        installEventMonitors()

        let targetFrame = panelFrame(on: screen)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        isVisible = true
        panel.alphaValue = reduceMotion ? 1 : 0

        if reduceMotion {
            panel.setFrame(targetFrame, display: true)
            panel.orderFrontRegardless()
            panel.makeKey()
        } else {
            var startingFrame = targetFrame
            startingFrame.origin.x += 18
            panel.setFrame(startingFrame, display: true)
            panel.orderFrontRegardless()
            panel.makeKey()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(targetFrame, display: true)
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard isVisible else { return }
        presentationGeneration &+= 1
        let hideGeneration = presentationGeneration
        isVisible = false
        cancelDismissTimer()
        removeEventMonitors()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        var destinationFrame = panel.frame
        destinationFrame.origin.x += 18
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(destinationFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.presentationGeneration == hideGeneration,
                      !self.isVisible else {
                    return
                }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }

    func handlePointerMove(to location: CGPoint) {
        guard isVisible, !preventsAutomaticDismiss else { return }

        if panel.frame.contains(location) {
            cancelDismissTimer()
        } else if dismissTimer == nil {
            let timer = Timer(timeInterval: dismissDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hide()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            dismissTimer = timer
        }
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
        cancelDismissTimer()
        removeEventMonitors()
    }

    private func panelFrame(on screen: NSScreen) -> CGRect {
        Self.panelFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            width: width
        )
    }

    static func panelFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        width: CGFloat
    ) -> CGRect {
        let rightEdge = min(screenFrame.maxX, visibleFrame.maxX)
        return CGRect(
            x: rightEdge - width,
            y: visibleFrame.minY,
            width: width,
            height: visibleFrame.height
        )
    }

    private func installEventMonitors() {
        guard localEventMonitor == nil, globalEventMonitor == nil else { return }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown, event.keyCode == 53 {
                self.hide()
                return nil
            }

            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let clickedExcludedView = event.window === self.outsideDismissExcludedView?.window
                if !self.preventsAutomaticDismiss,
                   event.window !== self.panel,
                   !clickedExcludedView {
                    self.hide()
                }
            }

            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible,
                      !self.preventsAutomaticDismiss,
                      !self.panel.frame.contains(NSEvent.mouseLocation) else {
                    return
                }
                self.hide()
            }
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func cancelDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }
}

private final class PulsePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
