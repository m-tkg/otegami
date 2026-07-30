import SwiftUI
import OtegamiRelayAPI

/// Task #173: `PushNotificationSettingsView`'s per-account watch-status
/// list — split into its own `View` (and `PushWatchStatusRow` below, one
/// per `ForEach` element) rather than inlined into that screen's `body`,
/// matching this codebase's CI-type-check-timeout guardrail
/// (`CONTRIBUTING.md`'s "A note on SwiftUI views and CI") for exactly the
/// `ForEach`-of-rows shape that guardrail calls out as a common trigger.
struct PushWatchStatusSection: View {
    var rows: [PushWatchDisplayRow]
    var reregisteringAccountId: String?
    var onReregister: (String) -> Void

    var body: some View {
        Section {
            if rows.isEmpty {
                // `PushWatchDisplayRow.build` returns one row per
                // configured account regardless of its `authType`/`kind`
                // (an ineligible account still gets a row, just
                // `.unsupported` — see that type's doc comment) — this
                // empty state is reached only when there are no accounts
                // configured at all, not "no password accounts" (accurate
                // before Task #175 widened watch eligibility to Gmail/
                // Microsoft too).
                Text("アカウントがありません。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.push.watchStatus.empty")
            } else {
                ForEach(rows) { row in
                    PushWatchStatusRow(
                        row: row,
                        isReregistering: reregisteringAccountId == row.accountId,
                        onReregister: { onReregister(row.accountId) }
                    )
                }
            }
        } header: {
            Text("アカウント別の状態")
        } footer: {
            Text("各アカウントのプッシュ通知 watch の状態です。停止しているアカウントは再登録できます。")
        }
    }
}

/// One row of `PushWatchStatusSection` — account display name, a status
/// label/icon/color, an optional timestamp, and (only when `.stopped`) a
/// "再登録" button. Never shows the IMAP password/token or any message
/// content — `PushWatchDisplayRow`/`WatchSummary` never carry either.
private struct PushWatchStatusRow: View {
    var row: PushWatchDisplayRow
    var isReregistering: Bool
    var onReregister: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: row.displayName)
                .font(.body)
            statusLabel
            if let subtitle {
                // `subtitle` embeds a formatted `Date` via
                // `String(localized:)` interpolation (the codebase's
                // established pattern for a localizable string with a
                // dynamic value — see `MessageHeaderCompactView
                // .toSummaryText`'s identical shape), so this renders it
                // with `Text(verbatim:)` rather than re-interpreting the
                // already-localized result as a `LocalizedStringKey` —
                // same reasoning as `AccountFilterChip`'s doc comment.
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .stopped = row.status {
                reregisterButton
            }
        }
        .accessibilityIdentifier("settings.push.watchStatus.row.\(row.accountId)")
    }

    private var statusLabel: some View {
        Label {
            Text(statusText)
                .font(.caption)
        } icon: {
            Image(systemName: statusSystemImage)
        }
        .foregroundStyle(statusColor)
        .accessibilityIdentifier("settings.push.watchStatus.row.\(row.accountId).status")
    }

    private var reregisterButton: some View {
        Button {
            onReregister()
        } label: {
            if isReregistering {
                ProgressView()
            } else {
                Text("再登録")
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .disabled(isReregistering)
        .accessibilityIdentifier("settings.push.watchStatus.row.\(row.accountId).reregisterButton")
    }

    private var statusText: LocalizedStringKey {
        switch row.status {
        case .registered:
            "登録済み"
        case .notRegistered:
            "未登録"
        case .stopped(.authFailure):
            "停止（認証失敗）"
        case .stopped(.connectionError):
            "停止（接続失敗）"
        case .stopped(.oauthTokenExpired):
            // Task #175: distinct from `.authFailure` — the fix isn't
            // "re-enter your password" but "re-authenticate this account"
            // (アカウント編集の「再認証」), since the relay's copy of the
            // refresh token is permanently dead.
            "停止（再認証が必要）"
        case .stopped(nil):
            "停止"
        case .unsupported:
            // Task #175: Gmail/Outlook accounts are watch-eligible now —
            // this only remains for the edge case
            // `AppEnvironment.isPushWatchCandidate(_:)` still excludes
            // (an `.oauth2` account of neither `.gmail` nor `.microsoft`
            // kind, which shouldn't occur in practice), so the label no
            // longer names a specific provider.
            "対象外"
        case .unavailable:
            "状態を取得できません"
        }
    }

    private var statusSystemImage: String {
        switch row.status {
        case .registered: "checkmark.circle.fill"
        case .notRegistered: "circle.dashed"
        case .stopped: "exclamationmark.triangle.fill"
        case .unsupported: "minus.circle"
        case .unavailable: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .registered: .green
        case .notRegistered, .unsupported, .unavailable: .secondary
        case .stopped: OtegamiColor.destructive
        }
    }

    /// A `String`, not `LocalizedStringKey` — built via `String(localized:)`
    /// interpolation (the codebase's established pattern for a localizable
    /// string with a dynamic value, e.g. `MessageHeaderCompactView
    /// .toSummaryText`), which `scripts/check-localizable-coverage.py`'s
    /// doc comment specifically calls out as the one interpolation form it
    /// *does* resolve to a catalog key (`%@`) — a raw `Text("...\(x)")`
    /// literal is skipped entirely instead.
    private var subtitle: String? {
        switch row.status {
        case .registered:
            if let lastConnectedAt = row.lastConnectedAt {
                String(localized: "最終接続: \(lastConnectedAt.formatted(.relative(presentation: .named)))")
            } else {
                nil
            }
        case .stopped:
            if let lastErrorAt = row.lastErrorAt {
                String(localized: "最終試行: \(lastErrorAt.formatted(.relative(presentation: .named)))")
            } else {
                nil
            }
        case .notRegistered, .unsupported, .unavailable:
            nil
        }
    }
}
