import Foundation

struct Device: Codable, Equatable {
    var ip: String
    var name: String?
    var mac: String?
}

/// Shared with the CLI: ~/.config/lgmon/device.json (+ keys.json for the app's pairing key).
enum Store {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lgmon")
    private static var deviceURL: URL { dir.appendingPathComponent("device.json") }
    private static var keysURL: URL { dir.appendingPathComponent("keys.json") }

    static func loadDevice() -> Device? {
        guard let data = try? Data(contentsOf: deviceURL) else { return nil }
        return try? JSONDecoder().decode(Device.self, from: data)
    }

    static func save(_ device: Device) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(device).write(to: deviceURL)
    }

    /// Keys are per device: MAC when known (survives DHCP changes), else IP.
    static func key(for d: Device) -> String? {
        keys()[d.mac ?? d.ip] ?? keys()[d.ip]
    }

    static func setKey(_ key: String, for d: Device) {
        var all = keys()
        all[d.mac ?? d.ip] = key
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted]).write(to: keysURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysURL.path)
    }

    private static func keys() -> [String: String] {
        guard let data = try? Data(contentsOf: keysURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return obj
    }
}

enum Discovery {
    /// SSDP search for webOS devices. Blocking, run it off the main thread.
    static func search(timeout: TimeInterval = 3) -> [Device] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")

        let targets = ["urn:lge-com:service:webos-second-screen:1", "upnp:rootdevice",
                       "urn:dial-multiscreen-org:service:dial:1"]
        func sendSearch() {
            for st in targets {
                let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(st)\r\n\r\n"
                _ = msg.withCString { ptr in
                    withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, ptr, strlen(ptr), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }

        var found: [String: (device: Device, webos: Bool)] = [:]
        let start = Date()
        var sent = 0
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date().timeIntervalSince(start) < timeout {
            // UDP gets lost and webOS sometimes ignores back-to-back searches: resend a few times
            if sent < 3, Date().timeIntervalSince(start) >= Double(sent) { sendSearch(); sent += 1 }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8) else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            var entry = found[ip] ?? (Device(ip: ip), false)
            for line in text.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if k == "st", v.contains("webos-second-screen") { entry.webos = true }
                if k == "dlnadevicename.lge.com" { entry.device.name = v.removingPercentEncoding ?? v }
                if k == "wakeup", let r = v.range(of: #"MAC=([0-9a-fA-F:]{17})"#, options: .regularExpression) {
                    entry.device.mac = String(v[r].dropFirst(4)).lowercased()
                }
            }
            found[ip] = entry
        }
        return found.values.filter { $0.webos }.map { $0.device }.sorted { $0.ip < $1.ip }
    }

    static func wakeOnLAN(mac: String) {
        let hex = mac.replacingOccurrences(of: ":", with: "")
        guard hex.count == 12 else { return }
        var macBytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            macBytes.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        let packet = [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: macBytes, count: 16).joined())
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        for port in [9, 7] {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = INADDR_BROADCAST
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
