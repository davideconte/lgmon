import AppKit

/// Media keys (brightness, volume, mute) and ⌃⌥ shortcuts through one event tap.
/// Needs Accessibility permission, because events we handle are swallowed.
final class KeyTap {
    enum Action {
        case brightness(Int, fine: Bool)
        case volume(Int, fine: Bool)
        case mute
        case back
    }

    /// Decides what to do with a key; nil lets the event through untouched.
    var decide: ((Press) -> Action?)?
    var perform: ((Action) -> Void)?

    enum Key {
        case brightnessUp, brightnessDown, soundUp, soundDown, mute
        case arrowUp, arrowDown, returnKey
    }

    struct Press {
        let key: Key
        let down: Bool
        let isRepeat: Bool
        let flags: CGEventFlags
    }

    private var tap: CFMachPort?

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << 14) | (1 << CGEventType.keyDown.rawValue)   // 14 = NSEvent.EventType.systemDefined
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: keyTapCallback, userInfo: me) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true to swallow the event.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        let flags = event.flags
        var press: Press?

        if type.rawValue == 14 {
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
            let code = (ns.data1 & 0xFFFF0000) >> 16
            let state = (ns.data1 & 0xFF00) >> 8
            let rep = (ns.data1 & 0x1) == 1
            let key: Key?
            switch code {
            case 0: key = .soundUp          // NX_KEYTYPE_SOUND_UP
            case 1: key = .soundDown
            case 2: key = .brightnessUp
            case 3: key = .brightnessDown
            case 7: key = .mute
            default: key = nil
            }
            if let key { press = Press(key: key, down: state == 0xA, isRepeat: rep, flags: flags) }
        } else if type == .keyDown {
            let ctrlAlt = flags.contains(.maskControl) && flags.contains(.maskAlternate) && !flags.contains(.maskCommand)
            guard ctrlAlt else { return false }
            let rep = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 126: press = Press(key: .arrowUp, down: true, isRepeat: rep, flags: flags)
            case 125: press = Press(key: .arrowDown, down: true, isRepeat: rep, flags: flags)
            case 36: press = Press(key: .returnKey, down: true, isRepeat: rep, flags: flags)
            default: break
            }
        }

        guard let press else { return false }
        let action = decide?(press)
        if UserDefaults.standard.bool(forKey: "debugKeys") {
            log("press \(press.key) down=\(press.down) -> \(action.map { "\($0)" } ?? "pass through")")
        }
        guard let action else { return false }
        if press.down {
            if case .mute = action, press.isRepeat { return true }
            if case .back = action, press.isRepeat { return true }
            DispatchQueue.main.async { self.perform?(action) }
        }
        return true
    }
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable()
        return Unmanaged.passUnretained(event)
    }
    return tap.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
