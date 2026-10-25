import AppKit

struct MonitorInput: Equatable {
    let id: String       // HDMI_1
    let label: String    // "Mac", "PC"
    let appId: String    // com.webos.app.hdmi1
    let connected: Bool
}

struct MonitorApp: Equatable {
    let id: String
    let title: String
}

/// State and commands for the LG monitor. Everything runs on the main actor;
/// network calls are awaited, writes are coalesced so fast key repeats stay smooth.
@MainActor
final class Monitor {
    static let shared = Monitor()

    enum Status: Equatable { case searching, pairing, ready, unreachable(String), choose([Device]) }

    private(set) var status: Status = .searching { didSet { log("status \(status)"); changed() } }
    private(set) var device: Device?
    private(set) var brightness: Int?
    private(set) var volume: Int?
    private(set) var muted = false
    private(set) var inputs: [MonitorInput] = []
    private(set) var apps: [MonitorApp] = []
    private(set) var currentApp: String?

    var onChange: (() -> Void)?
    var onPairingPrompt: (() -> Void)?

    private var client: WebOSClient?
    private var connecting: Task<WebOSClient, Error>?
    /// right after a write webOS keeps reporting the old value: trust ours for a while
    private var lastWrite = Date.distantPast
    private var homeInput: String?
    private var screenOff = false

    private var brightnessTarget: Int?
    private var volumeTarget: Int?
    private var flushing = false

    private func changed() { onChange?() }

    // MARK: connection

    func start() {
        device = Store.loadDevice()
        log("start, saved device \(String(describing: device))")
        Task { _ = try? await connectedClient(); await refresh(); await loadLists() }
    }

    func use(_ d: Device) {
        Store.save(d)
        device = d
        reset()
        Task { _ = try? await connectedClient(); await refresh(); await loadLists() }
    }

    func reset() {
        client?.close()
        client = nil
        connecting = nil
    }

    private func connectedClient() async throws -> WebOSClient {
        if let client, client.isOpen { return client }
        if let connecting { return try await connecting.value }
        let task = Task { () throws -> WebOSClient in try await self.openClient() }
        connecting = task
        defer { connecting = nil }
        do {
            let c = try await task.value
            client = c
            status = .ready
            return c
        } catch {
            if case .pairing = status {} else if case .choose = status {} else {
                status = .unreachable(error.localizedDescription)
            }
            throw error
        }
    }

    private func openClient() async throws -> WebOSClient {
        if let d = device {
            // the very first attempt can fail while macOS asks for Local Network access: retry once
            for attempt in 1...2 {
                do { return try await open(d) } catch { log("open \(d.ip) attempt \(attempt) failed: \(error)") }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // first run, or the IP changed: look around
        status = .searching
        let found = await Task.detached { Discovery.search() }.value
        log("discovery found \(found)")
        guard !found.isEmpty else { throw WebOSError.failed(L.notFound) }
        var pick: Device?
        if let d = device {
            pick = found.first { ($0.mac != nil && $0.mac == d.mac) || ($0.name != nil && $0.name == d.name) }
        }
        if pick == nil {
            if found.count == 1 { pick = found[0] } else { status = .choose(found); throw WebOSError.failed(L.chooseMonitor) }
        }
        var d = pick!
        if d.name == nil { d.name = device?.name }
        if d.mac == nil { d.mac = device?.mac }
        Store.save(d)
        device = d
        return try await open(d)
    }

    private func open(_ d: Device) async throws -> WebOSClient {
        let c = WebOSClient(host: d.ip, clientKey: Store.key(for: d))
        c.onPairingPrompt = { [weak self] in
            self?.status = .pairing
            self?.onPairingPrompt?()
        }
        let key = try await c.connect()
        Store.setKey(key, for: d)
        return c
    }

    /// Runs a command, reconnecting once if the socket died (standby, Wi-Fi hiccup).
    @discardableResult
    private func run<T>(_ op: (WebOSClient) async throws -> T) async throws -> T {
        do {
            return try await op(try await connectedClient())
        } catch {
            client?.close()
            client = nil
            return try await op(try await connectedClient())
        }
    }

    // MARK: reading

    func refresh() async {
        guard Date().timeIntervalSince(lastWrite) > 5 else { return }
        do {
            try await run { c in
                let pic = try await c.request("settings/getSystemSettings", ["category": "picture", "keys": ["backlight"]])
                if let s = pic["settings"] as? [String: Any] {
                    self.brightness = (s["backlight"] as? Int) ?? Int("\(s["backlight"] ?? "")")
                }
                let audio = try await c.request("audio/getStatus")
                self.muted = audio["mute"] as? Bool ?? false
                self.volume = (audio["volume"] as? Int) ?? ((audio["volumeStatus"] as? [String: Any])?["volume"] as? Int)
                let app = try await c.request("com.webos.applicationManager/getForegroundAppInfo")
                self.currentApp = app["appId"] as? String
            }
            changed()
        } catch {}
    }

    func loadLists() async {
        do {
            try await run { c in
                let res = try await c.request("tv/getExternalInputList")
                self.inputs = (res["devices"] as? [[String: Any]] ?? []).map {
                    MonitorInput(id: $0["id"] as? String ?? "", label: $0["label"] as? String ?? "",
                                 appId: $0["appId"] as? String ?? "", connected: $0["connected"] as? Bool ?? false)
                }
                let apps = try await c.request("com.webos.applicationManager/listLaunchPoints")
                self.apps = (apps["launchPoints"] as? [[String: Any]] ?? []).compactMap {
                    guard let id = $0["id"] as? String, let title = $0["title"] as? String,
                          !id.hasPrefix("com.webos.app.") else { return nil }  // skip system apps
                    return MonitorApp(id: id, title: title)
                }
            }
            changed()
        } catch {}
    }

    // MARK: brightness and volume (local value first, network after)

    /// Returns the new value immediately, for the on-screen indicator.
    @discardableResult
    func adjustBrightness(by delta: Int) -> Int? {
        guard let b = brightness else { Task { await refresh() }; return nil }
        setBrightness(b + delta)
        return brightness
    }

    func setBrightness(_ value: Int) {
        brightness = max(0, min(100, value))
        brightnessTarget = brightness
        lastWrite = Date()
        changed()
        flush()
    }

    func adjustVolume(by delta: Int) {
        guard let v = volume else { Task { await refresh() }; return }
        setVolume(v + delta)
    }

    func setVolume(_ value: Int) {
        volume = max(0, min(100, value))
        muted = false
        volumeTarget = volume
        lastWrite = Date()
        changed()
        flush()
    }

    func toggleMute() {
        muted.toggle()
        lastWrite = Date()
        changed()
        let m = muted
        Task { try? await run { try await $0.request("audio/setMute", ["mute": m]) } }
    }

    /// Sends only the latest target: holding a key doesn't queue up dozens of writes.
    private func flush() {
        guard !flushing else { return }
        flushing = true
        Task {
            defer { flushing = false }
            while brightnessTarget != nil || volumeTarget != nil {
                if let b = brightnessTarget {
                    brightnessTarget = nil
                    let wake = screenOff
                    screenOff = false
                    try? await run { c in
                        if wake { try await c.request("com.webos.service.tvpower/power/turnOnScreen", ["standbyMode": "active"]) }
                        try await c.luna("com.webos.settingsservice/setSystemSettings",
                                         ["category": "picture", "settings": ["backlight": b]])
                    }
                }
                if let v = volumeTarget {
                    volumeTarget = nil
                    _ = try? await run { try await $0.request("audio/setVolume", ["volume": v]) }
                }
            }
        }
    }

    // MARK: inputs, apps, power

    private func rememberHome() {
        if let cur = currentApp, inputs.contains(where: { $0.appId == cur }) { homeInput = cur }
    }

    func switchInput(_ input: MonitorInput) {
        rememberHome()
        currentApp = input.appId
        Task { try? await run { try await $0.request("tv/switchInput", ["inputId": input.id]) } }
    }

    func launch(_ app: MonitorApp) {
        rememberHome()
        currentApp = app.id
        Task { try? await run { try await $0.request("system.launcher/launch", ["id": app.id]) } }
    }

    func back() {
        // input "apps" launch like any other app
        guard let home = homeInput ?? inputs.first(where: { $0.label.lowercased() == "mac" })?.appId else { return }
        currentApp = home
        Task { try? await run { try await $0.request("system.launcher/launch", ["id": home]) } }
    }

    func turnScreenOff() {
        screenOff = true
        Task { try? await run { try await $0.request("com.webos.service.tvpower/power/turnOffScreen", ["standbyMode": "active"]) } }
    }

    func standby() {
        Task { try? await run { try await $0.request("system/turnOff") } }
    }

    func wake() {
        if let mac = device?.mac { Discovery.wakeOnLAN(mac: mac) }
    }
}
