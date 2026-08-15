import CMailCore
import Foundation
import MailCore
import MailTransport
import OtegamiCore

/// Pure MailCore2-model → `MailTransport`-value-type conversions, plus a
/// couple of MailCore2-config helpers. Everything here is `private static`
/// (i.e. `nonisolated`) *by necessity*, not just style: these run inside
/// MailCore2 completion closures, which fire on MailCore2's own internal
/// thread rather than `MailCoreIMAPSession`'s actor executor. None of them
/// touch actor state — they only transform the MailCore2 objects handed to
/// the completion block into this package's `Sendable` types before
/// `MailCoreIMAPSession`'s methods resume their continuation with the
/// result.
extension MailCoreIMAPSession {
    // MARK: - Config / auth

    // `ConnectionType` is a bare Clang-imported struct (`typealias
    // ConnectionType = CMailCore.ConnectionType`, see AndroidShim.swift) —
    // unlike `MCOAuthType`/`MCOMessageFlag`/`MCOIMAPFolderFlag`, MailCore2's
    // Swift port never gave it named static members, only
    // `init(rawValue:)`. Raw values are `ConnectionTypeClear = 1 << 0`,
    // `ConnectionTypeStartTLS = 1 << 1`, `ConnectionTypeTLS = 1 << 2` per
    // the pinned revision's `src/c/abstract/CMessageConstants.h`.
    static func connectionType(for security: MailConnectionSecurity) -> ConnectionType {
        switch security {
        case .plain: ConnectionType(rawValue: 1 << 0)
        case .startTLS: ConnectionType(rawValue: 1 << 1)
        case .tls: ConnectionType(rawValue: 1 << 2)
        }
    }

    static func apply(_ auth: MailAuth, to session: MCOIMAPSession) {
        switch auth {
        case .password(let username, let password):
            session.username = username
            session.password = password
            session.authType = .SASLNone
        case .xoauth2(let username, let accessToken):
            session.username = username
            session.OAuth2Token = accessToken
            session.authType = .XOAuth2
        }
    }

    // MARK: - Errors

    static func mapError(_ error: Error, mailboxPath: String? = nil) -> MailTransportError {
        let nsError = error as NSError
        guard nsError.domain == MailCoreErrorDomain,
              let code = MailCoreError(rawValue: numericCast(nsError.code))
        else {
            return .serverError(underlyingDescription: nsError.localizedDescription)
        }

        switch code {
        case .errorConnection, .errorTLSNotAvailable, .errorCertificate, .errorStartTLSNotAvailable:
            return .connectionFailed(underlyingDescription: nsError.localizedDescription)
        case .errorAuthentication, .errorAuthenticationRequired, .errorGmailApplicationSpecificPasswordRequired:
            return .authenticationFailed(underlyingDescription: nsError.localizedDescription)
        case .errorGmailTooManySimultaneousConnections:
            // 実機報告 (「本文の取得に失敗しました: serverError: … エラー 8」)。
            // MailCore2 がこのコードを立てるのは `LOGIN` 応答の解析時だけ
            // (`MCIMAPSession.cpp` の "Too many simultaneous connections" /
            // "Maximum number of connections" 文字列マッチ) — つまり
            // 「サーバーがコマンドを拒否した」ではなく「接続そのものが張れ
            // なかった」。`.serverError` に丸めると `BodyFetcher
            // .attemptSelfHeal` が UID の陳腐化と誤認しうるので分けてある
            // (`MailTransportError.tooManyConnections` の doc comment 参照)。
            return .tooManyConnections(underlyingDescription: nsError.localizedDescription)
        case .errorNonExistantFolder:
            return .mailboxNotFound(path: mailboxPath ?? "")
        case .errorCanceled:
            return .cancelled
        default:
            return .serverError(underlyingDescription: nsError.localizedDescription)
        }
    }

    // MARK: - Capabilities

    /// `(IndexSet bit index, capability)` pairs, per the `IMAPCapability` C
    /// enum declared in the pinned mailcore2 revision's
    /// `src/c/abstract/CMessageConstants.h`. Hardcoded because that C enum
    /// isn't re-exported through the "MailCore" Swift module (only through
    /// the internal "CMailCore" target, which isn't a public product of the
    /// `mailcore2` package) — pinning an exact revision in Package.swift is
    /// what keeps these indices safe to hardcode. `SPECIAL-USE` isn't part
    /// of this enum; mailboxes report it via `MCOIMAPFolderFlag` on
    /// `listMailboxes()` instead, which `mailboxInfo(from:)` reads directly.
    private static let capabilityIndex: [(UInt64, MailTransport.IMAPCapability)] = [
        (5, .condstore),
        (7, .idle),
        (10, .move),
        (12, .namespace),
        (13, .qresync),
        (19, .uidPlus),
        (34, .xoauth2),
        (36, .gmailExtensions),
    ]

    static func capabilities(from indexSet: MCOIndexSet?) -> Set<MailTransport.IMAPCapability> {
        guard let indexSet else { return [] }
        var result: Set<MailTransport.IMAPCapability> = []
        for (index, capability) in capabilityIndex where indexSet.contains(index) {
            result.insert(capability)
        }
        return result
    }

    // MARK: - Mailboxes

    static func mailboxInfo(from folder: MCOIMAPFolder) -> MailboxInfo {
        let path = folder.path ?? ""
        let delimiterScalar = folder.delimiter
        let delimiter: String? = delimiterScalar == 0
            ? nil
            : String(UnicodeScalar(UInt8(bitPattern: delimiterScalar)))

        // RFC 3501 mailbox paths are modified-UTF-7 encoded (e.g. Gmail's
        // "&MFkweTBmMG4w4TD8MOs-" for "すべてのメール") — decode before
        // normalizing the hierarchy delimiter to "/". The delimiter itself
        // is always plain printable ASCII (never part of an encoded shift
        // run), so decoding first and replacing the delimiter after
        // produces the same segmentation as decoding each path component
        // individually, with less code.
        let decodedPath = ModifiedUTF7.decode(path)
        let displayPath: String
        if let delimiter, delimiter != "/" {
            displayPath = decodedPath.replacingOccurrences(of: delimiter, with: "/")
        } else {
            displayPath = decodedPath
        }

        let flags = folder.flags
        var attributes: MailboxAttributes = []
        if flags.contains(.noSelect) { attributes.insert(.noSelect) }
        if flags.contains(.noInferiors) { attributes.insert(.noInferiors) }
        if flags.contains(.marked) { attributes.insert(.marked) }
        if flags.contains(.unmarked) { attributes.insert(.unmarked) }

        let (role, roleIsAuthoritative) = role(for: flags, path: path, displayPath: displayPath)
        return MailboxInfo(
            path: path,
            displayPath: displayPath,
            delimiter: delimiter,
            role: role,
            attributes: attributes,
            roleIsAuthoritative: roleIsAuthoritative
        )
    }

    /// Task #119 (実機報告「その他 → Trash」): SPECIAL-USE (`flags`) is always
    /// authoritative when the server advertises it, but plenty of real-world
    /// servers (iCloud among them) don't advertise it for every standard
    /// mailbox, or at all. `MailboxRole.inferred(fromDisplayPath:)` is the
    /// name-based fallback for exactly that gap — see its own doc comment for
    /// the matched name list and why it lives in `MailTransport` rather than
    /// here.
    ///
    /// Task #154: also reports whether the returned role came from one of
    /// the authoritative checks above (SPECIAL-USE flags, or the guaranteed
    /// `"INBOX"` path) rather than the name-guess fallback — see
    /// `MailboxInfo.roleIsAuthoritative`'s doc comment for why `AccountSyncer`
    /// needs this distinction.
    private static func role(for flags: MCOIMAPFolderFlag, path: String, displayPath: String) -> (role: MailboxRole, isAuthoritative: Bool) {
        if flags.contains(.inbox) { return (.inbox, true) }
        if flags.contains(.sentMail) { return (.sent, true) }
        if flags.contains(.drafts) { return (.drafts, true) }
        if flags.contains(.trash) { return (.trash, true) }
        if flags.contains(.spam) { return (.junk, true) }
        if flags.contains(.archive) { return (.archive, true) }
        if flags.contains(.allMail) { return (.all, true) }
        if flags.contains(.starred) { return (.flagged, true) }
        // SPECIAL-USE-less servers (the dev mailstack's Dovecot among
        // them): fall back to the one name IMAP itself guarantees the
        // meaning of.
        if path.caseInsensitiveCompare("INBOX") == .orderedSame { return (.inbox, true) }
        return (MailboxRole.inferred(fromDisplayPath: displayPath), false)
    }

    static func mailboxStatus(from info: MCOIMAPFolderInfo) -> MailboxStatus {
        MailboxStatus(
            uidValidity: info.uidValidity,
            uidNext: info.uidNext,
            highestModSeq: info.modSequenceValue,
            messageCount: Int(info.messageCount)
        )
    }

    // MARK: - Envelopes

    /// - Parameter fetchedAt: The wall-clock moment this envelope's `FETCH`
    ///   response was received — captured by the caller right before
    ///   issuing the request, not read fresh here (a batch covers many
    ///   messages fetched in the same round trip, and should judge all of
    ///   them against the same reference moment). Feeds `EnvelopeDateSentinel`
    ///   below; see that type's doc comment for why this is needed at all
    ///   (Task #193).
    static func envelope(from message: MCOIMAPMessage, fetchedAt: Date) -> FetchedEnvelope {
        let header = message.header
        let parts = message.mainPart.map(flattenParts) ?? []
        let gmailThreadId = message.gmailThreadID
        let gmailMessageId = message.gmailMessageID
        // INTERNALDATE (`MCOMessageHeader.receivedDate`) is set server-side
        // at APPEND/delivery time and always overwritten unconditionally by
        // MailCore2 whenever the FETCH response carries it (this app always
        // requests `.internalDate` — see this file's callers) — unlike
        // `.date` below, it's never defaulted to "now" by MailCore2 itself,
        // so it's safe to read as-is.
        let internalDate = header?.receivedDate ?? Date()
        // Task #193: MailCore2's `MessageHeader` default constructor
        // unconditionally stamps a freshly-created header's `.date` with
        // `time(NULL)` before the envelope is parsed, and only overwrites
        // it when the server's `ENVELOPE` response has a parseable `Date:`
        // — a message with a missing/malformed `Date:` header keeps that
        // construction-time "now" stamp forever, which this app used to
        // store verbatim (and re-store on every non-CONDSTORE resync,
        // since that path re-fetches the whole window every pass). Left
        // uncorrected, a years-old message picked up that way looks
        // "just sent" to `Threader`'s subject-fallback pass, folding it
        // into whatever recent thread happens to share its subject and a
        // participant. `EnvelopeDateSentinel` catches this without needing
        // a MailCore2-side "was this actually parsed" accessor (unlike the
        // analogous Message-ID case just below, MailCore2 exposes none for
        // `.date`): `nil` here lets every downstream reader fall back to
        // `internalDate` via this codebase's existing `date ?? internalDate`
        // idiom (`ThreadAssigner`/`MessageQuery`/`ThreadQuery`/the message
        // list UI all already do this for the ordinary "no Date: header at
        // all" case).
        let date = (header?.date).flatMap {
            EnvelopeDateSentinel.reconciledDate(date: $0, internalDate: internalDate, referenceTime: fetchedAt)
        }
        // Same root cause, the Message-ID side: MailCore2 fabricates a
        // random UUID-based Message-ID for a header whose envelope has none
        // (`MessageHeader::init`'s `generateMessageID` branch) — and, same
        // as `.date`, regenerates a *different* random one on every resync
        // of a message that genuinely never had one, since a fresh
        // `MessageHeader` starts from scratch each fetch. Unlike `.date`,
        // MailCore2 does expose a direct "was this fabricated" accessor
        // here (`isMessageIDAutoGenerated`), so this one needs no
        // heuristic: a fabricated ID is worse than no ID (it churns every
        // sync, breaking `reconcilePendingRelocation`'s/any future resync's
        // ability to match this message across mailboxes) — `nil` is
        // already a supported, expected case downstream (see
        // `reconcilePendingRelocation`'s doc comment).
        let messageId = (header?.isMessageIDAutoGenerated == true) ? nil : header?.messageID.map(messageIdWithAngleBrackets)

        return FetchedEnvelope(
            uid: message.uid,
            messageId: messageId,
            inReplyTo: header?.inReplyTo?.first.map(messageIdWithAngleBrackets),
            references: (header?.references ?? []).map(messageIdWithAngleBrackets),
            subject: header?.subject,
            from: header?.from.flatMap(emailAddress(from:)).map { [$0] } ?? [],
            to: emailAddresses(from: header?.to),
            cc: emailAddresses(from: header?.cc),
            bcc: emailAddresses(from: header?.bcc),
            replyTo: emailAddresses(from: header?.replyTo),
            date: date,
            internalDate: internalDate,
            flags: messageFlags(from: message.flags),
            size: Int(message.size),
            gmailThreadId: gmailThreadId == 0 ? nil : gmailThreadId,
            gmailMessageId: gmailMessageId == 0 ? nil : gmailMessageId,
            parts: parts
        )
    }

    /// MailCore2's `MCOMessageHeader.messageID`/`.references`/`.inReplyTo`
    /// strip the RFC 5322 angle brackets (`<...>`) that delimit a
    /// `msg-id`. `FetchedEnvelope`'s documented contract keeps them
    /// (`"<abc123@example.com>"`) — matching how the headers actually read
    /// on the wire, and matching what `Threader`/`OtegamiStore` compare
    /// against for `In-Reply-To`/`References` — so this backend re-adds
    /// them rather than the protocol's contract bending to match one
    /// backend's normalization.
    private static func messageIdWithAngleBrackets(_ raw: String) -> String {
        raw.hasPrefix("<") && raw.hasSuffix(">") ? raw : "<\(raw)>"
    }

    /// Not `private`: `MailCoreIMAPSession.fetchFlagsBatch` (a different
    /// file, same module) reuses this directly for Task #194's flags-only
    /// fetch rather than duplicating the bit-mapping.
    static func messageFlags(from flags: MCOMessageFlag) -> MessageFlags {
        var result: MessageFlags = []
        if flags.contains(.seen) { result.insert(.seen) }
        if flags.contains(.answered) { result.insert(.answered) }
        if flags.contains(.flagged) { result.insert(.flagged) }
        if flags.contains(.draft) { result.insert(.draft) }
        if flags.contains(.deleted) { result.insert(.deleted) }
        return result
    }

    /// The reverse of `messageFlags(from:)`, for `store(mailboxPath:change:)`
    /// (M3): our `MessageFlags` → MailCore2's `MCOMessageFlag`.
    static func mcoMessageFlag(from flags: MessageFlags) -> MCOMessageFlag {
        var result: MCOMessageFlag = []
        if flags.contains(.seen) { result.insert(.seen) }
        if flags.contains(.answered) { result.insert(.answered) }
        if flags.contains(.flagged) { result.insert(.flagged) }
        if flags.contains(.draft) { result.insert(.draft) }
        if flags.contains(.deleted) { result.insert(.deleted) }
        return result
    }

    /// `IMAPStoreFlagsRequestKind` is a plain (non-`NS_ENUM`) C enum from
    /// `CMessageConstants.h`, so — like `ConnectionType` above — MailCore2's
    /// Swift port only gives it `init(rawValue:)`, not named cases; raw
    /// values are the C declaration order (`Add = 0`, `Remove = 1`,
    /// `Set = 2`).
    static func storeFlagsRequestKind(for op: FlagOp) -> IMAPStoreFlagsRequestKind {
        switch op {
        case .add: IMAPStoreFlagsRequestKind(rawValue: 0)
        case .remove: IMAPStoreFlagsRequestKind(rawValue: 1)
        case .replace: IMAPStoreFlagsRequestKind(rawValue: 2)
        }
    }

    private static func emailAddress(from address: MCOAddress) -> EmailAddress? {
        guard let mailbox = address.mailbox, !mailbox.isEmpty else { return nil }
        return EmailAddress(name: address.displayName, address: mailbox)
    }

    private static func emailAddresses(from addresses: [MCOAddress]?) -> [EmailAddress] {
        (addresses ?? []).compactMap(emailAddress(from:))
    }

    /// Flattens MailCore2's recursive `BODYSTRUCTURE` part tree
    /// (`MCOAbstractPart`/`MCOAbstractMultipart`) into a leaf-only list —
    /// multipart containers (`multipart/mixed`, `multipart/alternative`,
    /// ...) aren't content themselves, so only their children are emitted.
    private static func flattenParts(_ part: MCOAbstractPart) -> [MIMEPartInfo] {
        if let multipart = part as? MCOAbstractMultipart {
            return (multipart.parts ?? []).flatMap(flattenParts)
        }

        let mimeType = part.mimeType ?? "application/octet-stream"
        let components = mimeType.split(separator: "/", maxSplits: 1)
        let type = components.first.map(String.init) ?? mimeType
        let subtype = components.count > 1 ? String(components[1]) : ""
        let partId = (part as? MCOIMAPPart)?.partID ?? ""
        let size = (part as? MCOIMAPPart)?.size ?? 0

        return [MIMEPartInfo(
            partId: partId,
            mimeType: type,
            mimeSubtype: subtype,
            filename: part.filename,
            contentId: part.contentID,
            isAttachment: part.isAttachment,
            size: Int(size)
        )]
    }

    // MARK: - QRESYNC vanished / UID search (Task #79, Task #167 / F5)

    /// Circuit breaker for `materializedUIDs(from:)`: the most UIDs either
    /// `vanishedUIDs(from:)` or `uidSet(from:)` will ever expand a single
    /// server-reported index set into. RFC 3501 UIDs are 32-bit, so any
    /// real mailbox's vanished/search-match set is nowhere near this — it
    /// exists purely to bound the memory an adversarial (or MITM'd, or
    /// compromised) IMAP server can force this client to allocate by
    /// reporting a huge-but-technically-`UInt32`-representable range (e.g.
    /// `1:4294967295`). See F5 in
    /// `CLAUDE-SECURITY-20260729-134850/CLAUDE-SECURITY-RESULTS.md`.
    private static let maxMaterializedUIDCount = 200_000

    /// Converts `indexSet`'s ranges to a `Set<UInt32>`, defending against a
    /// server-controlled index set whose ranges reach past what `UInt32`
    /// can represent — RFC 7162's `VANISHED (EARLIER) n:*` is mapped by
    /// mailcore2's `indexSetFromSet` to a range ending at `UINT64_MAX`
    /// (`* == 0` in libetpan's `mailimap_seq_number_parse`, which
    /// `indexSetFromSet` then turns into `RangeMake(n, UINT64_MAX)`) — or
    /// simply enormous (`1:4294967295`, ~4.3 billion elements). The
    /// previous implementation drove `MCOIndexSet.enumerate`, which calls
    /// this method's block once per element with a `UInt64` — piping that
    /// straight into `UInt32(_:)` (a trapping, range-checked initializer)
    /// crashed the process outright the first time an element exceeded
    /// `UInt32.max`, and even a range that stayed within `UInt32`'s range
    /// but was merely huge would materialize hundreds of millions of `Set`
    /// entries and exhaust memory first. This walks `allRanges()` instead
    /// (mailcore2's dense-range representation, never itself proportional
    /// to element count) so an out-of-bounds or oversized range can be
    /// detected and rejected *before* any trapping conversion or
    /// unbounded materialization happens:
    ///
    /// - A range whose lower bound already exceeds `UInt32.max` is skipped
    ///   entirely — RFC 3501 UIDs are 32-bit, so nothing in it could be a
    ///   real UID.
    /// - A range's upper bound is clipped to `UInt32.max`, computed with
    ///   overflow-safe addition (`addingReportingOverflow`) since a
    ///   "vanished-until-end" range's `length` can itself be `UInt64.max`
    ///   — `location + length` would trap on plain `+`.
    /// - If the running total across every (already-clipped) range would
    ///   exceed `maxMaterializedUIDCount`, returns `nil` immediately rather
    ///   than continuing to materialize a huge `Set` — callers treat `nil`
    ///   as "can't safely say" and fall back to a cheaper reconciliation
    ///   path instead of trusting an incomplete/truncated result.
    /// - Every element that does get inserted is bounded to `[0,
    ///   UInt32.max]` by the two checks above, so `UInt32(truncatingIfNeeded:)`
    ///   (never-trapping, unlike `UInt32(_:)`) is safe here purely as
    ///   defense in depth, not because it's expected to ever actually
    ///   truncate.
    private static func materializedUIDs(from indexSet: MCOIndexSet) -> Set<UInt32>? {
        var result: Set<UInt32> = []
        result.reserveCapacity(min(Int(clamping: indexSet.count()), maxMaterializedUIDCount))
        for range in indexSet.allRanges() {
            let location = range.location
            guard location <= UInt64(UInt32.max) else { continue }

            let upper: UInt64
            let (sum, overflowed) = location.addingReportingOverflow(range.length)
            upper = overflowed ? UInt64(UInt32.max) : min(sum, UInt64(UInt32.max))
            guard upper >= location else { continue }

            let rangeCount = upper - location + 1
            guard result.count + Int(clamping: rangeCount) <= maxMaterializedUIDCount else { return nil }

            var value = location
            while value <= upper {
                result.insert(UInt32(truncatingIfNeeded: value))
                value += 1
            }
        }
        return result
    }

    /// Converts `syncMessages`'s `vanishedMessages` index set (QRESYNC's
    /// `VANISHED` response, RFC 7162 §3.2.10) to a plain `Set<UInt32>` of
    /// expunged UIDs. `nil` when MailCore2 reports no such index set at all
    /// — the server doesn't support QRESYNC (or it simply isn't active for
    /// this fetch) — as opposed to a non-`nil` empty set, which means
    /// QRESYNC *was* active and genuinely nothing vanished this round. See
    /// `MailCoreIMAPSession.fetchEnvelopes(changedSince:)`'s doc comment for
    /// why that distinction matters to `MailboxSyncer`. As of Task #167,
    /// also returns `nil` — collapsing into the same "unknown" case — when
    /// `materializedUIDs(from:)` refuses to safely materialize the set (an
    /// out-of-range or oversized server-reported range); `MailboxSyncer`'s
    /// existing `nil` handling already falls back to
    /// `detectAndRemoveVanishedByUIDSearch`'s `UID SEARCH` reconciliation
    /// in that case, so this doesn't need its own separate signal.
    static func vanishedUIDs(from indexSet: MCOIndexSet?) -> Set<UInt32>? {
        guard let indexSet else { return nil }
        return materializedUIDs(from: indexSet)
    }

    /// Converts a `UID SEARCH` result index set to a plain `Set<UInt32>` —
    /// used by `searchExistingUIDs`. `nil` `indexSet` (a legitimately empty
    /// match, or MailCore2 handing back no index set at all) maps to an
    /// empty set: unlike `vanishedUIDs(from:)` above, there is no "unknown
    /// vs. definitely none" distinction to preserve for that case — a
    /// completed `UID SEARCH` is always authoritative about what it found.
    /// A *non-`nil`* `indexSet` that `materializedUIDs(from:)` can't safely
    /// materialize (Task #167 / F5) is different: silently returning an
    /// empty set here would read to `MailboxSyncer.detectAndRemoveVanishedByUIDSearch`
    /// as "the server confirms zero of these UIDs still exist" and delete
    /// every locally-stored message in the window — the opposite of safe.
    /// This throws instead, which that caller's existing error handling
    /// already treats as "couldn't confirm this pass, delete nothing."
    static func uidSet(from indexSet: MCOIndexSet?) throws -> Set<UInt32> {
        guard let indexSet else { return [] }
        guard let result = materializedUIDs(from: indexSet) else {
            throw MailTransportError.serverError(
                underlyingDescription: "UID SEARCH result too large to process safely"
            )
        }
        return result
    }

    // MARK: - UID ranges

    static func indexSet(for range: UIDRange) -> MCOIndexSet {
        // MailCoreRange.length is *not* an element count: `MCOIndexSet(range:
        // MailCoreRange(location: L, length: N))` covers the closed interval
        // [L, L+N] (N+1 elements) — confirmed empirically against this
        // pinned revision, since it isn't documented in the Swift port.
        // `location: 10, length: .max` covers [10, *) with no practical
        // upper bound, matching IMAP's `10:*`.
        let length: UInt64
        if let upperBound = range.upperBound {
            length = UInt64(upperBound) - UInt64(range.lowerBound)
        } else {
            length = UInt64.max
        }
        return MCOIndexSet(range: MailCoreRange(location: UInt64(range.lowerBound), length: length))
    }

    /// A discrete, possibly non-contiguous `UIDSet` (M3's `store`/`move`
    /// targets), rather than the closed-range `UIDRange` above.
    static func indexSet(for uids: UIDSet) -> MCOIndexSet {
        let indexSet = MCOIndexSet()
        for uid in uids.uids {
            indexSet.add(UInt64(uid))
        }
        return indexSet
    }

    /// Splits `range` into consecutive sub-ranges of at most `size` UIDs,
    /// so `fetchEnvelopes(batchSize:)` can issue several smaller `FETCH`
    /// commands instead of one unbounded one. Open-ended ranges
    /// (`UIDRange.upperBound == nil`, IMAP's `lowerBound:*`) are left
    /// un-chunked — the mailbox's actual highest UID isn't known
    /// client-side without another round trip, so there's nothing correct
    /// to chunk against.
    static func chunk(_ range: UIDRange, size: Int) -> [UIDRange] {
        guard let upperBound = range.upperBound, upperBound >= range.lowerBound else {
            return [range]
        }

        var chunks: [UIDRange] = []
        var start = range.lowerBound
        while start <= upperBound {
            let end = min(start &+ UInt32(clamping: max(1, size)) &- 1, upperBound)
            chunks.append(UIDRange(lowerBound: start, upperBound: end))
            if end == UInt32.max { break }
            start = end + 1
        }
        return chunks
    }
}
