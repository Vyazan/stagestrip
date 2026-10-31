import AppKit
import ApplicationServices

final class MinimizeInterceptor {
    var onPark: ((AXUIElement) -> Void)?
    private let systemWide = AXUIElementCreateSystemWide()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var eatMouseUp = false

    init() {
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
    }

    func start() {
        guard AXIsProcessTrusted(), tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<MinimizeInterceptor>.fromOpaque(context).takeUnretainedValue()
            return interceptor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private func axAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func eligible(_ window: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid != getpid() else { return false }
        return attribute(window, kAXMinimizeButtonAttribute) != nil
            && attribute(window, "AXFullScreen") as? Bool != true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseUp, eatMouseUp {
            eatMouseUp = false
            return nil
        }
        if type == .leftMouseDown {
            var element: AXUIElement?
            let point = event.location
            guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
                  let element, attribute(element, kAXSubroleAttribute) as? String == "AXMinimizeButton",
                  let window = axAttribute(element, kAXWindowAttribute),
                  eligible(window) else { return Unmanaged.passUnretained(event) }
            eatMouseUp = true
            DispatchQueue.main.async { [weak self] in self?.onPark?(window) }
            return nil
        }
        if type == .keyDown {
            guard event.getIntegerValueField(.keyboardEventKeycode) == 46,
                  event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == .maskCommand,
                  // The system-wide kAXFocusedApplicationAttribute fails with -25204 on macOS 27.2.
                  let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let window = axAttribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
                  eligible(window) else { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { [weak self] in self?.onPark?(window) }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
