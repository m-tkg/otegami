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
    private static let capabilityIndex: [(UInt64, IMAPCapability)] = [
        (5, .condstore),
        (7, .idle),
        (10, .move),
        (12, .namespace),
        (13, .qresync),
        (19, .uidPlus),
        (34, .xoauth2),
        (36, .gmailExtensions),
    ]

    static func capabilities(from indexSet: MCOIndexSet?) -> Set<IMAPCapability> {
        guard let indexSet else { return [] }
        var result: Set<IMAPCapability> = []
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

        let displayPath: String
        if let delimiter, delimiter != "/" {
            displayPath = path.replacingOccurrences(of: delimiter, with: "/")
        } else {
            displayPath = path
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
            role: role(for: flags, path: path),
            attributes: attributes
        )
    }

    private static func role(for flags: MCOIMAPFolderFlag, path: String) -> MailboxRole {
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
        return .none
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
