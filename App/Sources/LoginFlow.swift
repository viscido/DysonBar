import Foundation

/// First-launch / expired-session sign-in: email → one-time code + password →
/// (if the account has several) device choice. The password only travels in
/// the verify request and is cleared right after.
///
/// Dyson rate-limits code emails per account, so a code is requested only when
/// needed: going back to fix a field reuses the code already sent, and a new
/// one is requested only on explicit request or once the old one is stale.
@MainActor
final class LoginFlow: ObservableObject {
    enum Step { case email, code, device }

    @Published var email: String
    @Published var country: String
    @Published var password = ""
    @Published var code = ""
    @Published private(set) var step: Step = .email
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var devices: [DysonDevice] = []
    /// No new code requests before this time (after Dyson answered 429).
    @Published private(set) var blockedUntil: Date?
    @Published private(set) var codeSentAt: Date?

    /// Called once sign-in is complete and a device is selected.
    var onFinished: (() -> Void)?

    /// How long a requested code is reused instead of asking for another.
    static let codeReuseWindow: TimeInterval = 10 * 60
    /// Pause after a 429 when Dyson does not say how long to wait.
    static let defaultBackoff: TimeInterval = 15 * 60

    private let model: DysonModel
    private var challenge: (id: String, email: String, country: String, at: Date)?
    private var limitedOnVerify = false

    init(model: DysonModel) {
        self.model = model
        email = model.lastEmail
        country = model.lastCountry ?? Locale.current.region?.identifier ?? "US"
    }

    var normalizedEmail: String { email.trimmingCharacters(in: .whitespaces) }

    var normalizedCountry: String {
        country.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// e.g. "it-IT": the language of the code email.
    var culture: String {
        "\(Locale.current.language.languageCode?.identifier ?? "en")-\(normalizedCountry)"
    }

    var isBlocked: Bool { blockedUntil.map { $0 > Date() } ?? false }

    var canRequestCode: Bool {
        !busy && normalizedEmail.contains("@") && normalizedCountry.count == 2
    }

    /// Codes are often copied with spaces ("123 456"); Dyson wants them without.
    var normalizedCode: String { code.filter { !$0.isWhitespace } }

    var canVerify: Bool {
        !busy && !isBlocked && !normalizedCode.isEmpty && !password.isEmpty
    }

    /// `forceNew`: the user explicitly asked for another email.
    func requestCode(forceNew: Bool = false) {
        let email = normalizedEmail
        let country = normalizedCountry
        if !forceNew, let c = challenge, c.email == email, c.country == country,
           Date().timeIntervalSince(c.at) < Self.codeReuseWindow {
            error = nil
            step = .code  // the code already emailed is still good
            return
        }
        if isBlocked {
            error = blockedMessage()
            return
        }
        let culture = self.culture
        run {
            let api = self.model.api(country: country)
            await api.unlock()
            let status = try await api.accountStatus(email: email, country: country)
            guard status == "ACTIVE" else { throw DysonAPIError.accountNotFound(status) }
            let id = try await api.beginLogin(email: email, country: country, culture: culture)
            let now = Date()
            self.challenge = (id, email, country, now)
            self.codeSentAt = now
            self.code = ""
            self.step = .code
        }
    }

    func verify() {
        guard let challenge = challenge else { step = .email; return }
        if isBlocked {  // every attempt counts against Dyson's limit
            error = blockedMessage()
            return
        }
        let culture = self.culture
        let otp = normalizedCode
        let password = self.password
        self.password = ""
        run(verifying: true) {
            let api = self.model.api(country: challenge.country)
            let result = try await api.verify(email: challenge.email, password: password,
                                              challengeId: challenge.id, otp: otp,
                                              country: challenge.country, culture: culture)
            let session = DysonSession(email: challenge.email, country: challenge.country,
                                       account: result.account, token: result.token)
            let list = try await self.model.signIn(session)
            self.challenge = nil  // used up
            self.code = ""
            if list.count == 1 {
                self.choose(list[0])
            } else {
                self.devices = list
                self.step = .device
            }
        }
    }

    func choose(_ device: DysonDevice) {
        model.selectDevice(device.serial)
        onFinished?()
    }

    /// Back to the email step; the code already sent stays usable.
    func back() {
        step = .email
        password = ""
        error = nil
    }

    private func blockedMessage() -> String {
        var text = DysonAPIError.rateLimited(retryAfter: nil).errorDescription ?? ""
        if let until = blockedUntil {
            text += " Try again after \(until.formatted(date: .omitted, time: .shortened))."
        }
        if limitedOnVerify {
            text += " If the code is no longer accepted then, use \"Send a new code\"."
        } else if challenge != nil {
            text += " A code you already received can still be used."
        }
        return text
    }

    private func run(verifying: Bool = false, _ operation: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await operation()
            } catch DysonAPIError.rateLimited(let retryAfter) {
                self.limitedOnVerify = verifying
                let until = Date().addingTimeInterval(retryAfter ?? Self.defaultBackoff)
                self.blockedUntil = until
                self.error = self.blockedMessage()
                Task { [weak self] in  // re-enable the button when the pause ends
                    try? await Task.sleep(nanoseconds: UInt64(max(0, until.timeIntervalSinceNow) * 1e9))
                    if self?.blockedUntil == until { self?.blockedUntil = nil; self?.error = nil }
                }
            } catch {
                self.error = error.localizedDescription
            }
            self.busy = false
        }
    }
}
