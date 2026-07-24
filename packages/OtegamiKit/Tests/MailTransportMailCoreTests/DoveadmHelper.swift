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
