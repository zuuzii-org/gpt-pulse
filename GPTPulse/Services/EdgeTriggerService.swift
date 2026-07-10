import AppKit
import CoreGraphics
import Foundation

struct EdgeScreenGeometry: Equatable, Sendable {
    let id: UInt32
    let frame: CGRect
}

struct EdgeTriggerSample {
    let location: CGPoint
    let screens: [EdgeScreenGeometry]
    let uptime: TimeInterval
    let mouseButtonPressed: Bool
    let panelVisible: Bool
    let isFullScreen: (EdgeScreenGeometry) -> Bool
}

struct EdgeTriggerEvaluator: Sendable {
    let dwellDuration: TimeInterval
    let triggerBandWidth: CGFloat
    let activeVerticalFraction: CGFloat

    private(set) var candidateScreenID: UInt32?
    private(set) var candidateSince: TimeInterval?
    private(set) var hasTriggered = false

    init(
        dwellDuration: TimeInterval = 0.2,
        triggerBandWidth: CGFloat = 3,
        activeVerticalFraction: CGFloat = 0.6
    ) {
        self.dwellDuration = dwellDuration
        self.triggerBandWidth = triggerBandWidth
        self.activeVerticalFraction = activeVerticalFraction
    }

    mutating func evaluate(_ sample: EdgeTriggerSample) -> EdgeScreenGeometry? {
        if sample.panelVisible {
            if !hasTriggered {
                reset()
            }
            return nil
        }

        guard !sample.mouseButtonPressed,
              let screen = screenContaining(sample.location, in: sample.screens),
              isWithinActiveRightEdge(sample.location, of: screen),
              isRightEdgeExposed(screen, at: sample.location.y, among: sample.screens),
              !sample.isFullScreen(screen) else {
            reset()
            return nil
        }

        if candidateScreenID != screen.id {
            candidateScreenID = screen.id
            candidateSince = sample.uptime
            hasTriggered = false
            return nil
        }

        guard !hasTriggered,
              let candidateSince,
              sample.uptime - candidateSince >= dwellDuration - 0.000_001 else {
            return nil
        }

        hasTriggered = true
        return screen
    }

    mutating func reset() {
        candidateScreenID = nil
        candidateSince = nil
        hasTriggered = false
    }

    private func screenContaining(
        _ point: CGPoint,
        in screens: [EdgeScreenGeometry]
    ) -> EdgeScreenGeometry? {
        screens.first { screen in
            point.x >= screen.frame.minX && point.x < screen.frame.maxX
                && point.y >= screen.frame.minY && point.y < screen.frame.maxY
        }
    }

    private func isWithinActiveRightEdge(
        _ point: CGPoint,
        of screen: EdgeScreenGeometry
    ) -> Bool {
        let excludedFraction = (1 - activeVerticalFraction) / 2
        let activeMinY = screen.frame.minY + screen.frame.height * excludedFraction
        let activeMaxY = screen.frame.maxY - screen.frame.height * excludedFraction

        return point.x >= screen.frame.maxX - triggerBandWidth
            && point.y >= activeMinY
            && point.y <= activeMaxY
    }

    private func isRightEdgeExposed(
        _ screen: EdgeScreenGeometry,
        at y: CGFloat,
        among screens: [EdgeScreenGeometry]
    ) -> Bool {
        let pointImmediatelyRight = CGPoint(x: screen.frame.maxX + 1, y: y)
        return !screens.contains { other in
            other.id != screen.id && other.frame.contains(pointImmediatelyRight)
        }
    }
}

protocol FullScreenDetecting: Sendable {
    func isFullScreen(on screen: EdgeScreenGeometry) -> Bool
}

struct WorkspaceFullScreenDetector: FullScreenDetecting {
    func isFullScreen(on screen: EdgeScreenGeometry) -> Bool {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windowInfo = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[CFString: Any]] else {
            return false
        }

        let quartzScreenFrame = CGDisplayBounds(CGDirectDisplayID(screen.id))

        return windowInfo.contains { window in
            guard (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value == frontmostPID,
                  (window[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  let boundsValue = window[kCGWindowBounds],
                  let boundsDictionary = boundsValue as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                return false
            }

            return approximatelyEqual(bounds, quartzScreenFrame, tolerance: 2)
        }
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

@MainActor
final class EdgeTriggerService {
    var onTrigger: ((NSScreen) -> Void)?
    var onPointerMove: ((CGPoint) -> Void)?
    var isPanelVisible: () -> Bool = { false }

    private let settings: PulseSettings
    private let fullScreenDetector: any FullScreenDetecting
    private var evaluator: EdgeTriggerEvaluator
    private var timer: Timer?

    init(
        settings: PulseSettings,
        fullScreenDetector: any FullScreenDetecting = WorkspaceFullScreenDetector()
    ) {
        self.settings = settings
        self.fullScreenDetector = fullScreenDetector
        evaluator = EdgeTriggerEvaluator(dwellDuration: settings.edgeDwellDuration)
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.samplePointer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        evaluator.reset()
    }

    private func samplePointer() {
        let location = NSEvent.mouseLocation
        onPointerMove?(location)

        guard settings.edgeTriggerEnabled else {
            evaluator.reset()
            return
        }

        let geometries = NSScreen.screens.map(EdgeScreenGeometry.init)
        let sample = EdgeTriggerSample(
            location: location,
            screens: geometries,
            uptime: ProcessInfo.processInfo.systemUptime,
            mouseButtonPressed: NSEvent.pressedMouseButtons != 0,
            panelVisible: isPanelVisible(),
            isFullScreen: { [settings, fullScreenDetector] screen in
                settings.disableInFullScreen && fullScreenDetector.isFullScreen(on: screen)
            }
        )

        guard let triggeredScreen = evaluator.evaluate(sample),
              let screen = NSScreen.screens.first(where: {
                  EdgeScreenGeometry($0).id == triggeredScreen.id
              }) else {
            return
        }

        onTrigger?(screen)
    }
}

private extension EdgeScreenGeometry {
    init(_ screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        id = number?.uint32Value ?? UInt32(bitPattern: Int32(screen.hash))
        frame = screen.frame
    }
}

extension NSScreen {
    static func containing(_ point: CGPoint) -> NSScreen? {
        screens.first { screen in
            point.x >= screen.frame.minX && point.x < screen.frame.maxX
                && point.y >= screen.frame.minY && point.y < screen.frame.maxY
        }
    }
}
