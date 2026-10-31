import AppKit
import ApplicationServices
import Observation

/// "Work inside the preview": the real cursor is moved onto the previewed
/// display and kept there, and physical movement is scaled to match the
/// preview's size. Clicks, scrolling and typing reach apps on that display as
/// ordinary events. Command-Escape releases the cursor.
///
/// Needs Accessibility, because an active event tap can rewrite mouse events.
@MainActor
@Observable
final class CursorCapture {
    static let shared = CursorCapture()

    private(set) var capturedDisplay: CGDirectDisplayID?

    @ObservationIgnored fileprivate var position = CGPoint.zero
    @ObservationIgnored fileprivate var scale: CGFloat = 1
    @ObservationIgnored private var bounds = CGRect.zero
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var onRelease: ((CGPoint) -> Void)?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks for Accessibility once; macOS shows its own prompt with a link to System Settings.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Returns false (and asks for Accessibility) when the tap cannot be installed.
    func begin(displayID: CGDirectDisplayID, at location: CGPoint, scale: CGFloat,
               onRelease: @escaping (CGPoint) -> Void) -> Bool {
        guard Self.isTrusted else {
            Self.requestTrust()
            DisplayStore.shared.lastError = "Allow DoppioDisplay in System Settings › Privacy & Security › Accessibility to work inside the preview. Until then a double-click only moves the cursor."
            return false
        }
        end()

        let mask: CGEventMask = [
            CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .keyDown,
        ].reduce(0) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: cursorCaptureCallback, userInfo: nil
        ) else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        bounds = CGDisplayBounds(displayID)
        self.scale = max(scale, 1)
        self.onRelease = onRelease
        capturedDisplay = displayID

        // Detach the cursor from the mouse; we move it ourselves from the raw deltas.
        CGAssociateMouseAndMouseCursorPosition(0)
        // Warping suppresses local events briefly by default; we warp on every move.
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        move(to: location)
        return true
    }

    func end(for displayID: CGDirectDisplayID) {
        if capturedDisplay == displayID { end() }
    }

    func end() {
        guard capturedDisplay != nil else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        capturedDisplay = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        let release = onRelease
        onRelease = nil
        release?(position)
    }

    fileprivate func move(by dx: CGFloat, _ dy: CGFloat) {
        move(to: CGPoint(x: position.x + dx * scale, y: position.y + dy * scale))
    }

    private func move(to point: CGPoint) {
        position = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
        CGWarpMouseCursorPosition(position)
    }

    fileprivate func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

/// Runs on the main run loop (the tap's source is added there).
private func cursorCaptureCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    MainActor.assumeIsolated {
        let capture = CursorCapture.shared
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            capture.reenableTap()
            return Unmanaged.passUnretained(event)
        case .keyDown:
            // Command-Escape: release, and swallow the key.
            if event.getIntegerValueField(.keyboardEventKeycode) == 53, event.flags.contains(.maskCommand) {
                capture.end()
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            capture.move(
                by: CGFloat(event.getDoubleValueField(.mouseEventDeltaX)),
                CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
            )
            event.location = capture.position
            return Unmanaged.passUnretained(event)
        }
    }
}
