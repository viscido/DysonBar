import Foundation
import os

/// A connected device from the account manifest.
struct DysonDevice: Codable, Equatable, Identifiable {
    let serial: String
    let name: String
    let model: String?
    /// MQTT topic root (`mqttRootTopicLevel`, e.g. "527K"), not always the bare product type.
    let topicRoot: String

    var id: String { serial }
    var statusTopics: String { "\(topicRoot)/\(serial)/status/#" }
    var commandTopic: String { "\(topicRoot)/\(serial)/command" }
}

/// Short-lived AWS IoT custom-authorizer credentials for one device.
struct IoTCredentials: Equatable {
    let endpoint: String
    let clientId: String
    let tokenKey: String
    let tokenValue: String
    let tokenSignature: String
    let authorizerName: String

    var webSocketHeaders: [String: String] {
        [
            tokenKey: tokenValue,
            "X-Amz-CustomAuthorizer-Name": authorizerName,
            "X-Amz-CustomAuthorizer-Signature": tokenSignature,
        ]
    }
}

enum DysonAPIError: LocalizedError, Equatable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)  // seconds, when Dyson says
    case accountNotFound(String)
    case invalidCode
    case noDevices
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Your Dyson session has expired. Please sign in again."
        case .rateLimited:
            return "Dyson is temporarily refusing sign-in requests for this account (too many attempts)."
        case .accountNotFound(let status):
            return "No active Dyson account for this email and country (status: \(status))."
        case .invalidCode: return "The code or the password was not accepted."
        case .noDevices: return "No connected Dyson devices on this account."
        case .http(let code): return "Dyson cloud error (HTTP \(code))."
        case .badResponse: return "Unexpected response from the Dyson cloud."
        }
    }
}

/// Client for the (unofficial) Dyson app API. See docs/PROTOCOL.md.
final class DysonCloudAPI {
    static func productionBaseURL(country: String) -> URL {
        URL(string: country.uppercased() == "CN" ? "https://appapi.cp.dyson.cn"
                                                 : "https://appapi.cp.dyson.com")!
    }

    let baseURL: URL
    private let http: URLSession
    private static let log = Logger(subsystem: "io.github.dysonbar", category: "api")

    private struct Response {
        let status: Int
        let data: Data
        let retryAfter: TimeInterval?
    }

    init(baseURL: URL, http: URLSession = URLSession(configuration: .ephemeral)) {
        self.baseURL = baseURL
        self.http = http
    }

    // MARK: - sign-in (email + OTP)

    /// The API ignores clients that have not called this recently.
    func unlock() async {
        _ = try? await call("GET", "/v1/provisioningservice/application/Android/version")
    }

    func accountStatus(email: String, country: String) async throws -> String {
        let r = try await call("POST", "/v3/userregistration/email/userstatus",
                                          query: ["country": country], body: ["email": email])
        try check(r)
        return (try object(r.data)["accountStatus"] as? String) ?? "UNKNOWN"
    }

    /// Emails a one-time code; returns the challenge id to verify it against.
    func beginLogin(email: String, country: String, culture: String) async throws -> String {
        let r = try await call("POST", "/v3/userregistration/email/auth",
                                          query: ["country": country, "culture": culture],
                                          body: ["email": email])
        try check(r)
        guard let id = try object(r.data)["challengeId"] as? String else { throw DysonAPIError.badResponse }
        return id
    }

    func verify(email: String, password: String, challengeId: String, otp: String,
                country: String, culture: String) async throws -> (account: String, token: String) {
        let r = try await call(
            "POST", "/v3/userregistration/email/verify",
            query: ["country": country, "culture": culture],
            body: ["email": email, "password": password, "challengeId": challengeId, "otpCode": otp])
        if [400, 401, 403].contains(r.status) { throw DysonAPIError.invalidCode }
        try check(r)
        let obj = try object(r.data)
        guard let token = obj["token"] as? String, !token.isEmpty else { throw DysonAPIError.badResponse }
        return ((obj["account"] as? String) ?? "", token)
    }

    // MARK: - authenticated

    func devices(token: String) async throws -> [DysonDevice] {
        let r = try await call("GET", "/v3/manifest", token: token)
        try check(r, authenticated: true)
        return try Self.parseDevices(r.data)
    }

    func iotCredentials(token: String, serial: String) async throws -> IoTCredentials {
        let r = try await call("POST", "/v2/authorize/iot-credentials",
                                          body: ["Serial": serial], token: token)
        try check(r, authenticated: true)
        let obj = try object(r.data)
        guard let endpoint = obj["Endpoint"] as? String,
              let c = obj["IoTCredentials"] as? [String: Any],
              let clientId = c["ClientId"] as? String,
              let tokenValue = c["TokenValue"] as? String,
              let signature = c["TokenSignature"] as? String,
              let authorizer = c["CustomAuthorizerName"] as? String
        else { throw DysonAPIError.badResponse }
        return IoTCredentials(endpoint: endpoint, clientId: clientId,
                              tokenKey: (c["TokenKey"] as? String) ?? "token",
                              tokenValue: tokenValue, tokenSignature: signature,
                              authorizerName: authorizer)
    }

    /// Devices that talk MQTT through the cloud (vacuums, hair care etc. are skipped).
    static func parseDevices(_ data: Data) throws -> [DysonDevice] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DysonAPIError.badResponse
        }
        return list.compactMap { d in
            guard let serial = (d["serialNumber"] ?? d["Serial"]) as? String,
                  let config = d["connectedConfiguration"] as? [String: Any],
                  let mqtt = config["mqtt"] as? [String: Any],
                  let root = (mqtt["mqttRootTopicLevel"] as? String) ?? (d["type"] as? String)
            else { return nil }
            if let broker = mqtt["remoteBrokerType"] as? String, broker != "wss" { return nil }
            let name = (d["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (d["productName"] as? String) ?? serial
            return DysonDevice(serial: serial, name: name, model: d["model"] as? String, topicRoot: root)
        }
    }

    // MARK: - transport

    private func call(_ method: String, _ path: String, query: [String: String] = [:],
                      body: [String: Any]? = nil, token: String? = nil) async throws -> Response {
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!, timeoutInterval: 25)
        request.httpMethod = method
        // The API rejects other user agents and requires JSON bodies (415 otherwise).
        request.setValue("android client", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await http.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
        // Diagnostics without personal data: no bodies, emails or tokens.
        // Read with: /usr/bin/log show --last 1h --predicate 'subsystem == "io.github.dysonbar"'
        // (full path: in zsh, plain `log` is a shell builtin).
        Self.log.notice("\(method, privacy: .public) \(path, privacy: .public) -> \(status) retry-after: \(retryAfter.map { "\(Int($0))s" } ?? "-", privacy: .public) cf-ray: \(http?.value(forHTTPHeaderField: "cf-ray") ?? "-", privacy: .public)")
        return Response(status: status, data: data, retryAfter: retryAfter)
    }

    private func check(_ response: Response, authenticated: Bool = false) throws {
        switch response.status {
        case 200..<300: return
        case 401, 403: throw authenticated ? DysonAPIError.unauthorized : DysonAPIError.http(response.status)
        case 429: throw DysonAPIError.rateLimited(retryAfter: response.retryAfter)
        default: throw DysonAPIError.http(response.status)
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DysonAPIError.badResponse
        }
        return obj
    }
}
