import Foundation

/// Minimal MQTT 3.1 client over WebSocket — what the Dyson AWS IoT endpoint
/// needs: CONNECT, SUBSCRIBE, PUBLISH (QoS 0/1), PUBACK and keep-alive pings.
///
/// One instance is one connection attempt. Whatever ends it (refused handshake,
/// network loss, missed pings, `close()`), `.closed` is reported exactly once
/// and the owner creates a new instance to reconnect. All work runs on a
/// private serial queue; events are delivered on that queue.
final class MQTTClient: NSObject, URLSessionWebSocketDelegate {
    struct Config {
        var url: URL
        var headers: [String: String] = [:]
        var clientId: String
        var keepAlive: UInt16 = 30
        var connectTimeout: TimeInterval = 20
    }

    enum Failure: LocalizedError, Equatable {
        case rejected(httpStatus: Int)   // handshake refused, e.g. expired IoT token
        case refused(returnCode: UInt8)  // CONNACK return code != 0
        case timeout
        case closedByServer
        case protocolError(String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let status): return "Dyson cloud refused the connection (HTTP \(status))."
            case .refused(let rc): return "Dyson cloud refused the session (code \(rc))."
            case .timeout: return "The connection timed out."
            case .closedByServer: return "The Dyson cloud closed the connection."
            case .protocolError(let what): return "Protocol error: \(what)."
            case .transport(let what): return what
            }
        }
    }

    enum Event {
        case connected
        case message(topic: String, payload: Data)
        case closed(Failure?)  // nil: closed by us
    }

    /// Set before `open()`.
    var onEvent: ((Event) -> Void)?

    private let config: Config
    private let queue = DispatchQueue(label: "dysonbar.mqtt")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var timer: DispatchSourceTimer?
    private var inbound = Data()
    private var lastPacketId: UInt16 = 0
    private var openedAt = Date()
    private var lastInbound = Date()
    private var lastPing = Date()
    private var isConnected = false
    private var finished = false

    init(config: Config) {
        self.config = config
        super.init()
    }

    func open() {
        queue.async { [self] in
            let delegateQueue = OperationQueue()
            delegateQueue.underlyingQueue = queue
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: .ephemeral, delegate: self,
                                     delegateQueue: delegateQueue)
            var request = URLRequest(url: config.url, timeoutInterval: config.connectTimeout)
            for (name, value) in config.headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.setValue("mqtt", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            let task = session.webSocketTask(with: request)
            self.session = session
            self.task = task
            openedAt = Date()
            startTimer()
            task.resume()
        }
    }

    func subscribe(_ topic: String, qos: UInt8 = 0) {
        queue.async { [self] in
            guard isConnected else { return }
            send(Packet.subscribe(id: nextPacketId(), topic: topic, qos: qos))
        }
    }

    func publish(_ topic: String, _ payload: Data, qos: UInt8 = 0) {
        queue.async { [self] in
            guard isConnected else { return }
            send(Packet.publish(topic: topic, payload: payload, qos: qos,
                                id: qos > 0 ? nextPacketId() : nil))
        }
    }

    func close() {
        queue.async { [self] in
            if isConnected { send(Packet.disconnect) }
            finish(nil)
        }
    }

    // MARK: - URLSessionWebSocketDelegate (called on `queue`)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        send(Packet.connect(clientId: config.clientId, keepAlive: config.keepAlive))
        receiveNext()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(.closedByServer)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(failure(error))
    }

    // MARK: - internals (on `queue`)

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                guard !self.finished else { return }
                switch result {
                case .failure(let error):
                    self.finish(self.failure(error))
                case .success(let message):
                    switch message {
                    case .data(let data): self.inbound.append(data)
                    case .string(let text): self.inbound.append(Data(text.utf8))
                    @unknown default: break
                    }
                    self.drain()
                    if !self.finished { self.receiveNext() }
                }
            }
        }
    }

    /// Handles every complete packet in the buffer; a packet may span frames.
    private func drain() {
        while !finished {
            let parsed: Packet.Parsed?
            do {
                parsed = try Packet.parse(inbound)
            } catch {
                finish(.protocolError("malformed packet"))
                return
            }
            guard let packet = parsed else { return }  // wait for more bytes
            inbound = Data(inbound.dropFirst(packet.size))
            lastInbound = Date()
            handle(packet)
        }
    }

    private func handle(_ packet: Packet.Parsed) {
        let body = [UInt8](packet.body)
        switch packet.header >> 4 {
        case 2:  // CONNACK
            guard body.count >= 2 else { finish(.protocolError("short CONNACK")); return }
            guard body[1] == 0 else { finish(.refused(returnCode: body[1])); return }
            isConnected = true
            lastPing = Date()
            onEvent?(.connected)
        case 3:  // PUBLISH
            let qos = (packet.header >> 1) & 0x03
            guard body.count >= 2 else { return }
            let topicLength = Int(body[0]) << 8 | Int(body[1])
            var index = 2 + topicLength
            guard body.count >= index + (qos > 0 ? 2 : 0) else { return }
            let topic = String(decoding: body[2..<index], as: UTF8.self)
            if qos > 0 {
                send(Packet.puback(UInt16(body[index]) << 8 | UInt16(body[index + 1])))
                index += 2
            }
            onEvent?(.message(topic: topic, payload: Data(body[index...])))
        default:
            break  // SUBACK, PUBACK, PINGRESP: only keep-alive bookkeeping
        }
    }

    private func send(_ packet: Data) {
        task?.send(.data(packet)) { [weak self] error in
            guard let self = self, let error = error else { return }
            self.queue.async { self.finish(.transport(error.localizedDescription)) }
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        guard isConnected else {
            if now.timeIntervalSince(openedAt) > config.connectTimeout { finish(.timeout) }
            return
        }
        let keepAlive = TimeInterval(config.keepAlive)
        if now.timeIntervalSince(lastInbound) > keepAlive * 1.5 {
            finish(.timeout)  // no PINGRESP: the link is dead (e.g. after sleep)
        } else if now.timeIntervalSince(lastPing) >= keepAlive / 2 {
            lastPing = now
            send(Packet.pingreq)
        }
    }

    private func failure(_ error: Error?) -> Failure? {
        if let http = task?.response as? HTTPURLResponse, http.statusCode >= 400 {
            return .rejected(httpStatus: http.statusCode)
        }
        return error.map { .transport($0.localizedDescription) } ?? .closedByServer
    }

    private func finish(_ failure: Failure?) {
        guard !finished else { return }
        finished = true
        isConnected = false
        timer?.cancel()
        timer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()  // releases the delegate (self)
        let handler = onEvent
        onEvent = nil
        handler?(.closed(failure))
    }

    private func nextPacketId() -> UInt16 {
        lastPacketId = lastPacketId == .max ? 1 : lastPacketId + 1
        return lastPacketId
    }
}

/// MQTT packet encoding/decoding. Strings carry a 2-byte big-endian length;
/// only the fixed header's "remaining length" is a variable-length integer.
enum Packet {
    // MQTT 3.1 ("MQIsdp", level 3) is what the Dyson endpoint was verified with.
    static let protocolName = "MQIsdp"
    static let protocolLevel: UInt8 = 3

    static let pingreq = Data([0xC0, 0x00])
    static let disconnect = Data([0xE0, 0x00])

    struct Parsed {
        let header: UInt8
        let body: Data
        let size: Int  // bytes consumed from the buffer
    }

    struct Malformed: Error {}

    static func connect(clientId: String, keepAlive: UInt16) -> Data {
        var body = string(protocolName)
        body.append(protocolLevel)
        body.append(0x02)  // clean session, no credentials (auth is in the WebSocket headers)
        body.append(uint16(keepAlive))
        body.append(string(clientId))
        return frame(0x10, body)
    }

    static func subscribe(id: UInt16, topic: String, qos: UInt8) -> Data {
        var body = uint16(id)
        body.append(string(topic))
        body.append(qos)
        return frame(0x82, body)
    }

    static func publish(topic: String, payload: Data, qos: UInt8, id: UInt16?) -> Data {
        var body = string(topic)
        if qos > 0, let id = id { body.append(uint16(id)) }
        body.append(payload)
        return frame(0x30 | (qos << 1), body)
    }

    static func puback(_ id: UInt16) -> Data { frame(0x40, uint16(id)) }

    /// The first complete packet in `data`, nil if more bytes are needed.
    static func parse(_ data: Data) throws -> Parsed? {
        let head = [UInt8](data.prefix(5))
        guard head.count >= 2 else { return nil }
        var length = 0, multiplier = 1, index = 1
        while true {
            guard index < head.count else {
                if index > 4 { throw Malformed() }
                return nil
            }
            let byte = head[index]
            length += Int(byte & 0x7F) * multiplier
            index += 1
            if byte & 0x80 == 0 { break }
            if index > 4 { throw Malformed() }
            multiplier *= 128
        }
        let size = index + length
        guard data.count >= size else { return nil }
        let start = data.startIndex
        return Parsed(header: head[0], body: data.subdata(in: (start + index)..<(start + size)), size: size)
    }

    static func remainingLength(_ value: Int) -> Data {
        var out = Data()
        var n = value
        repeat {
            var byte = UInt8(n % 128)
            n /= 128
            if n > 0 { byte |= 0x80 }
            out.append(byte)
        } while n > 0
        return out
    }

    static func string(_ text: String) -> Data {
        let utf8 = Data(text.utf8)
        return uint16(UInt16(utf8.count)) + utf8
    }

    private static func uint16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }

    private static func frame(_ header: UInt8, _ body: Data) -> Data {
        var out = Data([header])
        out.append(remainingLength(body.count))
        out.append(body)
        return out
    }
}
