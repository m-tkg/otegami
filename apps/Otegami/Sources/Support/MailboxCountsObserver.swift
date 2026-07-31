import Foundation
import GRDB
import OtegamiStore
import SyncEngine

/// The mailbox tree + badge counts `SidebarView` (macOS's permanent left
/// column) and `FolderListSheet` (iOS's hamburger-menu drawer) each show —
/// unified inbox unread, per-mailbox unread, outbox/draft/sync-error/
/// mailbox-sync-error counts, and the mailbox tree itself — driven by the
/// same GRDB `ValueObservation`s in both screens. The two screens stay
/// separate `View` types (see `FolderListSheet`'s doc comment for why: they
/// no longer share a rendering context, one is an always-visible
/// `NavigationSplitView` column, the other a sliding drawer), but the
/// observation logic itself doesn't need to be duplicated — this type holds
/// it once as `@Observable` state, and each screen owns its own instance
/// (`@State private var countsObserver = MailboxCountsObserver()`).
///
/// Callers keep their own scheduling exactly as before this was extracted:
/// `SidebarView` starts one `observeMailboxes`/`observeUnreadCounts` pair
/// per visible account via a `.task(id: account.id)` on that account's own
/// `Section`, while `FolderListSheet` starts every account's pair together
/// via `withTaskGroup` under one `.task(id: environment.accounts.map(\.id))`
/// (`observeAllMailboxes()`/`observeAllUnreadCounts()`). This type only
/// supplies the per-account/per-database async functions that write into
/// its own state; it doesn't opine on how callers schedule or cancel them.
@MainActor
@Observable
final class MailboxCountsObserver {
    private(set) var mailboxesByAccountId: [String: [MailboxRecord]] = [:]
    private(set) var outboxCount = 0
    private(set) var draftCount = 0
    private(set) var failedOpCount = 0
    private(set) var mailboxSyncFailureCount = 0
    // M10: unread badges. `unreadByMailboxId` groups by mailbox id (spans
    // every account — a plain `[Int64: Int]` is enough since `MailboxRecord
    // .id` is a global autoincrement primary key, not scoped per account).
    // `unifiedInboxUnread` is its own separately-observed total rather than
    // derived by summing `unreadByMailboxId` client-side, since it's scoped
    // to inbox-role mailboxes only (`MessageQuery.unifiedInboxUnreadCount`'s
    // doc comment) — deriving it here would need this type to also know
    // each mailbox's role, duplicating logic the query already encodes.
    private(set) var unreadByMailboxId: [Int64: Int] = [:]
    private(set) var unifiedInboxUnread = 0

    /// Runs for as long as the caller's `.task` keeps it alive (cancelled
    /// automatically when the scope ends, same as before this was
    /// extracted — neither original call site did explicit cancellation
    /// either).
    ///
    /// Also claims "すべての受信トレイ" as the *data* selection the first
    /// time any account's mailboxes appear (M4) in `SidebarView` only — so
    /// the content column is ready to show a populated, threaded list the
    /// instant the user does navigate into it. `FolderListSheet` has no
    /// equivalent side effect. `onMailboxesLoaded`, called once per
    /// emission (every time, not just the first — mirroring the inline
    /// `if selection == nil { selection = .unifiedInbox }` guard
    /// `SidebarView` used to run directly in this loop), is how
    /// `SidebarView` opts into that behavior; `FolderListSheet` passes
    /// `nil` (the default) and gets none of it.
    ///
    /// `SidebarView`'s original doc comment on this method, preserved here
    /// since the rationale is unchanged:
    ///
    /// Deliberately does **not** also navigate there (i.e. does not push
    /// `preferredCompactColumn` forward) — that used to happen implicitly
    /// via `RootView`'s `onChange(of: selection)`, and on a compact-width
    /// device (iPhone) that meant a *cold launch* jumped straight past the
    /// sidebar into the message list with no tap at all (docs/verify.md,
    /// "コールドランチが統合受信トレイから始まる"): this same background
    /// data-load path fires on every launch once an account exists, so
    /// there was structurally no way to land on the sidebar root first.
    /// `RootView.onSelected`/`SidebarView.onSelected` is the only path that
    /// pushes the column forward now, and it only fires from a real row
    /// tap — this auto-select stays data-only so macOS/iPadOS's
    /// always-three-column layout (where there is no "column" to push,
    /// `preferredCompactColumn` is simply ignored) is unaffected either
    /// way.
    func observeMailboxes(accountId: String, dbWriter: any DatabaseWriter, onMailboxesLoaded: (() -> Void)? = nil) async {
        // メールボックス単位の非表示: `includeHidden: false` keeps a hidden
        // mailbox out of the sidebar/hamburger tree entirely — see
        // `MailboxQuery.request(accountId:includeHidden:)`'s doc comment.
        let observation = MailboxQuery.observation(accountId: accountId, includeHidden: false)
        do {
            for try await mailboxes in observation.values(in: dbWriter) {
                mailboxesByAccountId[accountId] = mailboxes
                onMailboxesLoaded?()
            }
        } catch {
            // A failing mailbox observation for one account shouldn't take
            // down the caller; that account's section just stops updating.
        }
    }

    /// Per-mailbox unread badges for one account — runs alongside
    /// `observeMailboxes(accountId:dbWriter:)` (same lifetime, a second
    /// `.task` at the same call site) rather than folded into it, since the
    /// two observe different tables (`mailbox` vs. `message`) and there's
    /// no reason a `mailbox` row change should wait on/block a `message`
    /// count re-fetch or vice versa.
    func observeUnreadCounts(accountId: String, dbWriter: any DatabaseWriter) async {
        let observation = MessageQuery.unreadCountsObservation(accountId: accountId)
        do {
            for try await counts in observation.values(in: dbWriter) {
                for (mailboxId, count) in counts {
                    unreadByMailboxId[mailboxId] = count
                }
                // A mailbox that just went from "has unread" to "fully
                // read" drops out of `counts` entirely (`MessageQuery
                // .unreadCounts`'s doc comment) — without this, its badge
                // would keep showing the last-known nonzero count forever.
                let staleMailboxIds = (mailboxesByAccountId[accountId] ?? [])
                    .compactMap(\.id)
                    .filter { counts[$0] == nil }
                for mailboxId in staleMailboxIds {
                    unreadByMailboxId.removeValue(forKey: mailboxId)
                }
            }
        } catch {
            // A failing observation just stops that account's badges from updating.
        }
    }

    func observeOutbox(accountIds: [String], dbWriter: any DatabaseWriter) async {
        let observation = OutboxQuery.observation(accountIds: accountIds)
        do {
            for try await pending in observation.values(in: dbWriter) {
                outboxCount = pending.count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }

    /// Drafts IMAP sync: counts the same unified list `DraftsView` shows
    /// (local + server-origin, deduplicated) — `DraftQuery.observation`'s
    /// local-only count would otherwise undercount whenever a
    /// server-origin draft (written by another client) hasn't been opened/
    /// saved in this app yet.
    func observeDraftCount(accountIds: [String], dbWriter: any DatabaseWriter) async {
        let observation = DraftQuery.unifiedObservation(accountIds: accountIds)
        do {
            for try await drafts in observation.values(in: dbWriter) {
                draftCount = drafts.count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }

    func observeFailedOpCount(accountIds: [String], dbWriter: any DatabaseWriter) async {
        let observation = OpQueueQuery.failedOpsObservation(accountIds: accountIds, minAttempts: OpQueueProcessor.maxAttempts)
        do {
            for try await ops in observation.values(in: dbWriter) {
                failedOpCount = ops.count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }

    /// Partial-sync-failure visibility — see `MailboxSyncFailuresView`'s
    /// doc comment for the full rationale. Separate counter/sheet from
    /// `failedOpCount` deliberately: an `opQueue` failure (a *user action*
    /// like a delete/flag-change that couldn't be applied) and a mailbox
    /// sync failure (the *background list-refresh itself* not working for
    /// that mailbox) are different problems with different retry
    /// semantics, so collapsing them into one counter/sheet would blur
    /// what's actually wrong.
    func observeMailboxSyncFailureCount(accountIds: [String], dbWriter: any DatabaseWriter) async {
        let observation = MailboxQuery.syncFailuresObservation(accountIds: accountIds)
        do {
            for try await mailboxes in observation.values(in: dbWriter) {
                mailboxSyncFailureCount = mailboxes.count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }

    /// M10: the "すべての受信トレイ" badge — re-observed whenever the
    /// caller's account list changes (adding/removing an account widens/
    /// narrows which inbox-role mailboxes count toward the total).
    func observeUnifiedInboxUnreadCount(accountIds: [String], dbWriter: any DatabaseWriter) async {
        let observation = MessageQuery.unifiedInboxUnreadCountObservation(accountIds: accountIds)
        do {
            for try await count in observation.values(in: dbWriter) {
                unifiedInboxUnread = count
            }
        } catch {
            // A failing observation just stops the badge from updating.
        }
    }
}
