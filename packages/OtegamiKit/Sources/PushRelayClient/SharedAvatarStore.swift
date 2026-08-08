import CryptoKit
import Foundation

/// The App Group-backed handoff for sender avatar images between the app and
/// its Notification Service Extension (Communication Notifications, iOS
/// only — `docs/push-notification-actions.md`).
///
/// **Why a second cache at all.** The app already resolves sender avatars
/// through four sources (`apps/Otegami/Sources/Support/Avatar/`: contacts
/// photo → Google profile photo → Gravatar → BIMI/company logo), but every
/// one of those keeps its own cache under `FileManager.urls(for:
/// .cachesDirectory)` — the *containing app's* container, which an app
/// extension cannot read. Rather than re-run any of that resolution inside
/// the Extension (no Contacts permission prompt is possible there, and
/// hitting gravatar.com/People API on every push would both leak traffic the
/// user never asked for and eat the Extension's ~5 second display budget),
/// the app mirrors whatever it already resolved into this shared directory
/// and the Extension only ever *reads*. Same "the app writes, the Extension
/// reads" shape as `NotificationContentSettingsStore.mirrorToAppGroup()`.
///
/// **Why files rather than `UserDefaults`.** `INImage(imageData:)` is widely
/// reported to work in Debug but fail in Release/TestFlight builds — the
/// `intents-remote-image-proxy` URL it derives fails to materialise and the
/// avatar silently never appears (Apple Developer Forums thread 692707). The
/// documented workaround is to hand `INImage` a real file URL inside an App
/// Group container, which is exactly what `imageURL(for:)` returns.
///
/// **File protection.** Entries are written with
/// `.completeFileProtectionUntilFirstUserAuthentication` on purpose: with
/// the default protection class the Extension cannot read them while the
/// device is locked, which would mean "the avatar shows up everywhere except
/// the lock screen" — the one place a push notification is most often seen.
/// Same reasoning as `KeychainCredentialStore`'s
/// `kSecAttrAccessibleAfterFirstUnlock`.
///
/// A missing entry is not an error: the Extension simply skips the
/// Communication Notification decoration and delivers the ordinary
/// app-icon notification it always did, so no negative ("this address has no
/// avatar") marker is stored here.
public struct SharedAvatarStore: Sendable {
    /// Path relative to the App Group container root. Sits alongside the
    /// app's own per-source `AvatarCache/<Source>/` directories in spirit,
    /// but in a different container.
    public static let subdirectory = "AvatarCache/Shared"

    /// 30 days. Long enough that a regular correspondent's avatar survives
    /// between pushes without the app having to re-render the list, short
    /// enough that a changed profile photo eventually stops being served
    /// from here (the app's own source caches have their own, shorter TTLs
    /// and overwrite this entry as soon as they resolve again).
    public static let defaultTimeToLive: TimeInterval = 60 * 60 * 24 * 30

    /// Bounded so the shared container can't grow without limit from a
    /// mailbox with thousands of distinct senders. At ~15-30KB per 128×128
    /// PNG this caps the directory around 15MB.
    public static let defaultEntryLimit = 500

    private static let fileExtension = "png"

    public let directory: URL

    /// - Parameter directory: the `AvatarCache/Shared` directory itself, not
    ///   the container root. Injectable so `swift test` can point at a
    ///   temporary directory instead of a real App Group container (which a
    ///   SwiftPM test bundle has no entitlement for).
    public init(directory: URL) {
        self.directory = directory
    }

    /// `nil` when no App Group is configured or its container isn't
    /// reachable — macOS always (`OtegamiAppGroup.identifier` returns `nil`
    /// there), and any iOS build whose entitlements don't actually grant the
    /// group. Callers treat that as "this feature is off", never as an error.
    public init?(appGroupIdentifier: String?) {
        guard let appGroupIdentifier,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        else { return nil }
        self.init(directory: container.appending(path: Self.subdirectory, directoryHint: .isDirectory))
    }

    /// Trim + lowercase, byte-for-byte the same normalization
    /// `GravatarAvatarResolver.normalize(_:)` applies before hashing — the
    /// writer (app) and the reader (Extension) derive this key from
    /// independently-compiled copies of the address string, so any drift
    /// here silently turns every lookup into a miss.
    public static func normalize(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// SHA-256 hex digest, used purely as a filesystem-safe file name (an
    /// email address is not one). `AvatarCacheKey.sha256Hex` in the app
    /// target forwards to this so there is a single implementation.
    ///
    /// - Parameter string: already normalized by the caller — this function
    ///   deliberately doesn't normalize, matching `AvatarCacheKey`'s existing
    ///   contract.
    public static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The path an entry for `address` would occupy, whether or not it
    /// exists.
    public func fileURL(for address: String) -> URL {
        let name = Self.sha256Hex(Self.normalize(address))
        return directory.appending(path: "\(name).\(Self.fileExtension)", directoryHint: .notDirectory)
    }

    /// Overwrites any existing entry for this address. Best-effort by
    /// design: the caller (`MirroringAvatarImageResolver`) is decorating a
    /// successful avatar resolution and must not fail the resolution itself
    /// just because the mirror couldn't be written.
    @discardableResult
    public func write(_ pngData: Data, for address: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pngData.write(to: fileURL(for: address), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    /// The file URL to hand `INImage(url:)`, or `nil` when there is no entry
    /// for this address or the one on disk is older than `timeToLive`.
    ///
    /// - Parameter now: injectable so TTL expiry is testable without sleeping.
    public func imageURL(
        for address: String,
        now: Date = Date(),
        timeToLive: TimeInterval = defaultTimeToLive
    ) -> URL? {
        let url = fileURL(for: address)
        guard let modified = Self.modificationDate(of: url) else { return nil }
        guard now.timeIntervalSince(modified) <= timeToLive else { return nil }
        return url
    }

    /// Drops expired entries, then oldest-first until at most `entryLimit`
    /// remain. Best-effort and silent: called from the app's launch path,
    /// never from the Extension (which has neither the time budget nor a
    /// reason to mutate what it only reads).
    public func prune(
        now: Date = Date(),
        timeToLive: TimeInterval = defaultTimeToLive,
        entryLimit: Int = defaultEntryLimit
    ) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return }
        var surviving: [(url: URL, modified: Date)] = []
        for name in names where name.hasSuffix(".\(Self.fileExtension)") {
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            guard let modified = Self.modificationDate(of: url) else { continue }
            if now.timeIntervalSince(modified) > timeToLive {
                try? fileManager.removeItem(at: url)
            } else {
                surviving.append((url, modified))
            }
        }
        guard surviving.count > entryLimit else { return }
        // Newest first, then drop everything past the limit.
        surviving.sort { $0.modified > $1.modified }
        for entry in surviving[entryLimit...] {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
