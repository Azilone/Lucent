import AppKit

/// Reads the native brightness (private DisplayServices) and intercepts the
/// brightness keys through an event tap (needs Accessibility permission).
enum NativeBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private static let get: GetFn? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetFn.self)
    }()

    /// 0…1, nil if unavailable.
    static func value(_ id: CGDirectDisplayID) -> Float? {
        var v: Float = 0
        guard let get, get(id, &v) == 0 else { return nil }
        return v
    }
}

final class BrightnessKeys {
    enum Key { case up, down }

    /// Return true to swallow the key press (the system then does nothing with it).
    var handler: ((Key) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, ctx in
            let me = Unmanaged<BrightnessKeys>.fromOpaque(ctx!).takeUnretainedValue()
            return me.handle(type, event)
        }, userInfo: ctx) else { return false }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
        let code = (ns.data1 & 0xFFFF0000) >> 16
        let isDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
        let key: Key
        switch code {
        case 2: key = .up   // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: key = .down // NX_KEYTYPE_BRIGHTNESS_DOWN
        default: return Unmanaged.passUnretained(event)
        }
        guard isDown else { return Unmanaged.passUnretained(event) }
        return handler?(key) == true ? nil : Unmanaged.passUnretained(event)
    }
}
