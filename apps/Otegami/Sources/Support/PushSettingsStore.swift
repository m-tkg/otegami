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
    /// Task #121 (実機報告「別端末/再インストールでリレー URL が消える」):
    /// this one key is *not* device-specific the way the rest of this
    /// store's state is — it's just a hostname the user typed once, so
    /// losing it on reinstall (or never seeing it on a second device)
    /// forces re-typing the same URL for no benefit. `internal` (not
    /// `private`) so `AppSettingsCloudDirectory` can allowlist it directly
    /// rather than this store needing its own `SettingsCloudValue`-shaped
    /// accessor — see that type's `stringDefaults` and
    /// `docs/icloud-sync.md`'s settings-sync table for the rationale this
    /// key alone crossed over while `deviceId`/`accountWatchMap`/
    /// `deviceSecret` stayed device-local.
    static let relayURLKey = "push.relayURLString"
    private static let deviceIdKey = "push.deviceId"
    private static let enabledKey = "push.enabled"
    private static let watchMapKey = "push.accountWatchMap"
    /// M9 follow-up (実機バグ1): last time `AppEnvironment
    /// .reconcilePushWatchesIfNeeded()` actually ran a full `GET
    /// /v1/watches` reconcile pass — not secret, just a throttle timestamp.
    private static let lastWatchReconcileDateKey = "push.lastWatchReconcileDate"
    private static let keychainService = "com.mtkg.otegami.push-device-secret"
    /// Task #171: the relay operator's shared `RELAY_DEVICE_REGISTRATION_SECRET`
    /// (see `server/otegami-relay/.../DeviceRoutes.authorizeRegistration`),
    /// a *credential* the same way `deviceSecret` is (a bearer token this
    /// device sends to the relay) — hence Keychain, not `UserDefaults`.
    /// Deliberately a separate service string from `deviceSecret`'s: this
    /// is one shared secret an operator hands out to every device they
    /// approve, not something the relay issues per-device, so conflating
    /// the two storage slots would make `deleteDeviceSecret()`/`reset()`
    /// (which must invalidate a *device's* registration, not the
    /// operator's secret) harder to reason about.
    private static let registrationSecretKeychainService = "com.mtkg.otegami.push-registration-secret"
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

    /// See `lastWatchReconcileDateKey`'s doc comment — `nil` until the
    /// first reconcile pass has ever run (e.g. a fresh install, or an
    /// existing install that just upgraded to this feature), which
    /// `AppEnvironment.reconcilePushWatchesIfNeeded()` treats the same as
    /// "due now."
    var lastWatchReconcileDate: Date? {
        get { defaults.object(forKey: Self.lastWatchReconcileDateKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.lastWatchReconcileDateKey) }
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
        try setSecret(secret, service: Self.keychainService)
    }

    func deleteDeviceSecret() throws {
        try deleteSecret(services: [Self.keychainService] + Self.legacyKeychainServices)
    }

    // MARK: - Registration secret (Keychain)

    /// Task #171: the relay's `RELAY_DEVICE_REGISTRATION_SECRET`, mirrored
    /// into every `POST /v1/devices` call as `Authorization: Bearer
    /// <this>` when the operator requires it — see
    /// `AppEnvironment.enablePushNotifications(relayURLString:
    /// registrationSecret:)`. `nil` (never set, or cleared) means "don't
    /// send the header," which is the correct behavior against every relay
    /// that hasn't opted into this gate.
    ///
    /// Unlike `deviceSecret`/`deviceId`/`relayURLString`, this is
    /// deliberately *not* cleared by `reset()`: it's not tied to a
    /// specific device registration (which `reset()` invalidates by
    /// deleting every watch server-side) — it's the operator's shared
    /// secret, which stays correct across a disable/re-enable cycle on
    /// this same device. It's also — same as `deviceSecret` — never
    /// `kSecAttrSynchronizable`, so it doesn't ride iCloud Keychain: each
    /// device that talks to a gated relay has to have this typed in
    /// locally (`docs/icloud-sync.md`).
    func registrationSecret() throws -> String? {
        if let data = try deviceSecretData(service: Self.registrationSecretKeychainService) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    func setRegistrationSecret(_ secret: String) throws {
        try setSecret(secret, service: Self.registrationSecretKeychainService)
    }

    func deleteRegistrationSecret() throws {
        try deleteSecret(services: [Self.registrationSecretKeychainService])
    }

    private func setSecret(_ secret: String, service: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(service: service)
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

    private func deleteSecret(services: [String]) throws {
        var lastError: KeychainError?
        for candidateService in services {
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
    /// still points at server state that no longer exists. Deliberately
    /// leaves `registrationSecret` alone — see that property's doc
    /// comment.
    func reset() {
        relayURLString = nil
        deviceId = nil
        isEnabled = false
        accountWatchMap = [:]
        lastWatchReconcileDate = nil
        try? deleteDeviceSecret()
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
