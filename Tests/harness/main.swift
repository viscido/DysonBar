import AppKit

// End-to-end tests against Tests/fake_dyson.py: sign-in flow, device choice,
// IoT-credential refresh, MQTT over WebSocket, state/commands, reconnects,
// session restore and expiry. Run via Tests/run.sh.

var failures = 0
func check(_ name: String, _ ok: Bool) {
    if !ok { failures += 1 }
    print(ok ? "PASS" : "FAIL", name)
}

@MainActor
func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

func sleep(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

func admin(_ base: URL, _ path: String) async -> [String: Any] {
    var request = URLRequest(url: base.appendingPathComponent(path))
    request.httpMethod = path == "admin/stats" ? "GET" : "POST"
    guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.001 } ?? false }

@MainActor
func menuTests() {
    _ = NSApplication.shared  // menu actions are dispatched through NSApp
    var chosen: String?
    let menu = TileMenuPresenter.makeMenu(
        options: [TileOption(id: "heat", title: "Heat"), TileOption(id: "cool", title: "Cool")],
        selectedID: "heat", onSelect: { chosen = $0 })
    menu.performActionForItem(at: 1)
    check("tile menu choice reaches its handler", chosen == "cool")
    check("tile menu marks the selected option", menu.items.first?.state == .on)
}

func packetTests() {
    let connect = Packet.connect(clientId: "client-1", keepAlive: 30)
    var expected: [UInt8] = [0x10, 22, 0, 6]
    expected += Array("MQIsdp".utf8)
    expected += [3, 0x02, 0, 30, 0, 8]
    expected += Array("client-1".utf8)
    check("CONNECT encoding (2-byte string lengths)", [UInt8](connect) == expected)
    check("remaining length 321 = C1 02", [UInt8](Packet.remainingLength(321)) == [0xC1, 0x02])
    let big = Packet.publish(topic: "t", payload: Data(repeating: 0x41, count: 300), qos: 1, id: 9)
    let parsed = try? Packet.parse(big)
    let expectedBody: Int = 2 + 1 + 2 + 300  // topic length, topic, packet id, payload
    let sizeOK = parsed?.size == big.count
    let bodyOK = parsed?.body.count == expectedBody
    check("parse multi-byte length packet", sizeOK && bodyOK)
    var incomplete = false
    do { incomplete = try Packet.parse(big.prefix(10)) == nil } catch {}
    check("parse waits for more bytes", incomplete)
    var malformed = false
    do { _ = try Packet.parse(Data([0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])) } catch { malformed = true }
    check("parse rejects 5-byte length", malformed)
}

@MainActor
func run(fake: String) async {
    packetTests()
    menuTests()

    // Start the fake cloud and read its ports.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc.arguments = [fake]
    let out = Pipe()
    proc.standardOutput = out
    try! proc.run()
    let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
    let ports = line.split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    guard ports.count == 2 else { print("FAIL fake server did not start: \(line)"); exit(1) }
    let apiBase = URL(string: "http://127.0.0.1:\(ports[0])")!
    defer { proc.terminate() }

    let suite = "dysonbar.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MemorySessionStore()
    var options = DysonModel.Options()
    options.apiBaseURL = { _ in apiBase }
    options.mqttURL = { URL(string: "ws://\($0)/mqtt")! }
    options.keepAlive = 2
    options.retryDelays = [0.3, 0.6]
    options.pendingTTL = 1.5

    let model = DysonModel(store: store, defaults: defaults, options: options)
    var signInRequests = 0
    model.onSignInRequired = { signInRequests += 1 }

    // First launch: no session.
    model.start()
    check("first launch asks to sign in", model.phase == .signedOut && signInRequests == 1)
    check("menu bar says Sign in", model.menuBarText == "Sign in")

    // Sign-in flow.
    let flow = LoginFlow(model: model)
    var finished = false
    flow.onFinished = { finished = true }
    flow.email = "nobody@example.com"
    flow.country = "it"
    flow.requestCode()
    _ = await until(3) { !flow.busy }
    check("unknown account is reported", flow.error != nil && flow.step == .email)

    flow.email = "user@example.com"
    flow.requestCode()
    _ = await until(3) { !flow.busy }
    check("code requested, culture uses country", flow.step == .code && flow.culture.hasSuffix("-IT"))

    // Code emails are rate-limited by Dyson: never request one more than needed.
    func codeRequests() async -> Int { await admin(apiBase, "admin/stats")["code_requests"] as? Int ?? -1 }
    flow.back()
    flow.requestCode()
    let afterBack = await codeRequests()
    check("back + Send code reuses the code already sent (no new email)",
          flow.step == .code && !flow.busy && afterBack == 1)
    _ = await admin(apiBase, "admin/ratelimit")
    flow.requestCode(forceNew: true)
    _ = await until(3) { !flow.busy }
    let afterLimit = await codeRequests()
    check("429 -> clear message, further requests paused",
          flow.isBlocked && (flow.error ?? "").contains("too many attempts")
          && (flow.error ?? "").contains("already received") && afterLimit == 2)
    flow.requestCode(forceNew: true)
    let whilePaused = await codeRequests()
    check("while paused no request reaches Dyson", !flow.busy && whilePaused == 2)
    let unblocked = await until(4) { !flow.isBlocked && flow.error == nil }
    check("pause ends after Retry-After", unblocked)

    func verifyRequests() async -> Int { await admin(apiBase, "admin/stats")["verify_requests"] as? Int ?? -1 }
    _ = await admin(apiBase, "admin/ratelimit-verify")
    flow.code = "123456"
    flow.password = "correct horse"
    flow.verify()
    _ = await until(3) { !flow.busy }
    let limitedVerifies = await verifyRequests()
    flow.code = "123456"
    flow.password = "correct horse"
    check("429 on Sign in disables Sign in", flow.isBlocked && !flow.canVerify
          && (flow.error ?? "").contains("Send a new code"))
    flow.verify()
    let pausedVerifies = await verifyRequests()
    check("while paused, Sign in sends nothing to Dyson", !flow.busy && pausedVerifies == limitedVerifies)
    let verifyUnblocked = await until(4) { !flow.isBlocked }
    check("Sign in re-enabled after Retry-After", verifyUnblocked && flow.canVerify)

    flow.code = "000000"
    flow.password = "correct horse"
    flow.verify()
    _ = await until(3) { !flow.busy }
    check("wrong code rejected, password cleared", flow.error != nil && flow.step == .code && flow.password.isEmpty)

    flow.code = " 123 456 "  // as copied from the email
    flow.password = "correct horse"
    flow.verify()
    _ = await until(3) { !flow.busy }
    check("device step lists the 2 connected devices (vacuum skipped)",
          flow.step == .device && flow.devices.count == 2)
    check("session token stored, password never stored",
          store.session?.token == "token-test-1" && flow.password.isEmpty
          && !String(decoding: try! JSONEncoder().encode(store.session!), as: UTF8.self).contains("horse"))

    flow.choose(flow.devices[1])
    check("choosing a device finishes sign-in", finished)
    check("stale IoT token rejected, fresh one fetched, live",
          await until(6) { model.phase == .live } && model.device?.serial == "TST-EU-BBB0002B")
    check("state streamed (QoS1 packet split across frames)",
          await until(3) { model.isOn && near(model.heatTargetC, 24.0) })
    check("env streamed (2 packets in 1 frame), fault message ignored",
          await until(3) { near(model.pm25, 12) && near(model.formaldehyde, 0.012) } && model.env["x"] == nil)
    check("menu bar shows room temperature", model.menuBarText == "23°")

    // Commands.
    model.adjustHeat(1)
    model.adjustHeat(1)
    check("rapid +/+ accumulates optimistically (24 -> 25)", near(model.heatTargetC, 25.0))
    await sleep(1.0)
    check("device confirmation keeps the value", near(model.heatTargetC, 25.0))
    model.send(["nmod": "ON"])
    check("optimistic toggle is instant", model.nightMode)
    check("unconfirmed write reverts after TTL", await until(3) { !model.nightMode })
    await sleep(2.5)

    var stats = await admin(apiBase, "admin/stats")
    let commands = stats["commands"] as? [[String: String]] ?? []
    check("commands reached the device", commands.contains {
        $0["hmax"].flatMap(Double.init).map { abs($0 / 10 - 273.15 - 25.0) < 0.06 } ?? false })
    check("PUBACK sent for QoS1 message", (stats["pubacks"] as? Int ?? 0) >= 1)
    check("keep-alive pings sent", (stats["pings"] as? Int ?? 0) >= 1)
    check("subscribed to status topics only",
          (stats["subscriptions"] as? [String] ?? []).allSatisfy { $0.hasSuffix("/status/#") })
    check("one handshake rejected (stale token)", stats["rejected"] as? Int == 1)

    // Connection loss.
    _ = await admin(apiBase, "admin/kick")
    check("dropped connection detected", await until(3) { model.phase != .live })
    check("reconnects with fresh credentials", await until(5) { model.phase == .live })

    // Device switch.
    model.selectDevice("TST-EU-AAA0001A")
    check("switches device", await until(5) { model.phase == .live && model.device?.serial == "TST-EU-AAA0001A" })
    check("new device state loaded", await until(3) { model.isOn && model.state["hmax"] == "2972" })

    // Restart: the stored session is reused, no sign-in prompt.
    let restartedStore = MemorySessionStore(store.session)
    let restarted = DysonModel(store: restartedStore, defaults: defaults, options: options)
    var restartedPrompts = 0
    restarted.onSignInRequired = { restartedPrompts += 1 }
    restarted.start()
    check("restart reconnects without sign-in, remembers device",
          await until(5) { restarted.phase == .live } && restartedPrompts == 0
          && restarted.device?.serial == "TST-EU-AAA0001A")
    restarted.signOut()
    check("explicit sign-out clears the session without prompting",
          restarted.phase == .signedOut && restartedStore.session == nil && restartedPrompts == 0)

    // Expired session.
    _ = await admin(apiBase, "admin/revoke")
    _ = await admin(apiBase, "admin/kick")
    check("revoked token -> signed out, sign-in requested",
          await until(5) { model.phase == .signedOut } && signInRequests == 2 && store.session == nil)
    check("email prefilled for the next sign-in", LoginFlow(model: model).email == "user@example.com")

    model.stop()
    stats = await admin(apiBase, "admin/stats")
    let errors = stats["errors"] as? [String] ?? ["no stats"]
    check("fake cloud saw only well-formed requests \(errors)", errors.isEmpty)
}

let fakePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/fake_dyson.py"
Task { @MainActor in
    await run(fake: fakePath)
    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
