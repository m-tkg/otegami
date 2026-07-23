import Foundation
import Security

/// Stores/retrieves account passwords in the Keychain, keyed by
/// `AccountRecord.id`. The `account` table itself only ever stores
/// `authType` (see `OtegamiStore.AccountRecord`'s doc comment) — this is
/// the one place the actual secret lives.
///
/// `kSecAttrAccessibleAfterFirstUnlock` (rather than
/// `.whenUnlocked`) so a background sync — BGAppRefresh, or a future push
/// relay wake (M9) — can read the password while the device is locked but
/// has been unlocked at least once since boot, which is the usual state for
/// a background task.
struct KeychainCredentialStore: Sendable {
    enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)

        var description: String {
            switch self {
            case .unexpectedStatus(let status):
                if let message = SecCopyErrorMessageString(status, nil) as String? {
                    "Keychain error \(status): \(message)"
                } else {
                    "Keychain error \(status)"
                }
            }
        }
    }

    private let service: String

    init(service: String = "com.m-tkg.otegami.account-password") {
        self.service = service
    }

    func setPassword(_ password: String, forAccountId accountId: String) throws {
        let data = Data(password.utf8)
        let query = baseQuery(accountId: accountId)

        let existsStatus = SecItemCopyMatching(query as CFDictionary, nil)
        switch existsStatus {
        case errSecSuccess:
            let update = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        default:
            throw KeychainError.unexpectedStatus(existsStatus)
        }
    }

    func password(forAccountId accountId: String) throws -> String? {
        var query = baseQuery(accountId: accountId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deletePassword(forAccountId accountId: String) throws {
        let status = SecItemDelete(baseQuery(accountId: accountId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(accountId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
        ]
    }
}
