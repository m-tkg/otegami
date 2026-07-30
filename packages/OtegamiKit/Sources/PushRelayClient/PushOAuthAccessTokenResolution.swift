import Foundation

/// Task #177 (`.oauth2`-kind account push enrichment): races an OAuth
/// access-token fetch (`tokenFetch` — in production, `GoogleOAuth.TokenStore
/// .accessToken(for:)`/`MicrosoftOAuth.TokenStore.accessToken(for:)`,
/// wired up by `NotificationService.oauthAccessToken(for:)`) against a fixed
/// `timeout`, collapsing every failure mode into a single `nil`:
///
/// - No refresh token stored for this account (never signed in via this
///   provider, or a previous `invalid_grant` already wiped it).
/// - The refresh itself failing (`invalid_grant`, network error, ...).
/// - Simply running out of time — `NotificationService`'s Extension process
///   has an OS-imposed ~30 second budget for the *entire*
///   `didReceive(_:withContentHandler:)` call (account lookup + Keychain +
///   this token exchange + the IMAP connect/select/fetch that follows it),
///   so a slow/hanging token endpoint must not be allowed to consume all of
///   it and leave zero time for the IMAP half.
///
/// `NotificationService.enrich(payload:)` treats a `nil` result here exactly
/// like a `.password` account's existing "no Keychain entry"/"IMAP connect
/// failed" cases: leave the generic fallback notification content in place,
/// never surface the failure anywhere a user could see it (F15: no token
/// value is ever logged either — this type never logs at all).
///
/// Deliberately closure-injected rather than depending on `GoogleOAuth`/
/// `MicrosoftOAuth` directly (this target has no dependency on either, and
/// isn't Apple-only *because* of this file) — lets `PushRelayClientTests`
/// exercise the timeout race deterministically with a fake `tokenFetch`
/// closure, no real Keychain, network, or actual OAuth client involved.
public enum PushOAuthAccessTokenResolution {
    public static func resolve(
        timeout: TimeInterval,
        tokenFetch: @escaping @Sendable () async throws -> String
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await tokenFetch()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                return nil
            }
            // Whichever of the two tasks above finishes first decides the
            // result — the loser (usually `tokenFetch`, still in flight
            // past the deadline; occasionally the sleep, if `tokenFetch`
            // already failed/returned before it) is cancelled via
            // `cancelAll()` rather than left to run to completion
            // unobserved. `tokenFetch` implementations are expected to
            // check for cancellation the same way any well-behaved async
            // network call does (`URLSession`'s async APIs already do)
            // so this doesn't leak a request past this function's return.
            defer { group.cancelAll() }
            guard let firstResult = await group.next() else { return nil }
            return firstResult
        }
    }
}
