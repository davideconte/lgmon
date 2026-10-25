import Foundation

/// Minimal webOS SSAP client: the websocket protocol LG's own remote app uses.
/// Port 3001 (TLS, self-signed certificate), JSON messages matched by id.
enum WebOSError: LocalizedError {
    case notConnected
    case pairingRejected
    case timeout
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "not connected"
        case .pairingRejected: return "pairing rejected on the monitor"
        case .timeout: return "the monitor did not answer"
        case .failed(let m): return m
        }
    }
}

final class WebOSClient: NSObject, URLSessionWebSocketDelegate {
    let host: String
    private(set) var clientKey: String?
    /// Called (on the main queue) when the monitor shows the pairing prompt.
    var onPairingPrompt: (() -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "lgmon.webos")
    private var nextId = 1
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var registerDone: ((Result<String, Error>) -> Void)?
    private var subscriptions: [String: ([String: Any]) -> Void] = [:]
    private(set) var isOpen = false

    init(host: String, clientKey: String?) {
        self.host = host
        self.clientKey = clientKey
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    // MARK: connection

    /// Opens the socket and registers. Returns the client key (new or confirmed).
    /// With a fresh key the monitor shows a prompt; we wait up to 60 s for the user.
    func connect() async throws -> String {
        guard let url = URL(string: "wss://\(host):3001") else { throw WebOSError.notConnected }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 8 << 20
        self.task = task
        task.resume()
        isOpen = true
        receive()

        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": Manifest.value,
        ]
        if let clientKey { payload["client-key"] = clientKey }
        let message: [String: Any] = ["type": "register", "id": "register_0", "payload": payload]

        let key: String = try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.registerDone = { cont.resume(with: $0) }
                self.send(message)
                self.queue.asyncAfter(deadline: .now() + (self.clientKey == nil ? 60 : 8)) {
                    if let done = self.registerDone {
                        self.registerDone = nil
                        done(.failure(WebOSError.timeout))
                    }
                }
            }
        }
        clientKey = key
        return key
    }

    func close() {
        isOpen = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failAll(WebOSError.notConnected)
    }

    // MARK: requests

    /// `uri` without the ssap:// prefix, e.g. "audio/getVolume".
    @discardableResult
    func request(_ uri: String, _ payload: [String: Any] = [:], timeout: Double = 5) async throws -> [String: Any] {
        guard isOpen else { throw WebOSError.notConnected }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                let id = String(self.nextId)
                self.nextId += 1
                self.pending[id] = { cont.resume(with: $0) }
                self.send(["id": id, "type": "request", "uri": "ssap://\(uri)", "payload": payload])
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if let done = self.pending.removeValue(forKey: id) {
                        done(.failure(WebOSError.timeout))
                    }
                }
            }
        }
    }

    /// Pushes every change of `uri` to `handler` (on the main queue) until the socket closes.
    func subscribe(_ uri: String, _ payload: [String: Any] = [:], _ handler: @escaping ([String: Any]) -> Void) {
        queue.async {
            let id = "sub\(self.nextId)"
            self.nextId += 1
            self.subscriptions[id] = handler
            self.send(["id": id, "type": "subscribe", "uri": "ssap://\(uri)", "payload": payload])
        }
    }

    /// Internal luna API, reachable only through an alert's callbacks (well-known webOS trick).
    /// Needed for writing settings such as the backlight. Results are not readable.
    func luna(_ uri: String, _ params: [String: Any]) async throws {
        let luna = "luna://\(uri)"
        let alert: [String: Any] = [
            "message": " ",
            "buttons": [["label": "", "onClick": luna, "params": params]],
            "onclose": ["uri": luna, "params": params],
            "onfail": ["uri": luna, "params": params],
        ]
        let res = try await request("system.notifications/createAlert", alert)
        guard let alertId = res["alertId"] else { throw WebOSError.failed("invalid alertId") }
        try await request("system.notifications/closeAlert", ["alertId": alertId])
    }

    // MARK: plumbing

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if error != nil { self?.queue.async { self?.connectionLost() } }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    if self.isOpen { log("socket closed: \(error.localizedDescription)") }
                    self.connectionLost()
                case .success(let message):
                    var data: Data?
                    switch message {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(obj)
                    }
                    if self.isOpen { self.receive() }
                }
            }
        }
    }

    private func handle(_ obj: [String: Any]) {
        let id = obj["id"].map { "\($0)" } ?? ""
        let type = obj["type"] as? String ?? ""
        let payload = obj["payload"] as? [String: Any] ?? [:]

        if id == "register_0" {
            if type == "registered", let key = payload["client-key"] as? String {
                registerDone?(.success(key)); registerDone = nil
            } else if type == "error" {
                registerDone?(.failure(WebOSError.pairingRejected)); registerDone = nil
            } else if type == "response", payload["pairingType"] as? String == "PROMPT", clientKey == nil {
                DispatchQueue.main.async { self.onPairingPrompt?() }
            }
            return
        }
        if let sub = subscriptions[id] {
            if type == "response" { DispatchQueue.main.async { sub(payload) } }
            return
        }
        guard let done = pending.removeValue(forKey: id) else { return }
        if type == "error" {
            done(.failure(WebOSError.failed(obj["error"] as? String ?? "error")))
        } else if payload["returnValue"] as? Bool == false {
            done(.failure(WebOSError.failed(payload["errorText"] as? String ?? "request failed")))
        } else {
            done(.success(payload))
        }
    }

    private func connectionLost() {
        guard isOpen else { return }
        isOpen = false
        failAll(WebOSError.notConnected)
    }

    private func failAll(_ error: Error) {
        queue.async {
            let all = self.pending
            self.pending.removeAll()
            all.values.forEach { $0(.failure(error)) }
            if let done = self.registerDone {
                self.registerDone = nil
                done(.failure(error))
            }
        }
    }

    // The monitor uses a self-signed certificate: trust it (local network only).
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { self.connectionLost() }
    }
}

/// LG's test-signed remote app manifest, as used by aiopylgtv/bscpylgtv (MIT).
/// "WRITE_SETTINGS" and "WRITE_NOTIFICATION_ALERT" in the signed part are what make luna calls work.
enum Manifest {
    static let signature =
        "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbm" +
        "ctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR" +
        "+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRy" +
        "aMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4" +
        "RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n" +
        "50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM" +
        "2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQoj" +
        "oa7NQnAtw=="

    static let value: [String: Any] = [
        "appVersion": "1.1",
        "manifestVersion": 1,
        "deviceName": "lgmon",
        "permissions": [
            "LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CLOSE", "TEST_OPEN", "TEST_PROTECTED",
            "CONTROL_AUDIO", "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK",
            "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_TV",
            "CONTROL_POWER", "CONTROL_TV_SCREEN", "READ_APP_STATUS", "READ_CURRENT_CHANNEL",
            "READ_INPUT_DEVICE_LIST", "READ_NETWORK_STATE", "READ_RUNNING_APPS",
            "READ_TV_CHANNEL_LIST", "WRITE_NOTIFICATION_TOAST", "READ_POWER_STATE",
            "READ_COUNTRY_INFO", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD",
            "READ_INSTALLED_APPS", "READ_SETTINGS", "READ_STORAGE_DEVICE_LIST",
        ],
        "signatures": [["signature": signature, "signatureVersion": 1]],
        "signed": [
            "appId": "com.lge.test",
            "created": "20140509",
            "localizedAppNames": ["": "LG Remote App", "ko-KR": "리모컨 앱", "zxx-XX": "ЛГ Rэмotэ AПП"],
            "localizedVendorNames": ["": "LG Electronics"],
            "permissions": [
                "TEST_SECURE", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD",
                "READ_INSTALLED_APPS", "READ_LGE_SDX", "READ_NOTIFICATIONS", "SEARCH",
                "WRITE_SETTINGS", "WRITE_NOTIFICATION_ALERT", "CONTROL_POWER",
                "READ_CURRENT_CHANNEL", "READ_RUNNING_APPS", "READ_UPDATE_INFO",
                "UPDATE_FROM_REMOTE_APP", "READ_LGE_TV_INPUT_EVENTS", "READ_TV_CURRENT_TIME",
            ],
            "serial": "2f930e2d2cfe083771f68e4fe7bb07",
            "vendorId": "com.lge",
        ],
    ]
}
