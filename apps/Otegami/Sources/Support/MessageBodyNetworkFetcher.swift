import Foundation
import MailTransport
import OtegamiStore

/// Shared core of `MessageView.fetchBodyOverNetwork(message:)` and
/// `ThreadDetailView.fetchBodyOverNetworkForThreadSummary(message:account:)`
/// — both resolve `auth(for:)`, resolve a mailbox path, then call
/// `environment.syncCoordinator.fetchBody(for:mailboxPath:account:auth:)`,
/// in that exact order (auth first, so a mailbox-path lookup that needs its
/// own DB read — `ThreadDetailView`'s case — is skipped entirely when auth
/// already failed). They disagree on error handling: `MessageView`'s caller
/// needs the failure to propagate (a real fetch the user is waiting on, with
/// its own error UI, and it also rewrites an auth failure's underlying error
/// into a `MailTransportError.authenticationFailed` for a friendlier
/// message), while `ThreadDetailView`'s caller is a best-effort per-message
/// step inside a larger "summarize the whole thread" loop that must keep
/// going even if one message's body can't be fetched.
///
/// This extracts exactly the part that's identical between the two —
/// auth resolution, then mailbox-path resolution, then the `fetchBody`
/// call — and leaves each caller's own strict/best-effort wrapper in place.
/// `resolveMailboxPath` is a closure (not a plain `String`/`String?`
/// argument) specifically so it only runs *after* auth succeeds, matching
/// both original implementations: `MessageView` reads its already-resolved
/// `mailboxPath` property (cheap either way), but `ThreadDetailView` does an
/// async DB read for it (`ThreadDetailView.mailboxPath(mailboxId:db:)`) that
/// must stay skipped when auth fails, exactly as it was skipped before this
/// extraction.
///
/// See `MessageView+BodyLoader.swift`'s `fetchBodyOverNetwork(message:)` and
/// `ThreadDetailView+ThreadSummary.swift`'s
/// `fetchBodyOverNetworkForThreadSummary(message:account:)` for the two
/// wrappers.
@MainActor
enum MessageBodyNetworkFetcher {
    /// Thrown only when `environment.auth(for: account)` itself fails —
    /// wraps the original error so a caller that needs to react
    /// specifically to an auth failure (as opposed to a `fetchBody` failure)
    /// can `catch` this case by type instead of guessing from the
    /// underlying error's shape. `MessageView`'s wrapper catches this to
    /// rebuild the same `MailTransportError.authenticationFailed
    /// (underlyingDescription:)` it always has; `ThreadDetailView`'s wrapper
    /// doesn't need to distinguish at all (`try?` swallows every failure
    /// alike), so it never touches this type.
    struct AuthResolutionFailure: Error {
        let underlying: Error
    }

    /// Resolves auth, then `resolveMailboxPath()`, then calls
    /// `environment.syncCoordinator.fetchBody`. An auth failure is thrown as
    /// `AuthResolutionFailure`; a missing mailbox path throws
    /// `MailTransportError.mailboxNotFound(path: "")` (unwrapped — both
    /// original call sites already treated "no mailbox path" as just
    /// another plain failure, no special rewriting); a `fetchBody` failure
    /// propagates completely unwrapped, exactly as before.
    static func fetch(
        message: MessageRecord,
        account: AccountRecord,
        environment: AppEnvironment,
        resolveMailboxPath: () async -> String?
    ) async throws {
        let auth: MailAuth
        do {
            auth = try await environment.auth(for: account)
        } catch {
            throw AuthResolutionFailure(underlying: error)
        }
        guard let mailboxPath = await resolveMailboxPath() else {
            throw MailTransportError.mailboxNotFound(path: "")
        }
        try await environment.syncCoordinator.fetchBody(
            for: message,
            mailboxPath: mailboxPath,
            account: account,
            auth: auth
        )
    }
}
