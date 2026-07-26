import Foundation

/// Shells out to `docker compose exec dovecot doveadm ...` against
/// `dev/mailstack`, standing in for "another IMAP client just delivered
/// mail" in `WatcherPoolRealDovecotIntegrationTests` — mirrors
/// `packages/OtegamiKit/Tests/MailTransportMailCoreTests/DoveadmHelper.swift`
/// (same idea, duplicated rather than shared since the two test targets
/// don't otherwise depend on each other).
///
/// Only ever invoked from tests gated by `RelayIMAPTestEnvironment.primary`
/// (i.e. `OTEGAMI_TEST_IMAP_HOST` set) — a plain `swift test` never shells
/// out to `docker`.
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
    /// test process's working directory. Overridable via
    /// `OTEGAMI_TEST_MAILSTACK_DIR` for any other layout.
    static var mailstackDirectory: String {
        if let override = ProcessInfo.processInfo.environment["OTEGAMI_TEST_MAILSTACK_DIR"] {
            return override
        }
        // #filePath: .../server/otegami-relay/Tests/OtegamiRelayTests/DoveadmHelper.swift
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DoveadmHelper.swift -> OtegamiRelayTests/
            .deletingLastPathComponent() // OtegamiRelayTests/ -> Tests/
            .deletingLastPathComponent() // Tests/ -> otegami-relay/
            .deletingLastPathComponent() // otegami-relay/ -> server/
            .deletingLastPathComponent() // server/ -> repo root
            .appendingPathComponent("dev/mailstack")
            .path
    }

    /// `doveadm save -u <user> -m <mailboxPath>`, piping `content` in as
    /// the message's raw RFC 822 bytes.
    static func save(user: String, mailboxPath: String = "INBOX", content: String) throws {
        try run(["doveadm", "save", "-u", user, "-m", mailboxPath], stdin: content)
    }

    /// Re-runs `dev/mailstack/seed/seed.sh`, restoring the standard
    /// fixture set — any integration test that injects extra mail via
    /// `save` should call this in a `defer` so it doesn't leak into other
    /// suites (`MailCoreIMAPSessionIntegrationTests` et al. assume the
    /// standard seed).
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

/// `nil` (suites skipped) unless `OTEGAMI_TEST_IMAP_HOST` is set — same
/// opt-in convention as `packages/OtegamiKit`'s `TestIMAPEnvironment`.
enum RelayIMAPTestEnvironment {
    static var primary: (host: String, port: Int, username: String, password: String)? {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["OTEGAMI_TEST_IMAP_HOST"] else { return nil }
        let port = environment["OTEGAMI_TEST_IMAP_PORT"].flatMap(Int.init) ?? 1143
        let username = environment["OTEGAMI_TEST_IMAP_USER"] ?? "test1@otegami.test"
        let password = environment["OTEGAMI_TEST_IMAP_PASSWORD"] ?? "test1234"
        return (host: host, port: port, username: username, password: password)
    }
}
