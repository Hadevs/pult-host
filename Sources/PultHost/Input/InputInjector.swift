import AppKit
import CoreGraphics

/// Turns client input messages into real macOS events. Main thread only.
/// Needs the Accessibility permission; without it macOS drops the events.
final class InputInjector {
    /// Bounds of the streamed display in global points.
    var displayBounds: CGRect = CGDisplayBounds(CGMainDisplayID())

    private let source = CGEventSource(stateID: .hidSystemState)
    private var position: CGPoint = CGEvent(source: nil)?.location ?? .zero
    private var buttonsDown: Set<CGMouseButton> = []
    private var scrollRemainder = CGPoint.zero
    private var lookRemainder = CGPoint.zero
    private var pressedAt: [CGMouseButton: TimeInterval] = [:]
    /// A real mouse holds the button 50–100 ms. A down and up that land in the
    /// same instant are sometimes not taken as a click (the window behind
    /// doesn't come forward), so the button stays down at least this long.
    /// Input runs on one queue in order, so nothing can overtake the release.
    private static let minimumHold: TimeInterval = 0.035
    /// Last position we put the cursor at, so the cursor monitor can tell
    /// our own moves from someone using the physical mouse.
    private(set) var lastInjected: CGPoint?

    func moveMouse(x: Float, y: Float) {
        let p = CGPoint(x: displayBounds.minX + CGFloat(x), y: displayBounds.minY + CGFloat(y))
        position = CGPoint(x: min(max(p.x, displayBounds.minX), displayBounds.maxX - 1),
                           y: min(max(p.y, displayBounds.minY), displayBounds.maxY - 1))
        lastInjected = position
        let type: CGEventType
        let button: CGMouseButton
        if buttonsDown.contains(.left) { type = .leftMouseDragged; button = .left }
        else if buttonsDown.contains(.right) { type = .rightMouseDragged; button = .right }
        else if buttonsDown.contains(.center) { type = .otherMouseDragged; button = .center }
        else { type = .mouseMoved; button = .left }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { return }
        withHeldModifiers(e)
        e.post(tap: .cghidEventTap)
    }

    /// A modifier held on the phone's keyboard also applies to the mouse
    /// (⌘-click, ⇧-click, ⌥-drag).
    private func withHeldModifiers(_ e: CGEvent) {
        if !heldModifiers.isEmpty { e.flags = flags(heldModifiers) }
    }

    /// Relative motion for game cameras (FPS look). Games read the pointer's
    /// delta, not its absolute position — so we carry the motion as event
    /// deltas and leave the absolute cursor where it is, which also keeps it
    /// from drifting into a screen edge and stalling the turn.
    func moveMouseRelative(dx: Float, dy: Float) {
        lookRemainder.x += CGFloat(dx)
        lookRemainder.y += CGFloat(dy)
        let ix = Int64(lookRemainder.x.rounded(.towardZero))
        let iy = Int64(lookRemainder.y.rounded(.towardZero))
        guard ix != 0 || iy != 0 else { return }
        lookRemainder.x -= CGFloat(ix)
        lookRemainder.y -= CGFloat(iy)

        // Anchor the event at the cursor's live location so it doesn't warp
        // (a stale position would jump the cursor); the motion rides as deltas.
        let current = CGEvent(source: nil)?.location ?? position
        position = current
        let type: CGEventType
        let button: CGMouseButton
        if buttonsDown.contains(.left) { type = .leftMouseDragged; button = .left }
        else if buttonsDown.contains(.right) { type = .rightMouseDragged; button = .right }
        else { type = .mouseMoved; button = .left }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: current, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: ix)
        e.setIntegerValueField(.mouseEventDeltaY, value: iy)
        withHeldModifiers(e)
        e.post(tap: .cghidEventTap)
    }

    func mouseButton(_ raw: UInt8, down: Bool, clickCount: UInt8) {
        let button: CGMouseButton = raw == 1 ? .right : raw == 2 ? .center : .left
        let type: CGEventType
        switch (button, down) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        case (_, true): type = .otherMouseDown
        case (_, false): type = .otherMouseUp
        }
        let now = ProcessInfo.processInfo.systemUptime
        if down {
            pressedAt[button] = now
        } else if let pressed = pressedAt.removeValue(forKey: button), now - pressed < Self.minimumHold {
            Thread.sleep(forTimeInterval: Self.minimumHold - (now - pressed))
        }
        if down { buttonsDown.insert(button) } else { buttonsDown.remove(button) }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        withHeldModifiers(e)
        e.post(tap: .cghidEventTap)
    }

    func scroll(dx: Float, dy: Float) {
        scrollRemainder.x += CGFloat(dx)
        scrollRemainder.y += CGFloat(dy)
        let ix = Int32(scrollRemainder.x.rounded(.towardZero))
        let iy = Int32(scrollRemainder.y.rounded(.towardZero))
        guard ix != 0 || iy != 0 else { return }
        scrollRemainder.x -= CGFloat(ix)
        scrollRemainder.y -= CGFloat(iy)
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    func key(code: UInt16, down: Bool, modifiers: Modifiers) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        // A held modifier key (gamepad Shift) must look like a real one:
        // a flagsChanged event, and its flag on every key pressed meanwhile.
        if let m = Self.modifierKeys[code] {
            if down { heldModifiers.insert(m) } else { heldModifiers.remove(m) }
            e.type = .flagsChanged
        }
        e.flags = flags(modifiers.union(heldModifiers))
        e.post(tap: .cghidEventTap)
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
    }

    private var heldKeys: Set<UInt16> = []
    private var heldModifiers: Modifiers = []
    private static let modifierKeys: [UInt16: Modifiers] = [
        56: .shift, 60: .shift, 59: .control, 62: .control, 58: .option, 61: .option, 55: .command, 54: .command,
    ]

    /// Types arbitrary Unicode (any layout, emoji) without caring about the
    /// Mac's active keyboard layout.
    func type(_ text: String) {
        for ch in text {
            switch ch {
            case "\n", "\r": tap(36)
            case "\t": tap(48)
            default:
                // The event carries the exact character (any language, any Mac
                // layout) and also the physical key it sits on, so games that
                // read key codes see "3" as the 3 key, not as A.
                let units = Array(String(ch).utf16)
                let key = KeyChars.key(for: ch)
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: key?.code ?? 0, keyDown: down) else { continue }
                    e.flags = key?.shift == true ? .maskShift : []
                    e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    e.post(tap: .cghidEventTap)
                }
            }
        }
    }

    /// Dictated text: puts it on the clipboard and pastes it with ⌘V. The
    /// user spoke intending to insert, so we always paste rather than only
    /// when a field looks editable (the check misses web and Electron
    /// fields). Returns whether a text field was detected, for the toast.
    func insertOrCopy(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let editable = focusedElementIsEditable()
        key(code: 9, down: true, modifiers: .command)
        key(code: 9, down: false, modifiers: .command)
        return editable
    }

    /// A photo from the phone: put it on the clipboard and paste it into
    /// whatever has focus. Returns whether it was pasted.
    func insertImage(_ data: Data) -> Bool {
        guard let image = NSImage(data: data) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])   // TIFF rep; every app that takes a pasted image accepts it
        guard focusedElementIsEditable() else { return false }
        key(code: 9, down: true, modifiers: .command)
        key(code: 9, down: false, modifiers: .command)
        return true
    }

    private func focusedElementIsEditable() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return false }
        let el = ref as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        if let role = role as? String,
           [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role) { return true }
        // Web and custom editors often use other roles but expose a settable value or "AXEditable".
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXEditable" as CFString, &editable) == .success, editable as? Bool == true { return true }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(el, kAXSelectedTextRangeAttribute as CFString, &settable)
        return settable.boolValue
    }

    /// Lets go of anything still held when the client vanishes mid-drag.
    func releaseAll() {
        for b in buttonsDown { mouseButton(b == .right ? 1 : b == .center ? 2 : 0, down: false, clickCount: 1) }
        for k in heldKeys { key(code: k, down: false, modifiers: []) }
    }

    private func tap(_ code: UInt16) {
        key(code: code, down: true, modifiers: [])
        key(code: code, down: false, modifiers: [])
    }

    private func flags(_ m: Modifiers) -> CGEventFlags {
        var f: CGEventFlags = []
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.command) { f.insert(.maskCommand) }
        return f
    }
}
