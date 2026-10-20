import Foundation
import Security

/// The signed-in Dyson account. Only the bearer token from the OTP login is
/// kept — the account password is used once to sign in and never stored.
struct DysonSession: Codable, Equatable {
    var email: String
    var country: String
    var account: String
    var token: String
}

protocol SessionStore: AnyObject {
    func load() -> DysonSession?
    @discardableResult func save(_ session: DysonSession) -> Bool
    func delete()
}

/// Session persisted as one generic-password item in the user's login keychain.
final class KeychainSessionStore: SessionStore {
    private let service: String
    private let account = "dyson-session"

    init(service: String = "DysonBar") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> DysonSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(DysonSession.self, from: data)
    }

    @discardableResult
    func save(_ session: DysonSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "DysonBar — Dyson account session"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// In-memory store, for tests.
final class MemorySessionStore: SessionStore {
    var session: DysonSession?

    init(_ session: DysonSession? = nil) {
        self.session = session
    }

    func load() -> DysonSession? { session }

    @discardableResult
    func save(_ session: DysonSession) -> Bool {
        self.session = session
        return true
    }

    func delete() { session = nil }
}
