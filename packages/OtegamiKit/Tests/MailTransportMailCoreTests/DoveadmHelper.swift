import Foundation

/// Shells out to `docker compose exec dovecot doveadm ...` against
/// `dev/mailstack`, standing in for "another IMAP client just did
/// something" in integration tests (M3: `SyncEngineIntegrationTests`
/// needs to inject new mail/flag changes the way a second real client
/// would, so `MailboxSyncer.incrementalSync` has something genuine to
/// pick up over the wire — not just another `MailCoreIMAPSession` call
/// from the same test process).
///
/// Only ever invoked from tests gated by `TestIMAPEnvironment.primary`
/// (i.e. `OTEGAMI_TEST_IMAP_HOST` set), matching the rest of this target's
/// opt-in convention — a plain `swift test` never shells out to `docker`.
enum DoveadmHelper {
    struct CommandFailed: Error, CustomStringConvertible {
        let command: [String]
        let status: Int32
        let output: String

        var description: String {
            "doveadm command failed (\(status)): \(command.joined(separator: " "))\n\(output)"
        }
    }

    /// `dev/mailstack`'s directory, where `docker compose` must run from
    /// (it resolves `compose.yml` relative to CWD). Derived from this
    /// source file's own compile-time path (`#filePath`) rather than the
    /// test process's working directory — that varies by how `swift test`
    /// ends up invoked (a plain shell's CWD vs. a test bundle's, ...), but
    /// this file's location relative to `dev/mailstack` in the repo never
    /// does. Overridable via `OTEGAMI_TEST_MAILSTACK_DIR` for any other
    /// layout.
    static var mailstackDirectory: String {
        if let override = ProcessInfo.processInfo.environment["OTEGAMI_TEST_MAILSTACK_DIR"] {
            return override
        }
        // #filePath: .../packages/OtegamiKit/Tests/MailTransportMailCoreTests/DoveadmHelper.swift
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DoveadmHelper.swift -> MailTransportMailCoreTests/
            .deletingLastPathComponent() // MailTransportMailCoreTests/ -> Tests/
            .deletingLastPathComponent() // Tests/ -> OtegamiKit/
            .deletingLastPathComponent() // OtegamiKit/ -> packages/
            .deletingLastPathComponent() // packages/ -> repo root
            .appendingPathComponent("dev/mailstack")
            .path
    }

    /// `doveadm save -u <user> -m <mailboxPath>`, piping `content` in as
    /// the message's raw RFC 822 bytes — the same mechanism
    /// `dev/mailstack/seed/seed.sh` uses to load fixtures, since the
    /// `dovecot/dovecot` image ships no shell to `docker cp` a file into
    /// directly.
    static func save(user: String, mailboxPath: String = "INBOX", content: String) throws {
        try run(["doveadm", "save", "-u", user, "-m", mailboxPath], stdin: content)
    }

    /// `doveadm flags add -u <user> <flag> mailbox <mailboxPath> all` —
    /// applies `flag` (e.g. `"\\Seen"`) to every message in the mailbox.
    /// Coarse (not scoped to one message) on purpose: integration tests
    /// reset the mailbox to a known single-message state first, so "all"
    /// unambiguously means "that one seeded message".
    static func addFlag(user: String, flag: String, mailboxPath: String = "INBOX") throws {
        try run(["doveadm", "flags", "add", "-u", user, flag, "mailbox", mailboxPath, "all"])
    }

    /// `doveadm expunge -u <user> mailbox <mailboxPath> all` — empties the
    /// mailbox, matching `seed.sh`'s idempotent-reseed pattern so a test
    /// can establish a known starting point regardless of what a previous
    /// test run (or `make mailstack-seed`) left behind.
    static func expungeAll(user: String, mailboxPath: String = "INBOX") throws {
        // `|| true`-equivalent: an empty/never-created mailbox makes
        // `doveadm expunge` exit non-zero, which is fine here.
        _ = try? run(["doveadm", "expunge", "-u", user, "mailbox", mailboxPath, "all"])
    }

    /// `doveadm fetch -u <user> flags mailbox <mailboxPath> HEADER Subject
    /// <subject>` — used by `SMTPIntegrationTests` to confirm a
    /// client-side `IMAPSessionProtocol.append` (M5's best-effort Sent
    /// copy) actually landed server-side, by exact subject rather than
    /// UID (the APPEND response's returned UID isn't always available —
    /// see `append`'s doc comment on `UIDPLUS` support). Returns an empty
    /// string (not a thrown error) when nothing matches, so callers can
    /// poll it in a retry loop the same way `restoreStandardFixtures`'s
    /// callers already do for other doveadm queries.
    static func fetchFlagsBySubject(user: String, mailboxPath: String, subject: String) -> String {
        (try? run(["doveadm", "fetch", "-u", user, "flags", "mailbox", mailboxPath, "HEADER", "Subject", subject])) ?? ""
    }

    /// `doveadm mailbox status -u <user> messages <mailboxPath>` — parses
    /// Dovecot's `"<mailboxPath> messages=N"` response into `N`. Used by
    /// Drafts-sync integration tests to assert "replaced, not duplicated"
    /// (exactly one message in Drafts after an edit-and-resave) without
    /// needing to know any particular message's exact subject/UID. Returns
    /// `0` (not a thrown error) for a mailbox that doesn't exist yet or is
    /// genuinely empty — both report the same "nothing there" outcome a
    /// caller cares about.
    static func messageCount(user: String, mailboxPath: String) -> Int {
        guard let output = try? run(["doveadm", "mailbox", "status", "-u", user, "messages", mailboxPath]) else { return 0 }
        guard let equalsIndex = output.firstIndex(of: "=") else { return 0 }
        let digits = output[output.index(after: equalsIndex)...].prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    /// `doveadm mailbox create -u <user> <mailboxPath>` — used by
    /// integration tests that need a real (non-`SPECIAL-USE`) mailbox to
    /// exist, then stop existing, against an actual Dovecot server (see
    /// `deleteMailbox`'s doc comment for why `SPECIAL-USE` mailboxes like
    /// `Trash`/`Junk` don't work for that purpose on this dev mailstack).
    static func createMailbox(user: String, mailboxPath: String) throws {
        try run(["doveadm", "mailbox", "create", "-u", user, mailboxPath])
    }

    /// `doveadm mailbox delete -u <user> <mailboxPath>`. Note: this dev
    /// mailstack's Dovecot config auto-creates/auto-subscribes the standard
    /// `SPECIAL-USE` mailboxes (`Sent`/`Drafts`/`Junk`/`Trash`) on the next
    /// listing, so deleting one of *those* doesn't durably reproduce "no
    /// such mailbox" the way a plain user-created mailbox does (confirmed
    /// manually: `doveadm mailbox delete ... Junk` followed immediately by
    /// `doveadm mailbox list` still shows `Junk`). Use a mailbox created via
    /// `createMailbox` first for any test that needs the deletion to stick.
    static func deleteMailbox(user: String, mailboxPath: String) throws {
        try run(["doveadm", "mailbox", "delete", "-u", user, mailboxPath])
    }

    /// `doveadm mailbox list -u <user>`, one mailbox name per line —
    /// lets a test assert a mailbox does/doesn't currently exist
    /// server-side without going through `MailCoreIMAPSession` (which is
    /// exactly what's under test).
    static func listMailboxes(user: String) throws -> [String] {
        try run(["doveadm", "mailbox", "list", "-u", user])
            .split(separator: "\n")
            .map(String.init)
    }

    /// Re-runs `dev/mailstack/seed/seed.sh` (the canonical fixture set),
    /// restoring the INBOX state `MailCoreIMAPSessionIntegrationTests`
    /// assumes. Any test that mutates INBOX contents beyond that fixed set
    /// (`expungeAll`, `save`, `addFlag`, ...) — as `SyncEngineIntegrationTests`
    /// does — must call this in a `defer` so the shared mailstack is left
    /// the way other opt-in integration tests in this same target expect
    /// to find it, regardless of test run order.
    static func restoreStandardFixtures() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", "seed/seed.sh"]
        process.currentDirectoryURL = URL(fileURLWithPath: mailstackDirectory)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: outputData, encoding: .utf8) ?? ""
            throw CommandFailed(command: process.arguments ?? [], status: process.terminationStatus, output: output)
        }
    }

    @discardableResult
    private static func run(_ doveadmArguments: [String], stdin: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "compose", "exec", "-T", "dovecot"] + doveadmArguments
        process.currentDirectoryURL = URL(fileURLWithPath: mailstackDirectory)

        let stdinPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        if let stdin {
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try stdinPipe.fileHandleForWriting.close()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw CommandFailed(command: process.arguments ?? [], status: process.terminationStatus, output: output)
        }
        return output
    }
}
