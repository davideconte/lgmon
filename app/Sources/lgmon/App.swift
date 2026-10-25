import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = Monitor.shared
    private let keys = KeyTap()
    private var statusItem: NSStatusItem!
    private var brightnessSlider: SliderItemView?
    private var volumeSlider: SliderItemView?
    private var permissionTimer: Timer?
    private var volumeStreak = 0
    private var lastVolumeKey = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.firstLaunchDefaults()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "lgmon")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor.onChange = { [weak self] in self?.syncSliders() }
        monitor.onPairingPrompt = { HUD.shared.showMessage(L.pairing, detail: "LG webOS", seconds: 30) }
        monitor.start()

        keys.decide = { [weak self] press in self?.decide(press) }
        keys.perform = { [weak self] action in self?.perform(action) }
        startKeys(prompt: true)

        // pick up changes made with the monitor's own joystick or remote
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.monitor.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.monitor.reset(); await self?.monitor.refresh() }
        }
    }

    // MARK: URL scheme, for Shortcuts, Raycast, scripts

    /// lgmon://brightness/40 · /brightness/+5 · /volume/-2 · /mute · /input/HDMI_2
    /// /app/youtube · /back · /screen/off · /standby · /wake · /menu
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
            guard let cmd = parts.first else { continue }
            let arg = parts.count > 1 ? parts[1] : nil
            func level(_ current: Int?, _ s: String) -> Int? {
                guard let n = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "+"))) else { return nil }
                return s.hasPrefix("+") || s.hasPrefix("-") ? (current ?? 0) + n : n
            }
            switch cmd {
            case "brightness":
                if let arg, let v = level(monitor.brightness, arg) {
                    monitor.setBrightness(v)
                    if let b = monitor.brightness { HUD.shared.showBrightness(b, on: SystemInfo.screenUnderMouse()) }
                }
            case "volume":
                if let arg, let v = level(monitor.volume, arg) { monitor.setVolume(v) }
            case "mute": monitor.toggleMute()
            case "input":
                if let arg, let i = monitor.inputs.first(where: { $0.id.lowercased() == arg.lowercased() || $0.label.lowercased() == arg.lowercased() }) {
                    monitor.switchInput(i)
                }
            case "app":
                if let arg, let a = monitor.apps.first(where: { $0.id == arg || $0.title.lowercased().contains(arg.lowercased()) }) {
                    monitor.launch(a)
                }
            case "back": monitor.back()
            case "screen": if arg == "off" { monitor.turnScreenOff() }
            case "standby": monitor.standby()
            case "wake": monitor.wake()
            case "menu": statusItem.button?.performClick(nil)
            default: break
            }
        }
    }

    // MARK: keys

    private func startKeys(prompt: Bool) {
        if SystemInfo.accessibilityTrusted(prompt: prompt), keys.start() { return }
        // wait for the user to grant Accessibility, then start without a restart
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, SystemInfo.accessibilityTrusted(prompt: false), self.keys.start() else { return }
                t.invalidate()
            }
        }
    }

    nonisolated private func decide(_ p: KeyTap.Press) -> KeyTap.Action? {
        let alt = p.flags.contains(.maskAlternate), shift = p.flags.contains(.maskShift)
        let fine = alt && shift
        switch p.key {
        case .brightnessUp, .brightnessDown:
            guard SystemInfo.pointerOnMonitor else { return nil }
            return .brightness(p.key == .brightnessUp ? 1 : -1, fine: fine)
        case .soundUp, .soundDown:
            let dir = p.key == .soundUp ? 1 : -1
            if Settings.optionVolumeForBrightness, alt, !shift { return .brightness(dir, fine: false) }
            guard Settings.volumeKeys, SystemInfo.audioGoesToMonitor else { return nil }
            return .volume(dir, fine: fine)
        case .mute:
            guard Settings.volumeKeys, SystemInfo.audioGoesToMonitor else { return nil }
            return .mute
        case .arrowUp, .arrowDown:
            return .brightness(p.key == .arrowUp ? 1 : -1, fine: shift)
        case .returnKey:
            return .back
        }
    }

    /// 1 per tap; faster taps or a held key speed up to 2, then 3.
    private func volumeStep() -> Int {
        let now = Date()
        volumeStreak = now.timeIntervalSince(lastVolumeKey) < 0.35 ? volumeStreak + 1 : 0
        lastVolumeKey = now
        switch volumeStreak {
        case ..<4: return 1
        case ..<10: return 2
        default: return 3
        }
    }

    private func perform(_ action: KeyTap.Action) {
        switch action {
        case .brightness(let dir, let fine):
            if let v = monitor.adjustBrightness(by: dir * (fine ? 1 : 5)) {
                HUD.shared.showBrightness(v, on: SystemInfo.screenUnderMouse())
            }
        case .volume(let dir, let fine):
            // no indicator: the monitor shows its own
            monitor.adjustVolume(by: dir * (fine ? 1 : volumeStep()))
        case .mute:
            monitor.toggleMute()
        case .back:
            monitor.back()
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        Task { await monitor.refresh(); await monitor.loadLists() }
        build(menu)
    }

    private func build(_ menu: NSMenu) {
        menu.removeAllItems()

        switch monitor.status {
        case .searching:
            menu.addItem(disabled(L.searching))
        case .pairing:
            menu.addItem(disabled(L.pairing))
        case .unreachable(let why):
            menu.addItem(disabled(L.unreachable))
            menu.addItem(disabled(why))
        case .choose(let devices):
            menu.addItem(disabled(L.chooseMonitor))
            for d in devices {
                menu.addItem(item("\(d.name ?? "webOS")  ·  \(d.ip)") { [weak self] in self?.monitor.use(d) })
            }
        case .ready:
            break
        }

        let b = SliderItemView(title: L.brightness, symbol: "sun.max.fill", value: monitor.brightness) { [weak self] v in
            self?.monitor.setBrightness(v)
        }
        brightnessSlider = b
        menu.addItem(viewItem(b))
        let v = SliderItemView(title: L.volume, symbol: "speaker.wave.2.fill", value: monitor.volume) { [weak self] v in
            self?.monitor.setVolume(v)
        }
        volumeSlider = v
        menu.addItem(viewItem(v))
        menu.addItem(.separator())

        let inputMenu = NSMenu()
        for i in monitor.inputs {
            var name = i.id.replacingOccurrences(of: "_1", with: "").replacingOccurrences(of: "_", with: " ")
            if !i.label.isEmpty { name += "  (\(i.label))" }
            if !i.connected { name += "  ·  \(L.notConnected)" }
            let it = item(name) { [weak self] in self?.monitor.switchInput(i) }
            it.state = monitor.currentApp == i.appId ? .on : .off
            inputMenu.addItem(it)
        }
        menu.addItem(submenu(L.input, "rectangle.connected.to.line.below", inputMenu))

        let appMenu = NSMenu()
        for a in monitor.apps { appMenu.addItem(item(a.title) { [weak self] in self?.monitor.launch(a) }) }
        menu.addItem(submenu(L.apps, "play.rectangle", appMenu))

        let back = item(L.backToMac, symbol: "laptopcomputer") { [weak self] in self?.monitor.back() }
        back.keyEquivalent = "\r"
        back.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(back)
        menu.addItem(.separator())

        let eye = item(L.eyeCare, symbol: "eye") { [weak self] in
            guard let self else { return }
            self.monitor.setEyeCare(!self.monitor.eyeCare)
        }
        eye.state = monitor.eyeCare ? .on : .off
        menu.addItem(eye)
        menu.addItem(item(L.screenOff, symbol: "moon") { [weak self] in self?.monitor.turnScreenOff() })
        menu.addItem(item(L.standby, symbol: "power") { [weak self] in self?.monitor.standby() })
        if monitor.device?.mac != nil, monitor.status != .ready {
            menu.addItem(item(L.wake, symbol: "power.circle") { [weak self] in self?.monitor.wake() })
        }
        menu.addItem(.separator())

        if !keys.isRunning {
            menu.addItem(item(L.enableKeys, symbol: "keyboard") { [weak self] in
                SystemInfo.openAccessibilitySettings()
                self?.startKeys(prompt: true)
            })
        }

        let settings = NSMenu()
        settings.addItem(toggle(L.optionVolume, Settings.optionVolumeForBrightness) { Settings.optionVolumeForBrightness.toggle() })
        settings.addItem(toggle(L.volumeKeys, Settings.volumeKeys) { Settings.volumeKeys.toggle() })
        settings.addItem(.separator())
        settings.addItem(toggle(L.openAtLogin, Settings.openAtLogin) { Settings.openAtLogin.toggle() })
        settings.addItem(item(L.searchAgain) { [weak self] in
            guard let self else { return }
            self.monitor.reset()
            if let d = self.monitor.device { self.monitor.use(Device(ip: "0.0.0.0", name: d.name, mac: d.mac)) } else { self.monitor.start() }
        })
        settings.addItem(.separator())
        settings.addItem(item(L.about) { NSWorkspace.shared.open(URL(string: "https://github.com/davideconte/lgmon")!) })
        menu.addItem(submenu(L.settings, "gearshape", settings))

        let quit = NSMenuItem(title: L.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func syncSliders() {
        brightnessSlider?.update(monitor.brightness)
        volumeSlider?.update(monitor.volume)
    }

    // MARK: menu helpers

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, symbol: String? = nil, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title, action: action)
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    private func submenu(_ title: String, _ symbol: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        i.submenu = sub
        i.isEnabled = !sub.items.isEmpty
        return i
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let i = NSMenuItem()
        i.view = view
        return i
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

/// "Brightness" label above a full-width slider, like the Control Center modules.
final class SliderItemView: NSView {
    private let slider = NSSlider()
    private let onChange: (Int) -> Void
    private var lastSent: Int?
    private var lastMoved = Date.distantPast

    init(title: String, symbol: String, value: Int?, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.frame = NSRect(x: 14, y: 30, width: 200, height: 17)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.frame = NSRect(x: 14, y: 6, width: 18, height: 18)
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true
        slider.controlSize = .regular
        slider.target = self
        slider.action = #selector(moved)
        slider.frame = NSRect(x: 38, y: 4, width: 208, height: 22)
        [label, icon, slider].forEach(addSubview)
        slider.isEnabled = value != nil
        slider.integerValue = value ?? 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ value: Int?) {
        slider.isEnabled = value != nil
        // don't fight the user's finger while dragging
        if let value, Date().timeIntervalSince(lastMoved) > 0.6 { slider.integerValue = value }
    }

    @objc private func moved() {
        lastMoved = Date()
        let v = slider.integerValue
        guard v != lastSent else { return }
        lastSent = v
        onChange(v)
    }
}
