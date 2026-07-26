import Foundation
import Security

/// Persists the push opt-in flow's own local state — relay URL, this
/// device's relay-issued id/secret, and which watch id belongs to which
/// local account. Split out of `AppEnvironment` mainly so `deviceSecret`'s
/// Keychain handling (it's a bearer credential, same sensitivity class as
/// an IMAP password) doesn't get lost among everything else there.
///
/// - Relay URL / device id / accountId→watchId map: `UserDefaults` — none
///   of these are secret (the relay URL is just a hostname the user typed,
///   watch ids are opaque and useless without the bearer secret).
/// - Device secret: Keychain (`KeychainCredentialStore`-adjacent, but
///   deliberately a separate service string — it's not an IMAP account
///   password, and conflating the two would make `KeychainCredentialStore`
///   harder to reason about for what it already does).
// `@unchecked Sendable`: `UserDefaults` is documented as thread-safe but
// isn't declared `Sendable` in this SDK snapshot.
struct PushSettingsStore: @unchecked Sendable {
    private static let relayURLKey = "push.relayURLString"
    private static let deviceIdKey = "push.deviceId"
    private static let enabledKey = "push.enabled"
    private static let watchMapKey = "push.accountWatchMap"
    private static let keychainService = "com.mtkg.otegami.push-device-secret"
    /// Same rename hazard as `KeychainCredentialStore.legacyServices`
    /// (`52df393` changed this hardcoded default too) — kept here for
    /// symmetry/consistency even though a stale device secret is much
    /// lower-stakes than a lost mail password (`enablePushNotifications`
    /// just re-registers a fresh one; this only saves that one round trip).
    private static let legacyKeychainServices = ["com.m-tkg.otegami.push-device-secret"]
    private static let keychainAccount = "device"

    private let defaults: UserDefaults
    private let accessGroup: String?

    init(defaults: UserDefaults = .standard, accessGroup: String? = nil) {
        self.defaults = defaults
        self.accessGroup = accessGroup
    }

    var relayURLString: String? {
        get { defaults.string(forKey: Self.relayURLKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.relayURLKey) }
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var deviceId: String? {
        get { defaults.string(forKey: Self.deviceIdKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.deviceIdKey) }
    }

    /// `accountId` -> relay `watchId`, for every account currently
    /// watched. Used both to know what to `DELETE` when disabling/deleting
    /// an account, and to skip creating a duplicate watch for an account
    /// that already has one.
    var accountWatchMap: [String: String] {
        get {
            guard let data = defaults.data(forKey: Self.watchMapKey),
                  let map = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return map
        }
        nonmutating set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.watchMapKey)
        }
    }

    func setWatchId(_ watchId: String?, forAccountId accountId: String) {
        var map = accountWatchMap
        if let watchId {
            map[accountId] = watchId
        } else {
            map.removeValue(forKey: accountId)
        }
        accountWatchMap = map
    }

    // MARK: - Device secret (Keychain)

    func deviceSecret() throws -> String? {
        if let data = try deviceSecretData(service: Self.keychainService) {
            return String(data: data, encoding: .utf8)
        }
        for legacyService in Self.legacyKeychainServices {
            guard let data = try deviceSecretData(service: legacyService) else { continue }
            try? setDeviceSecret(String(data: data, encoding: .utf8) ?? "")
            _ = SecItemDelete(baseQuery(service: legacyService) as CFDictionary)
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private func deviceSecretData(service: String) throws -> Data? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return result as? Data
    }

    // M11: deliberately *not* `kSecAttrSynchronizable` — this secret is
    // paired 1:1 with this device's own APNs device token (never itself
    // synced), so syncing just the secret to another device would leave it
    // holding a bearer credential with no matching token to actually use it.
    func setDeviceSecret(_ secret: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery()
        let existsStatus = SecItemCopyMatching(query as CFDictionary, nil)
        switch existsStatus {
        case errSecSuccess:
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
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

    func deleteDeviceSecret() throws {
        var lastError: KeychainError?
        for candidateService in [Self.keychainService] + Self.legacyKeychainServices {
            let status = SecItemDelete(baseQuery(service: candidateService) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                lastError = .unexpectedStatus(status)
                continue
            }
        }
        if let lastError { throw lastError }
    }

    /// Clears every bit of local push state — relay URL, device id/secret,
    /// enabled flag, and the accountId→watchId map. Called after
    /// successfully deleting every watch server-side
    /// (`AppEnvironment.disablePushNotifications()`), so nothing local
    /// still points at server state that no longer exists.
    func reset() {
        relayURLString = nil
        deviceId = nil
        isEnabled = false
        accountWatchMap = [:]
        try? deleteDeviceSecret()
    }

    private func baseQuery() -> [String: Any] {
        baseQuery(service: Self.keychainService)
    }

    private func baseQuery(service: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

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
}
