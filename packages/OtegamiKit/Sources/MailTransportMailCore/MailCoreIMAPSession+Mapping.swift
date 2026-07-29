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

        return MailboxInfo(
            path: path,
            displayPath: displayPath,
            delimiter: delimiter,
            role: role(for: flags, path: path, displayPath: displayPath),
            attributes: attributes
        )
    }

    /// Task #119 (実機報告「その他 → Trash」): SPECIAL-USE (`flags`) is always
    /// authoritative when the server advertises it, but plenty of real-world
    /// servers (iCloud among them) don't advertise it for every standard
    /// mailbox, or at all. `MailboxRole.inferred(fromDisplayPath:)` is the
    /// name-based fallback for exactly that gap — see its own doc comment for
    /// the matched name list and why it lives in `MailTransport` rather than
    /// here.
    private static func role(for flags: MCOIMAPFolderFlag, path: String, displayPath: String) -> MailboxRole {
        if flags.contains(.inbox) { return .inbox }
        if flags.contains(.sentMail) { return .sent }
        if flags.contains(.drafts) { return .drafts }
        if flags.contains(.trash) { return .trash }
        if flags.contains(.spam) { return .junk }
        if flags.contains(.archive) { return .archive }
        if flags.contains(.allMail) { return .all }
        if flags.contains(.starred) { return .flagged }
        // SPECIAL-USE-less servers (the dev mailstack's Dovecot among
        // them): fall back to the one name IMAP itself guarantees the
        // meaning of.
        if path.caseInsensitiveCompare("INBOX") == .orderedSame { return .inbox }
        return MailboxRole.inferred(fromDisplayPath: displayPath)
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

    static func envelope(from message: MCOIMAPMessage) -> FetchedEnvelope {
        let header = message.header
        let parts = message.mainPart.map(flattenParts) ?? []
        let gmailThreadId = message.gmailThreadID
        let gmailMessageId = message.gmailMessageID

        return FetchedEnvelope(
            uid: message.uid,
            messageId: header?.messageID.map(messageIdWithAngleBrackets),
            inReplyTo: header?.inReplyTo?.first.map(messageIdWithAngleBrackets),
            references: (header?.references ?? []).map(messageIdWithAngleBrackets),
            subject: header?.subject,
            from: header?.from.flatMap(emailAddress(from:)).map { [$0] } ?? [],
            to: emailAddresses(from: header?.to),
            cc: emailAddresses(from: header?.cc),
            bcc: emailAddresses(from: header?.bcc),
            replyTo: emailAddresses(from: header?.replyTo),
            date: header?.date,
            internalDate: header?.receivedDate ?? Date(),
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

    private static func messageFlags(from flags: MCOMessageFlag) -> MessageFlags {
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

    // MARK: - RFC 2231 filename fallback

    /// Patches `content.parts` with RFC 2231-decoded filenames recovered
    /// from `rawMessage`'s raw `Content-Disposition` headers, for whichever
    /// attachment part(s) mailcore2 left with `filename == nil`
    /// (`docs/roadmap.md`'s "RFC 2231 ファイル名のみのメール" note).
    ///
    /// Matches positionally: the n-th part needing a filename (in `parts`'
    /// order) gets the n-th filename `RFC2231FilenameDecoder
    /// .extendedFilenames` found in `rawMessage` (in document order). This
    /// is safe rather than approximate because `extendedFilenames` only
    /// ever surfaces `Content-Disposition` headers using the *extended*
    /// (`filename*=`) form in the first place — exactly the set mailcore2
    /// fails to parse a `filename` out of — so a plain `filename="..."`
    /// header (which mailcore2 already resolved, leaving that part's
    /// `filename` non-nil) never contributes an entry and never occupies a
    /// slot in either list. The two orderings only need to agree among
    /// *this* subset, and both walk the message's MIME parts in the same
    /// (wire/structural) order.
    ///
    /// If `rawMessage` contains fewer RFC 2231 filenames than there are
    /// parts missing one (e.g. one attachment's header was malformed enough
    /// that `extendedFilenames` skipped it — see its own doc comment), the
    /// remaining part(s) are left with `filename == nil`, same as before
    /// this fallback ran; this never removes information, only adds it.
    static func applyRFC2231FilenameFallback(to content: MessageBodyContent, rawMessage: Data) -> MessageBodyContent {
        let missingIndices = content.parts.indices.filter {
            content.parts[$0].isAttachment && content.parts[$0].filename == nil
        }
        guard !missingIndices.isEmpty else { return content }

        let filenames = RFC2231FilenameDecoder.extendedFilenames(inRawMessage: rawMessage)
        guard !filenames.isEmpty else { return content }

        var patched = content
        for (offset, index) in missingIndices.enumerated() where offset < filenames.count {
            patched.parts[index].filename = filenames[offset]
        }
        return patched
    }

    // MARK: - Body (M2)

    /// `MCOMessageParser.attachments()`/`.htmlInlineAttachments()` return
    /// `MCOAttachment` (a leaf `MCOAbstractPart` subclass) rather than the
    /// `MCOIMAPPart` that `flattenParts(_:)` above works with —
    /// `MCOMessageParser` re-parses the whole RFC822 blob locally rather
    /// than walking the server's `BODYSTRUCTURE`, so its parts have no IMAP
    /// part specifier at all. `uniqueID` (a stable identifier the parser
    /// assigns while walking the MIME tree) stands in as `MIMEPartInfo
    /// .partId` instead; it isn't a `BODY[<partId>]` fetch key, so M8's
    /// attachment *data* download will need its own lookup (`partForUniqueID`
    /// on a freshly-parsed message), not `fetchMessageBody(partId:)`.
    static func bodyContent(from parser: MCOMessageParser) -> MessageBodyContent {
        MessageBodyContent(
            plainText: nonEmpty(parser.plainTextBodyRendering()),
            html: nonEmpty(parser.htmlBodyRendering()),
            parts: parts(from: parser)
        )
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    /// Attachments and inline (`cid:`-referenced) parts, de-duplicated by
    /// `uniqueID` — `attachments()` and `htmlInlineAttachments()` can both
    /// report the same part in some multipart layouts.
    private static func parts(from parser: MCOMessageParser) -> [MIMEPartInfo] {
        var seenUniqueIDs: Set<String> = []
        var result: [MIMEPartInfo] = []
        for part in (parser.attachments() ?? []) + (parser.htmlInlineAttachments() ?? []) {
            let uniqueID = part.uniqueID ?? ""
            guard seenUniqueIDs.insert(uniqueID).inserted else { continue }
            result.append(mimePartInfo(from: part))
        }
        return result
    }

    // MARK: - Attachment data (M8)

    /// Looks up `uniqueID` (an `AttachmentRecord.partId` value, as stamped
    /// by `parts(from:)` above at body-fetch time) among `parser`'s parts
    /// and returns its raw, decoded bytes — `MCOAbstractPart.getData(_:)`
    /// handles the `Content-Transfer-Encoding` decoding itself, the same
    /// division of labor `bodyContent(from:)` already relies on for the
    /// text parts. `applyUniquePartID` (mailcore2's own uniqueID assignment,
    /// a deterministic breadth-first walk of the MIME tree keyed only by
    /// structural position) reruns identically every time the same RFC 822
    /// bytes are reparsed, which is what makes re-fetching+reparsing the
    /// whole message here — rather than trying to map back to a real IMAP
    /// `BODY[<partId>]` specifier the parser never captured in the first
    /// place — a safe way to resolve this uniqueID back to data on a fresh
    /// `MCOMessageParser` instance (see `MailCoreIMAPSession.fetchMessageBody`'s
    /// doc comment for the full rationale, and `parts(from:)`'s doc comment
    /// above for why `partId` is a uniqueID and not a `BODYSTRUCTURE` path
    /// to begin with). Runs inside a MailCore2 completion closure (MailCore2's
    /// own internal thread), like every other `private static` helper in
    /// this file — never touches actor state.
    static func partData(from parser: MCOMessageParser, uniqueID: String) -> Data? {
        guard let part = parser.partForUniqueID(uniqueID: uniqueID) else { return nil }
        return MCOAbstractPart.getData(part)
    }

    private static func mimePartInfo(from part: MCOAbstractPart) -> MIMEPartInfo {
        let mimeType = part.mimeType ?? "application/octet-stream"
        let components = mimeType.split(separator: "/", maxSplits: 1)
        let type = components.first.map(String.init) ?? mimeType
        let subtype = components.count > 1 ? String(components[1]) : ""
        let size = (part as? MCOAttachment)?.data?.count ?? 0

        return MIMEPartInfo(
            partId: part.uniqueID ?? "",
            mimeType: type,
            mimeSubtype: subtype,
            filename: part.filename,
            contentId: part.contentID,
            isAttachment: part.isAttachment,
            size: size
        )
    }

    // MARK: - QRESYNC vanished / UID search (Task #79)

    /// Converts `syncMessages`'s `vanishedMessages` index set (QRESYNC's
    /// `VANISHED` response, RFC 7162 §3.2.10) to a plain `Set<UInt32>` of
    /// expunged UIDs. `nil` when MailCore2 reports no such index set at all
    /// — the server doesn't support QRESYNC (or it simply isn't active for
    /// this fetch) — as opposed to a non-`nil` empty set, which means
    /// QRESYNC *was* active and genuinely nothing vanished this round. See
    /// `MailCoreIMAPSession.fetchEnvelopes(changedSince:)`'s doc comment for
    /// why that distinction matters to `MailboxSyncer`.
    static func vanishedUIDs(from indexSet: MCOIndexSet?) -> Set<UInt32>? {
        guard let indexSet else { return nil }
        var result: Set<UInt32> = []
        indexSet.enumerate { result.insert(UInt32($0)) }
        return result
    }

    /// Converts a `UID SEARCH` result index set to a plain `Set<UInt32>` —
    /// used by `searchExistingUIDs`. `nil` (a legitimately empty match, or
    /// MailCore2 handing back no index set at all) maps to an empty set
    /// either way: unlike `vanishedUIDs(from:)` above, there is no
    /// "unknown vs. definitely none" distinction to preserve here — a
    /// completed `UID SEARCH` is always authoritative about what it found.
    static func uidSet(from indexSet: MCOIndexSet?) -> Set<UInt32> {
        guard let indexSet else { return [] }
        var result: Set<UInt32> = []
        indexSet.enumerate { result.insert(UInt32($0)) }
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
