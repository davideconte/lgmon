import AppKit
import ApplicationServices
import CoreAudio
import ServiceManagement

// MARK: strings

enum L {
    static let it = (Locale.preferredLanguages.first ?? "").hasPrefix("it")
    static func t(_ en: String, _ itText: String) -> String { it ? itText : en }

    static let brightness = t("Brightness", "Luminosità")
    static let volume = t("Volume", "Volume")
    static let input = t("Input", "Ingresso")
    static let apps = t("Monitor Apps", "App del monitor")
    static let backToMac = t("Back to This Mac", "Torna al Mac")
    static let screenOff = t("Turn Screen Off", "Spegni schermo")
    static let eyeCare = t("Eye Comfort (Less Blue Light)", "Comfort visivo (meno luce blu)")
    static let standby = t("Standby", "Standby")
    static let wake = t("Wake Monitor", "Accendi monitor")
    static let settings = t("Settings", "Impostazioni")
    static let optionVolume = t("⌥ + Volume Keys Change Brightness", "⌥ + tasti volume cambiano la luminosità")
    static let volumeKeys = t("Volume Keys Control the Monitor's Speakers", "Tasti volume regolano gli altoparlanti del monitor")
    static let openAtLogin = t("Open at Login", "Apri al login")
    static let searchAgain = t("Search Monitors Again", "Cerca di nuovo i monitor")
    static let about = t("lgmon on GitHub", "lgmon su GitHub")
    static let quit = t("Quit lgmon", "Esci da lgmon")
    static let searching = t("Looking for your LG monitor…", "Cerco il monitor LG…")
    static let pairing = t("Accept lgmon on your monitor", "Accetta lgmon sul monitor")
    static let notFound = t("No LG webOS monitor found on the network", "Nessun monitor LG webOS trovato in rete")
    static let chooseMonitor = t("Choose a monitor", "Scegli un monitor")
    static let unreachable = t("Monitor not reachable", "Monitor non raggiungibile")
    static let enableKeys = t("Enable Keyboard Shortcuts…", "Attiva le scorciatoie da tastiera…")
    static let notConnected = t("not connected", "non collegato")
}

// MARK: settings

enum Settings {
    private static let d = UserDefaults.standard
    static var optionVolumeForBrightness: Bool {
        get { d.object(forKey: "optionVolumeForBrightness") as? Bool ?? true }
        set { d.set(newValue, forKey: "optionVolumeForBrightness") }
    }
    static var volumeKeys: Bool {
        get { d.object(forKey: "volumeKeys") as? Bool ?? true }
        set { d.set(newValue, forKey: "volumeKeys") }
    }
    static var match: String { d.string(forKey: "match") ?? "LG" }

    static var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    /// First launch: open at login by default, like most menu bar utilities.
    static func firstLaunchDefaults() {
        guard !d.bool(forKey: "launchedBefore") else { return }
        d.set(true, forKey: "launchedBefore")
        openAtLogin = true
    }
}

// MARK: screens and audio

enum SystemInfo {
    static func screenUnderMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    static func isMonitor(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.localizedCaseInsensitiveContains(Settings.match)
    }

    static var pointerOnMonitor: Bool { isMonitor(screenUnderMouse()?.localizedName) }

    /// Name of the current default audio output (CoreAudio).
    static func defaultOutputName() -> String? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    static var audioGoesToMonitor: Bool { isMonitor(defaultOutputName()) }

    static func accessibilityTrusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// MARK: log

/// ~/Library/Logs/lgmon.log, for troubleshooting.
func log(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/lgmon.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
