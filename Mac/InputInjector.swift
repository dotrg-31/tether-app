import ApplicationServices
import CoreGraphics
import Foundation

/// Turns iPad touches into mouse events on the virtual display. Needs Accessibility permission.
final class InputInjector {
    var bounds: () -> CGRect
    private var lastDownTime = Date.distantPast
    private var lastDownPoint = CGPoint.zero
    private var clickCount: Int64 = 1
    private let source = CGEventSource(stateID: .hidSystemState)

    init(bounds: @escaping () -> CGRect) { self.bounds = bounds }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func point(_ x: Float, _ y: Float) -> CGPoint {
        let b = bounds()
        let cx = min(max(CGFloat(x), 0), 1), cy = min(max(CGFloat(y), 0), 1)
        return CGPoint(x: b.minX + cx * (b.width - 1), y: b.minY + cy * (b.height - 1))
    }

    private func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clicks)
        e.post(tap: .cghidEventTap)
    }

    private func registerDown(at p: CGPoint) -> Int64 {
        let now = Date()
        let close = hypot(p.x - lastDownPoint.x, p.y - lastDownPoint.y) < 12
        clickCount = (now.timeIntervalSince(lastDownTime) < NSEvent.doubleClickIntervalSafe && close) ? clickCount + 1 : 1
        lastDownTime = now
        lastDownPoint = p
        return clickCount
    }

    func handle(_ t: TouchPacket) {
        let p = point(t.x, t.y)
        switch t.phase {
        case .move:
            post(.mouseMoved, p)
        case .down:
            post(.mouseMoved, p)
            post(.leftMouseDown, p, clicks: registerDown(at: p))
        case .drag:
            post(.leftMouseDragged, p, clicks: clickCount)
        case .up:
            post(.leftMouseUp, p, clicks: clickCount)
        case .click:
            post(.mouseMoved, p)
            let c = registerDown(at: p)
            post(.leftMouseDown, p, clicks: c)
            post(.leftMouseUp, p, clicks: c)
        case .rightClick:
            post(.mouseMoved, p)
            post(.rightMouseDown, p, button: .right)
            post(.rightMouseUp, p, button: .right)
        }
    }

    func handle(_ s: ScrollPacket) {
        let p = point(s.x, s.y)
        post(.mouseMoved, p)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(s.dy.rounded()), wheel2: Int32(s.dx.rounded()), wheel3: 0)
        else { return }
        e.post(tap: .cghidEventTap)
    }
}

import AppKit
private extension NSEvent {
    static var doubleClickIntervalSafe: TimeInterval { min(max(doubleClickInterval, 0.2), 1.0) }
}
