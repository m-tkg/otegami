import Foundation
import Intents
import PushRelayClient

/// iOS Communication Notifications (Task: 送信者アバター付きプッシュ通知):
/// donating an `INSendMessageIntent` with a sender `INPerson` (avatar image
/// included) to the system, before `NotificationService.deliver()` hands
/// the notification to the OS, lets the OS draw the sender's avatar as a
/// large circular image with this app's own icon automatically composited
/// into its bottom-right corner — no UI code in this app draws either
/// image itself; `UNNotificationContent.updating(from:)`
/// (`NotificationService.deliver()`) is what actually applies it.
///
/// Split the same way this directory's other decision types are
/// (`NotificationService.envelopeContentDecision`/`.syncFirstDecision`):
/// pure decision logic (`NotificationService.senderDecision(...)`/
/// `.conversationIdentifier(accountId:senderAddress:)`, both `extension
/// NotificationService` below, exercised directly by
/// `CommunicationNotificationDecisionTests` — no `Intents`/donation/
/// `UNMutableNotificationContent` involved) versus the side-effecting
/// `CommunicationNotificationBuilder` (constructs the actual `INPerson`/
/// `INSendMessageIntent` and donates it — not unit-tested, since that needs
/// real `UNUserNotificationCenter`/Intents runtime state a `swift test`
/// process doesn't have).
///
/// **The "送信者のプロフィールアイコンを表示" list-display toggle
/// (`ListDisplaySettingsStore.showAvatarKey`) gates this feature.**
/// `NotificationEnrichment`'s own doc comment states the design principle
/// this follows: a notification the user configured to hide something must
/// look identical to one that simply failed to enrich, never a "we clearly
/// know but you told us not to say" half-measure. Silently drawing an
/// avatar in a push notification because the user turned sender avatars off
/// everywhere else in this app would be exactly that kind of inconsistency
/// — see `NotificationService.showsAvatarPreference()`'s own doc comment.
enum CommunicationNotificationDecision: Equatable {
    /// Decorate this notification as a Communication Notification, using
    /// `sender`.
    case decorate(CommunicationNotificationSender)
    /// Don't build an intent at all. `reason.rawValue` is also what
    /// `NotificationService` records as this run's
    /// `PushDiagnosticsRun.Outcome.skipped(reason:)` text (Task: 端末内診断
    /// — see `PushDiagnosticsRun.Stage`'s doc comment on
    /// `.communicationNotification`).
    case skip(reason: SkipReason)

    enum SkipReason: String, Equatable, Sendable {
        /// This device's `NotificationContentPreferences.showsSender` is
        /// off — the notification isn't allowed to say *who* it's from at
        /// all, so it certainly can't show their photo either.
        case showsSenderOff = "showsSender off"
        /// `MailListSettingsView`'s "送信者のプロフィールアイコンを表示"
        /// toggle (`ListDisplaySettingsStore.showAvatarKey`, mirrored into
        /// the App Group `UserDefaults` suite by the app — see
        /// `NotificationService.showsAvatarPreference()`) is off.
        case showAvatarOff = "showAvatar off"
        /// Neither the push payload's relay-prefetched envelope
        /// (`PushNotificationPayload.latestFromAddress`) nor this run's
        /// IMAP resolution (the sync-first path or the legacy fallback)
        /// named a sender address.
        case noSenderAddress = "no sender address"
        /// A sender address was resolved, but `SharedAvatarStore` has no
        /// (unexpired) cached avatar file for it — the app has never
        /// resolved/mirrored an avatar for this correspondent yet, or the
        /// entry aged out past its TTL. Per this feature's own explicit
        /// design decision, this is a hard stop, not a fallback to a
        /// drawn-initials placeholder — an undecorated notification, not a
        /// half-decorated one.
        case avatarCacheMiss = "avatar cache miss"
    }
}

/// Everything `CommunicationNotificationBuilder.donate(sender:)` needs to
/// build the `INPerson`/`INSendMessageIntent` pair, already resolved by
/// `NotificationService.senderDecision(...)` — a small `Sendable` value
/// type so it can cross from the pure decision side into the
/// side-effecting donation side without re-deriving anything.
struct CommunicationNotificationSender: Equatable, Sendable {
    let displayName: String
    let address: String
    /// See `NotificationService.conversationIdentifier(accountId:senderAddress:)`'s
    /// doc comment.
    let conversationIdentifier: String
    /// The file `INImage(url:)` is handed — see
    /// `CommunicationNotificationBuilder.donate(sender:)`'s doc comment for
    /// why this must be a file URL, never `INImage(imageData:)`.
    let avatarFileURL: URL
}

extension NotificationService {
    /// Whether/how to decorate a notification as a Communication
    /// Notification — pure aside from `avatarStore.imageURL(for:)` reading
    /// a directory the caller already fully controls/injects (the same
    /// shape `SharedAvatarStore`'s own tests use, not a network/IMAP/GRDB
    /// call), so directly exercisable by `CommunicationNotificationDecisionTests`
    /// with a temporary directory. Test-reachable per this file's existing
    /// "private → internal for tests" convention (`parsePayload(_:)`'s doc
    /// comment) — this one goes one step further to `internal` (the
    /// default) since `CommunicationNotificationDecisionTests` calls it via
    /// `NotificationService.senderDecision(...)`, matching
    /// `envelopeContentDecision`/`syncFirstDecision`'s own visibility.
    ///
    /// - Parameters:
    ///   - payloadSenderAddress/payloadSenderName: `PushNotificationPayload
    ///     .latestFromAddress`/`.latestFromName` (Phase 3's relay-prefetched
    ///     envelope) — available with zero network calls, so preferred
    ///     whenever present, even over a *more* complete sync/legacy
    ///     result: the point of Phase 3 was exactly this "trust the cheap
    ///     source first" tradeoff, and this feature follows the same one.
    ///   - syncSenderAddress/syncSenderName: the sender this run's IMAP
    ///     resolution found — sync-first's `PushTriggeredInboxSync.Outcome
    ///     .message.fromAddresses.first`, or the legacy fallback's
    ///     `FetchedEnvelope.from.first` — used only when the payload named
    ///     no address at all.
    static func senderDecision(
        accountId: String,
        payloadSenderAddress: String?,
        payloadSenderName: String?,
        syncSenderAddress: String?,
        syncSenderName: String?,
        preferences: NotificationContentPreferences,
        showsAvatar: Bool,
        avatarStore: SharedAvatarStore?
    ) -> CommunicationNotificationDecision {
        guard preferences.showsSender else { return .skip(reason: .showsSenderOff) }
        guard showsAvatar else { return .skip(reason: .showAvatarOff) }

        let address: String
        let name: String?
        if let payloadSenderAddress, !payloadSenderAddress.isEmpty {
            address = payloadSenderAddress
            name = payloadSenderName
        } else if let syncSenderAddress, !syncSenderAddress.isEmpty {
            address = syncSenderAddress
            name = syncSenderName
        } else {
            return .skip(reason: .noSenderAddress)
        }

        guard let avatarStore, let avatarFileURL = avatarStore.imageURL(for: address) else {
            return .skip(reason: .avatarCacheMiss)
        }

        // `preferences.showsSender` is already confirmed on above, and
        // `address` is non-empty, so this can only ever return a real
        // name/address — never `NotificationEnrichment.genericTitle` —
        // reusing the exact same "prefer a non-empty display name, else
        // the address" rule the rest of this file's notification titles
        // already use (this function's own doc comment on why re-using it
        // matters).
        let displayName = NotificationEnrichment.title(preferences: preferences, senderName: name, senderAddress: address)
        return .decorate(CommunicationNotificationSender(
            displayName: displayName,
            address: address,
            conversationIdentifier: conversationIdentifier(accountId: accountId, senderAddress: address),
            avatarFileURL: avatarFileURL
        ))
    }

    /// The Communication Notification's "conversation" identifier —
    /// deliberately **one per (account, sender address) pair, never per
    /// mail thread**. At the point this whole file runs (envelope time —
    /// before, or instead of, the full body/thread fetch a user opening the
    /// app would trigger), the pushed message's `threadId` isn't known yet;
    /// Apple's own `INSendMessageIntent.conversationIdentifier` guidance is
    /// that this value must stay *stable* for a given conversation for the
    /// OS's grouping/notification-history to make sense, and reusing a
    /// placeholder now that gets replaced by the real thread id later would
    /// violate exactly that (every notification donated under the
    /// placeholder would become orphaned from the ones donated afterward
    /// under the real id). Grouping by sender instead is also simply what a
    /// user expects from "this is a notification from Alice", independent
    /// of which of Alice's mail threads it happens to belong to.
    ///
    /// `SharedAvatarStore.normalize(_:)` (trim + lowercase — the exact same
    /// normalization the shared avatar cache's own key derivation uses)
    /// keeps this identifier stable across the same real address arriving
    /// with different casing/whitespace between the push payload and a
    /// later IMAP-resolved envelope.
    static func conversationIdentifier(accountId: String, senderAddress: String) -> String {
        "\(accountId)/\(SharedAvatarStore.normalize(senderAddress))"
    }
}

/// The side-effecting half: turns a resolved `CommunicationNotificationSender`
/// into a donated `INSendMessageIntent`, or a thrown error if the donation
/// itself failed. Not unit-tested — see this file's top doc comment for
/// why (real `Intents`/`UNUserNotificationCenter` runtime state, not
/// available to `swift test`) — kept as thin as possible so
/// `NotificationService.senderDecision(...)` carries the actual logic
/// burden instead.
enum CommunicationNotificationBuilder {
    enum DonationOutcome {
        case success(INSendMessageIntent)
        case failure(Error)
    }

    /// Builds the `INPerson`/`INSendMessageIntent` pair for `sender`,
    /// donates an incoming `INInteraction` for it, and returns the intent
    /// only once that donation has actually succeeded — Apple's own
    /// documented ordering is donate first, `content.updating(from:)`
    /// second (`NotificationService.deliver()`'s
    /// `applyCommunicationNotificationIfAvailable()`), so a caller must
    /// never hand an un-donated intent to that call.
    ///
    /// **`INImage(url:)`, never `INImage(imageData:)`.** The latter is
    /// widely reported to work in Debug but silently fail to show an avatar
    /// in Release/TestFlight builds — the `intents-remote-image-proxy` URL
    /// it derives internally fails to materialise (Apple Developer Forums
    /// thread 692707). `SharedAvatarStore.imageURL(for:)` hands back a real
    /// file URL inside the shared App Group container specifically so this
    /// can always use the documented-safe path. **Do not "simplify" this
    /// back to `imageData:` even though it looks equivalent and easier to
    /// construct in a test — doing so silently breaks the exact build type
    /// (Release/TestFlight) this feature ships to, in a way no Debug run or
    /// simulator check will ever catch.**
    ///
    /// `isContactSuggestion: false`/`suggestionType: .none` are Apple's own
    /// documented choice for an `INPerson` derived from just an email
    /// address rather than a real Contacts entry — they suppress this
    /// person from being offered as a Siri/share-sheet/Focus contact
    /// suggestion, which would be a much bigger, unrelated behavior change
    /// than "draw an avatar on a notification" and isn't something this
    /// feature should cause as a side effect. `contactIdentifier` is left
    /// `nil` for the same reason (linking to a real contact would only
    /// strengthen those same suggestions) — and it also means this
    /// Extension never needs the Contacts entitlement/permission prompt
    /// just to decorate a notification.
    ///
    /// The recipient (this device's own account) is intentionally never
    /// added as a participant — Apple's guidance for an incoming
    /// `INSendMessageIntent` is that only the *other* party belongs in
    /// `sender`/`recipients`. `content` (the message body) is left `nil`
    /// for the same "this is an incoming notification, not an outgoing
    /// draft" reason — handing the mail's body text to the intent framework
    /// here would expose it to Siri for no benefit.
    static func donate(sender: CommunicationNotificationSender) async -> DonationOutcome {
        let handle = INPersonHandle(value: sender.address, type: .emailAddress)
        let person = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: sender.displayName,
            image: INImage(url: sender.avatarFileURL),
            contactIdentifier: nil,
            customIdentifier: nil,
            isContactSuggestion: false,
            suggestionType: .none
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: nil,
            conversationIdentifier: sender.conversationIdentifier,
            serviceName: nil,
            sender: person,
            attachments: nil
        )
        // Mirrors `INPerson`'s own `image:` above via the intent's
        // parameter-level image API — seen in multiple real-world
        // Communication Notification implementations alongside the
        // `INPerson.image` initializer argument; costs nothing to also set
        // here even if the `INPerson`-level image alone already suffices.
        intent.setImage(INImage(url: sender.avatarFileURL), forParameterNamed: \.sender)

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do {
            try await interaction.donate()
            return .success(intent)
        } catch {
            return .failure(error)
        }
    }
}
