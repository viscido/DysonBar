import Foundation

/// App state and the device connection: signs in with the cloud API, fetches
/// short-lived AWS IoT credentials and keeps one MQTT-over-WebSocket session.
/// Nothing but the session token (Keychain) and the chosen device / last email
/// (UserDefaults) is persisted; device state lives in memory only.
@MainActor
final class DysonModel: ObservableObject {
    enum Phase: Equatable {
        case signedOut
        case connecting
        case live
        case offline(String)  // retrying in the background
    }

    struct Options {
        var apiBaseURL: (String) -> URL = DysonCloudAPI.productionBaseURL(country:)
        var mqttURL: (String) -> URL = { URL(string: "wss://\($0)/mqtt")! }
        var keepAlive: UInt16 = 30
        var retryDelays: [TimeInterval] = [2, 5, 15, 30, 60]
        var pendingTTL: TimeInterval = 4
    }

    @Published private(set) var phase: Phase = .signedOut
    @Published private(set) var state: [String: String] = [:]
    @Published private(set) var env: [String: String] = [:]
    @Published private(set) var devices: [DysonDevice] = []
    @Published private(set) var device: DysonDevice?

    /// Main thread, after any change that affects the menu-bar title.
    var onStateChange: (() -> Void)?
    /// Main thread, when the user has to sign in: first launch or expired session
    /// (not after an explicit sign-out).
    var onSignInRequired: (() -> Void)?

    private(set) var session: DysonSession?
    private let store: SessionStore
    private let defaults: UserDefaults
    private let options: Options
    private var mqtt: MQTTClient?
    private var generation = 0  // bumps on every (re)connect; stale callbacks are dropped
    private var attempt = 0
    private var retryWork: DispatchWorkItem?

    // Device-confirmed product state; `state` is this plus pending optimistic
    // writes, so the UI reacts instantly and repeated taps accumulate.
    private var confirmed: [String: String] = [:]
    private var pending: [String: (value: String, until: Date)] = [:]

    private enum Keys {
        static let serial = "selectedSerial"
        static let email = "lastEmail"
        static let country = "lastCountry"
    }

    init(store: SessionStore = KeychainSessionStore(), defaults: UserDefaults = .standard,
         options: Options = Options()) {
        self.store = store
        self.defaults = defaults
        self.options = options
    }

    // MARK: - lifecycle

    func start() {
        session = store.load()
        if session == nil {
            setPhase(.signedOut)
            onSignInRequired?()  // first launch
        } else {
            connect()
        }
    }

    func stop() {
        teardown()
    }

    /// E.g. after wake from sleep, when the old socket is certainly dead.
    func reconnectNow() {
        guard session != nil else { return }
        connect()
    }

    // MARK: - account

    var lastEmail: String { session?.email ?? defaults.string(forKey: Keys.email) ?? "" }
    var lastCountry: String? { session?.country ?? defaults.string(forKey: Keys.country) }

    func api(country: String) -> DysonCloudAPI {
        DysonCloudAPI(baseURL: options.apiBaseURL(country))
    }

    /// Stores a fresh session and loads its devices; the caller then picks one
    /// with `selectDevice`, which connects.
    func signIn(_ newSession: DysonSession) async throws -> [DysonDevice] {
        let list = try await api(country: newSession.country).devices(token: newSession.token)
        guard !list.isEmpty else { throw DysonAPIError.noDevices }
        store.save(newSession)
        defaults.set(newSession.email, forKey: Keys.email)
        defaults.set(newSession.country, forKey: Keys.country)
        session = newSession
        devices = list
        return list
    }

    func signOut() {
        teardown()
        store.delete()
        session = nil
        devices = []
        device = nil
        resetDeviceState()
        setPhase(.signedOut)
    }

    func selectDevice(_ serial: String) {
        defaults.set(serial, forKey: Keys.serial)
        if device?.serial != serial { resetDeviceState() }
        if session != nil { connect() }
    }

    // MARK: - connection

    private func connect() {
        guard let session = session else { return }
        teardown()
        let gen = generation
        setPhase(.connecting)
        Task {
            do {
                let api = self.api(country: session.country)
                if self.devices.isEmpty {
                    self.devices = try await api.devices(token: session.token)
                }
                guard gen == self.generation else { return }
                guard let dev = self.pickDevice() else { throw DysonAPIError.noDevices }
                self.device = dev
                // IoT credentials are short-lived: fetch fresh ones for every connection.
                let creds = try await api.iotCredentials(token: session.token, serial: dev.serial)
                guard gen == self.generation else { return }
                self.openMQTT(creds, gen: gen)
            } catch DysonAPIError.unauthorized {
                guard gen == self.generation else { return }
                self.sessionExpired()
            } catch {
                guard gen == self.generation else { return }
                self.scheduleRetry(gen, reason: error.localizedDescription)
            }
        }
    }

    private func pickDevice() -> DysonDevice? {
        let saved = defaults.string(forKey: Keys.serial)
        return devices.first { $0.serial == saved } ?? devices.first
    }

    private func openMQTT(_ creds: IoTCredentials, gen: Int) {
        let client = MQTTClient(config: .init(url: options.mqttURL(creds.endpoint),
                                              headers: creds.webSocketHeaders,
                                              clientId: creds.clientId,
                                              keepAlive: options.keepAlive))
        client.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, gen: gen) }
            }
        }
        mqtt = client
        client.open()
    }

    private func handle(_ event: MQTTClient.Event, gen: Int) {
        guard gen == generation, let device = device else { return }
        switch event {
        case .connected:
            attempt = 0
            mqtt?.subscribe(device.statusTopics)
            setPhase(.live)
            requestState()
        case .message(_, let payload):
            merge(payload)
        case .closed(let failure):
            mqtt = nil
            scheduleRetry(gen, reason: failure?.localizedDescription ?? "Disconnected.")
        }
    }

    private func scheduleRetry(_ gen: Int, reason: String) {
        setPhase(.offline(reason))
        let delays = options.retryDelays
        let delay = delays[min(attempt, delays.count - 1)]
        attempt += 1
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, gen == self.generation else { return }
                self.connect()
            }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func sessionExpired() {
        teardown()
        store.delete()
        session = nil
        setPhase(.signedOut)
        onSignInRequired?()
    }

    private func teardown() {
        generation += 1
        retryWork?.cancel()
        retryWork = nil
        mqtt?.close()
        mqtt = nil
    }

    private func setPhase(_ new: Phase) {
        guard phase != new else { return }
        phase = new
        onStateChange?()
    }

    // MARK: - messages

    private static let stateMessages: Set<String> = ["CURRENT-STATE", "STATE-CHANGE"]
    private static let environmentMessages: Set<String> = ["ENVIRONMENTAL-CURRENT-SENSOR-DATA"]

    private func merge(_ payload: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let kind = obj["msg"] as? String else { return }
        var changed = false
        if Self.stateMessages.contains(kind), let values = obj["product-state"] as? [String: Any] {
            for (key, value) in values {
                if let v = Self.scalar(value) { confirmed[key] = v }
            }
            changed = recompute()
        } else if Self.environmentMessages.contains(kind), let values = obj["data"] as? [String: Any] {
            var next = env
            for (key, value) in values {
                if let v = Self.scalar(value) { next[key] = v }
            }
            if next != env {
                env = next
                changed = true
            }
        }
        if changed { onStateChange?() }
    }

    /// STATE-CHANGE carries [old, new] pairs; CURRENT-STATE plain values.
    private static func scalar(_ value: Any) -> String? {
        let v = (value as? [Any])?.last ?? value
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private func resetDeviceState() {
        confirmed = [:]
        pending = [:]
        env = [:]
        recompute()
    }

    /// state = confirmed + still-pending optimistic writes. A pending value is
    /// dropped once the device confirms it or its TTL runs out.
    @discardableResult
    private func recompute() -> Bool {
        let now = Date()
        pending = pending.filter { $0.value.until > now && confirmed[$0.key] != $0.value.value }
        var display = confirmed
        for (key, p) in pending { display[key] = p.value }
        guard display != state else { return false }
        state = display
        return true
    }

    // MARK: - commands

    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func publish(_ message: [String: Any], qos: UInt8) {
        guard phase == .live, let device = device, let mqtt = mqtt,
              let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        mqtt.publish(device.commandTopic, data, qos: qos)
    }

    /// STATE-SET. Shows immediately and is reconciled with the device's
    /// STATE-CHANGE; if never confirmed it reverts after `pendingTTL`.
    func send(_ data: [String: String]) {
        guard phase == .live else { return }
        let ttl = options.pendingTTL
        let until = Date().addingTimeInterval(ttl)
        for (key, value) in data { pending[key] = (value, until) }
        if recompute() { onStateChange?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + ttl + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                if self?.recompute() == true { self?.onStateChange?() }
            }
        }
        publish(["msg": "STATE-SET", "time": Self.timestamp.string(from: Date()),
                 "mode-reason": "LAPP", "data": data], qos: 1)
    }

    func requestState() {
        let now = Self.timestamp.string(from: Date())
        for msg in ["REQUEST-CURRENT-STATE", "REQUEST-PRODUCT-ENVIRONMENT-CURRENT-SENSOR-DATA"] {
            publish(["msg": msg, "time": now], qos: 0)
        }
    }

    func togglePower() { send(["fpwr": isOn ? "OFF" : "ON"]) }

    /// Heat target range the device accepts, in °C.
    static let heatRange: ClosedRange<Double> = 1...37
    static let sleepPresets = [0, 15, 30, 60, 120, 240]

    func adjustHeat(_ delta: Double) {
        guard let current = heatTargetC else { return }
        setHeatTarget(current + delta * 0.5)
    }

    /// Absolute heat target (0.5 °C steps); also switches heating on.
    func setHeatTarget(_ celsius: Double) {
        let c = min(max((celsius * 2).rounded() / 2, Self.heatRange.lowerBound), Self.heatRange.upperBound)
        send(["hmax": String(Int(((c + 273.15) * 10).rounded())), "hmod": "HEAT"])
    }

    func setHeatMode(_ on: Bool) { send(["hmod": on ? "HEAT" : "OFF"]) }

    /// nil = auto. Turns the unit on if it is off.
    func setFanSpeed(_ level: Int?) {
        var data: [String: String]
        if let level = level {
            data = ["fnsp": String(format: "%04d", min(max(level, 1), 10)), "auto": "OFF"]
        } else {
            data = ["fnsp": "AUTO", "auto": "ON"]
        }
        if !isOn { data["fpwr"] = "ON" }
        send(data)
    }

    /// 0 = off.
    func setSleep(minutes: Int) {
        send(["sltm": minutes <= 0 ? "OFF" : String(format: "%04d", minutes)])
    }

    /// Front airflow (`fdir` ON) vs. backward/diffused (OFF) — community-documented.
    func setFrontAirflow(_ on: Bool) { send(["fdir": on ? "ON" : "OFF"]) }

    func adjustFan(_ delta: Int) {
        let next = min(max((fanSpeedNumber ?? 5) + delta, 1), 10)
        var data = ["fnsp": String(format: "%04d", next), "auto": "OFF"]
        if !isOn { data["fpwr"] = "ON" }
        send(data)
    }

    func toggleRotation() { send(["oson": rotation ? "OFF" : "ON"]) }

    func toggleAuto() {
        if autoMode {
            send(["auto": "OFF", "fnsp": String(format: "%04d", fanSpeedNumber ?? 5)])
        } else {
            send(["auto": "ON", "fnsp": "AUTO"])
        }
    }

    func toggleNight() { send(["nmod": nightMode ? "OFF" : "ON"]) }
    func toggleContinuous() { send(["rhtm": continuous ? "OFF" : "ON"]) }

    /// Off → 15m → 30m → 1h → 2h → 4h. A timer set elsewhere to a non-preset
    /// value moves to the nearest preset in the pressed direction.
    func cycleSleep(_ delta: Int) {
        let presets = Self.sleepPresets
        let current = sleepMinutes ?? 0
        let next: Int
        if delta > 0 {
            next = presets.first(where: { $0 > current }) ?? presets[presets.count - 1]
        } else {
            next = presets.last(where: { $0 < current }) ?? 0
        }
        setSleep(minutes: next)
    }

    #if DEBUG
    /// Previews and snapshots: show a fixed state without any connection.
    func loadPreview(phase: Phase, device: DysonDevice?, state: [String: String], env: [String: String]) {
        self.phase = phase
        self.device = device
        confirmed = state
        pending = [:]
        self.env = env
        recompute()
    }
    #endif

    // MARK: - derived values

    var connected: Bool { phase == .live }
    var deviceName: String { device?.name ?? "Dyson" }

    func kelvinToC(_ s: String?) -> Double? {
        guard let s = s, s != "OFF", let v = Double(s) else { return nil }
        return v / 10.0 - 273.15
    }

    /// Sensor reading with zero padding removed and fixed-point scale applied;
    /// nil while the sensor is idle ("OFF", e.g. fan off).
    func envNumber(_ key: String, divisor: Double = 1) -> Double? {
        guard let v = env[key], v != "OFF", let n = Double(v) else { return nil }
        return n / divisor
    }

    var isOn: Bool { state["fpwr"] == "ON" }
    /// Rounded to 0.5 °C: the device stores the target in tenths of kelvin, so
    /// 24 °C comes back as 2972 = 24.05 °C.
    var heatTargetC: Double? { kelvinToC(state["hmax"]).map { ($0 * 2).rounded() / 2 } }
    var roomTempC: Double? { kelvinToC(env["tact"]) }
    var humidity: Double? { envNumber("hact") }
    var pm25: Double? { envNumber("pm25") }
    var pm10: Double? { envNumber("pm10") }
    /// VOC index (reported ×10).
    var voc: Double? { envNumber("va10", divisor: 10) }
    /// Formaldehyde in mg/m³ (reported ×1000; `hchr` as in libdyson, `hcho` fallback).
    var formaldehyde: Double? { envNumber("hchr", divisor: 1000) ?? envNumber("hcho", divisor: 1000) }
    var hasFormaldehydeSensor: Bool { env["hchr"] != nil || env["hcho"] != nil }

    var fanSpeedText: String {
        guard let fnsp = state["fnsp"] else { return "—" }
        if fnsp == "AUTO" { return "Auto" }
        if let n = Int(fnsp) { return "\(n)" }
        return fnsp
    }

    var fanSpeedNumber: Int? { state["fnsp"].flatMap { Int($0) } }
    var isHeating: Bool { state["hsta"] == "HEAT" }
    /// Heat mode selected (the unit heats when below target); `isHeating` = heating right now.
    var heatModeOn: Bool { state["hmod"] == "HEAT" }
    var frontAirflow: Bool { state["fdir"] != "OFF" }
    var hasFrontAirflowSetting: Bool { state["fdir"] != nil }
    /// NO₂ index (reported ×10).
    var nox: Double? { envNumber("noxl", divisor: 10) }
    var hasHeater: Bool { state["hmax"] != nil }
    var autoMode: Bool { state["auto"] == "ON" }
    var rotation: Bool { state["oson"] == "ON" }
    var nightMode: Bool { state["nmod"] == "ON" }
    var continuous: Bool { state["rhtm"] == "ON" }

    var sleepMinutes: Int? {
        guard let sltm = state["sltm"], sltm != "OFF" else { return nil }
        return Int(sltm)
    }

    var sleepTimerText: String {
        guard let m = sleepMinutes else { return "Off" }
        if m >= 60, m % 60 == 0 { return "\(m / 60)h" }
        return "\(m)m"
    }

    var filterLife: Double? {
        guard let hflr = state["hflr"], let v = Double(hflr) else { return nil }
        return min(max(v / 100.0, 0), 1)
    }

    var errorCode: String? {
        guard let ercd = state["ercd"], !ercd.isEmpty, ercd != "NONE" else { return nil }
        return ercd
    }

    /// Live room temperature while running, otherwise an explicit state.
    var menuBarText: String {
        if phase == .signedOut { return "Sign in" }
        if !connected || state.isEmpty { return "--°" }
        if !isOn { return "Off" }
        if let r = roomTempC { return String(format: "%.0f°", r) }
        if let h = heatTargetC { return String(format: "%.0f°", h) }
        return "On"
    }

    var statusText: String {
        switch phase {
        case .signedOut: return "Not signed in"
        case .connecting: return "Connecting…"
        case .offline: return "Offline — retrying"
        case .live: break
        }
        if !isOn { return "Off" }
        var parts: [String] = []
        if isHeating { parts.append("Heating") }
        if state["fnst"] == "FAN" { parts.append("Fan \(fanSpeedText)") }
        return parts.isEmpty ? "Idle" : parts.joined(separator: " · ")
    }

    var detailText: String {
        if case .offline(let reason) = phase { return reason }
        var parts: [String] = []
        if let t = heatTargetC { parts.append(String(format: "Heat %.1f°", t)) }
        if let t = roomTempC { parts.append(String(format: "Room %.1f°", t)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
