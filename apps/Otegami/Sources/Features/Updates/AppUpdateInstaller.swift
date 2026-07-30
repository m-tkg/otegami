import Foundation
import OtegamiCore

#if os(macOS)
/// Task #182 (macOS アプリ内アップデート、実機フィードバック「更新ボタンも
/// 置いて、自身のアップデートができるようにしてほしい」): downloads,
/// verifies, and installs a GitHub Release's `Otegami.zip` in place of the
/// currently-running app bundle. `AboutView` is the only caller — always
/// user-initiated (a button press), never automatic (spec: "ユーザーの明示
/// 操作でのみ実行し、自動更新はしない").
///
/// Steps, in order (spec's own numbered list):
/// 1. Download the asset to a private temp directory (`AppUpdateDownloader`,
///    which itself enforces the GitHub-only host allowlist on every
///    redirect).
/// 2. List the zip's entries and reject the whole archive if any entry could
///    zip-slip out of the extraction directory (`ZipEntryPathValidator`),
///    *then* extract with `ditto` (Apple's own tool, already zip-slip-safe on
///    its own — this is defense in depth, matching this repo's SEC-A
///    precedent of never trusting a single layer), then re-verify the
///    resulting app bundle path is still contained
///    (`FileSystemPathContainment.isDescendant`, the exact helper SEC-A
///    added for the equivalent attachment-filename bug).
/// 3. Compare the extracted app's Developer ID signature
///    (`CodeSignatureIdentity`) against the *running* app's — any mismatch,
///    including either side being unreadable/unsigned, aborts before
///    anything is moved. Also requires Gatekeeper (`spctl -a`) to accept the
///    candidate.
/// 4. Check write permission on the running app's parent directory; if
///    that fails, throw `.noWritePermission` rather than attempting
///    anything — `AboutView` catches this specifically and falls back to
///    opening the release page instead (spec: "書き込み権限が無い場合は...
///    フォールバックで良い" — this app deliberately does not attempt an
///    authenticated/elevated install here, matching that spec note).
/// 5. Swap: move the running app aside to a sibling backup path, move the
///    verified candidate into the vacated original path, and only then
///    delete the backup — if the second move fails, the backup is moved
///    back so the original app is never left missing.
///
/// Every step after the download runs a real `/usr/bin/*` tool via
/// `Process` (`ditto`/`unzip`/`codesign`/`spctl`) rather than reimplementing
/// zip parsing or code-signature verification in Swift — these are the same
/// Apple-maintained tools `release-macos.yml` itself already relies on for
/// the equivalent build-time steps.
actor AppUpdateInstaller {
    enum InstallError: Error, Equatable {
        case disallowedDownloadHost
        case downloadFailed(String)
        case emptyArchive
        case unsafeZipEntry(String)
        case extractionFailed(String)
        case appBundleNotFound
        case appBundleEscapedExtractionDirectory
        case signatureUnreadable(String)
        case signatureMismatch
        case gatekeeperRejected(String)
        case noWritePermission(path: String)
        case swapFailed(String)
    }

    enum Phase: Equatable, Sendable {
        case downloading(fraction: Double)
        case verifying
        case installing
        case done
    }

    struct Outcome: Sendable, Equatable {
        let installedVersion: String
    }

    private let downloader: AppUpdateDownloader
    /// Overridable only by tests/previews that want to point this at a
    /// throwaway copy of the app rather than `Bundle.main` itself — the real
    /// call site (`AboutView`) never sets this, so production always targets
    /// whatever app is actually running.
    private let currentAppURLOverride: URL?

    init(downloader: AppUpdateDownloader = AppUpdateDownloader(), currentAppURLOverride: URL? = nil) {
        self.downloader = downloader
        self.currentAppURLOverride = currentAppURLOverride
    }

    private var currentAppURL: URL {
        currentAppURLOverride ?? Bundle.main.bundleURL
    }

    func install(asset: GitHubReleaseAsset, onPhase: @escaping @Sendable (Phase) -> Void) async throws -> Outcome {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtegamiUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let zipURL = workDir.appendingPathComponent("Otegami.zip")
        do {
            try await downloader.download(from: asset.browserDownloadURL, to: zipURL) { fraction in
                onPhase(.downloading(fraction: fraction))
            }
        } catch AppUpdateDownloader.DownloadError.disallowedHost {
            throw InstallError.disallowedDownloadHost
        } catch {
            throw InstallError.downloadFailed(error.localizedDescription)
        }

        onPhase(.verifying)

        let entries = try await listZipEntries(at: zipURL)
        guard !entries.isEmpty else { throw InstallError.emptyArchive }
        if let unsafeEntry = entries.first(where: { !ZipEntryPathValidator.isSafe(entryPath: $0) }) {
            throw InstallError.unsafeZipEntry(unsafeEntry)
        }

        let extractDir = workDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try await extract(zipAt: zipURL, to: extractDir)

        guard let candidateAppURL = try findAppBundle(in: extractDir) else {
            throw InstallError.appBundleNotFound
        }
        // Second containment layer, after `ditto` has already run — see this
        // type's doc comment. `ditto` itself won't produce an escaping path,
        // but this fails closed rather than trusting that unconditionally.
        guard FileSystemPathContainment.isDescendant(of: extractDir, url: candidateAppURL) else {
            throw InstallError.appBundleEscapedExtractionDirectory
        }

        let currentIdentity = try await codeSignatureIdentity(of: currentAppURL)
        let candidateIdentity = try await codeSignatureIdentity(of: candidateAppURL)
        guard currentIdentity.isSameSigner(as: candidateIdentity) else {
            throw InstallError.signatureMismatch
        }
        try await verifyGatekeeperAcceptance(of: candidateAppURL)

        let parentDirectory = currentAppURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDirectory.path) else {
            throw InstallError.noWritePermission(path: parentDirectory.path)
        }

        onPhase(.installing)
        let installedVersion = bundleShortVersion(of: candidateAppURL) ?? "?"
        try swap(candidateAppURL: candidateAppURL, currentAppURL: currentAppURL)

        onPhase(.done)
        return Outcome(installedVersion: installedVersion)
    }

    // MARK: - Zip listing / extraction

    private func listZipEntries(at zipURL: URL) async throws -> [String] {
        let result = try await runProcess("/usr/bin/unzip", arguments: ["-Z1", zipURL.path])
        guard result.status == 0 else {
            throw InstallError.extractionFailed("unzip -Z1: \(result.stderr)")
        }
        return result.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func extract(zipAt zipURL: URL, to destination: URL) async throws {
        let result = try await runProcess("/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, destination.path])
        guard result.status == 0 else {
            throw InstallError.extractionFailed("ditto -x -k: \(result.stderr)")
        }
    }

    private func findAppBundle(in directory: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let appBundles = contents.filter { $0.pathExtension == "app" }
        return appBundles.count == 1 ? appBundles.first : nil
    }

    // MARK: - Signature / Gatekeeper verification

    private func codeSignatureIdentity(of appURL: URL) async throws -> CodeSignatureIdentity {
        // `codesign -dv` writes its human-readable summary to **stderr**, not
        // stdout — a long-standing tool quirk (`man codesign` documents `-d`
        // as printing to standard error); reading stdout here would silently
        // see an empty string and every parse would come back all-`nil`.
        let result = try await runProcess("/usr/bin/codesign", arguments: ["-dv", "--verbose=4", appURL.path])
        guard result.status == 0 else {
            throw InstallError.signatureUnreadable("codesign -dv (\(appURL.lastPathComponent)): \(result.stderr)")
        }
        return CodeSignatureIdentity.parse(codesignOutput: result.stderr)
    }

    private func verifyGatekeeperAcceptance(of appURL: URL) async throws {
        let result = try await runProcess("/usr/sbin/spctl", arguments: ["-a", "-vv", "--type", "execute", appURL.path])
        guard result.status == 0 else {
            throw InstallError.gatekeeperRejected(result.stderr)
        }
    }

    private func bundleShortVersion(of appURL: URL) -> String? {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    // MARK: - Swap

    /// Moves `currentAppURL` aside to a sibling backup path, moves
    /// `candidateAppURL` into the now-vacated `currentAppURL` path, and only
    /// then deletes the backup — spec: "新しいものを隣に展開 → 検証 → 入れ替え
    /// → 旧を削除" ("extract the new one alongside → verify → swap → delete
    /// the old one"), "失敗しても元の状態を壊さない" ("even on failure, don't
    /// break the existing state"). If moving the candidate into place fails,
    /// the backup is moved straight back to `currentAppURL` so this method
    /// never leaves the app missing from its expected path.
    ///
    /// Moving the bundle a running process's own executable lives inside is
    /// safe on macOS/Darwin — the running process keeps its already-open
    /// file descriptor/mapped pages for its executable regardless of what
    /// happens to the directory entry pointing at them, the same property
    /// Sparkle-style macOS updaters rely on. Nothing here tries to replace
    /// `Contents/MacOS/Otegami` while it's running; it replaces the whole
    /// bundle *directory entry* the currently-running copy no longer needs
    /// to look up again until the next relaunch.
    private func swap(candidateAppURL: URL, currentAppURL: URL) throws {
        let backupURL = currentAppURL.deletingLastPathComponent()
            .appendingPathComponent(currentAppURL.lastPathComponent + ".old-\(Int(Date().timeIntervalSince1970))")

        do {
            try FileManager.default.moveItem(at: currentAppURL, to: backupURL)
        } catch {
            throw InstallError.swapFailed("could not move the running app aside: \(error.localizedDescription)")
        }

        do {
            try FileManager.default.moveItem(at: candidateAppURL, to: currentAppURL)
        } catch {
            // Roll back: put the original app back exactly where it was.
            try? FileManager.default.moveItem(at: backupURL, to: currentAppURL)
            throw InstallError.swapFailed("could not move the new app into place, rolled back: \(error.localizedDescription)")
        }

        // Best-effort cleanup — a leftover ".old-<timestamp>" bundle next to
        // the app is harmless clutter, not a correctness problem, so a
        // failure here doesn't fail the whole install.
        try? FileManager.default.removeItem(at: backupURL)
    }

    // MARK: - Process helper

    /// Runs `executablePath` and awaits its exit, capturing stdout/stderr
    /// incrementally via `readabilityHandler` (rather than a single
    /// `readDataToEndOfFile()` call inside `terminationHandler`, which can
    /// deadlock if the child writes enough output to fill the pipe buffer
    /// before exiting — a well-known `Process`/`Pipe` pitfall). No output
    /// this method's own call sites read is expected to be large (a file
    /// listing, a codesign summary, an spctl one-liner), but the safer
    /// pattern costs nothing to use unconditionally.
    private func runProcess(_ path: String, arguments: [String]) async throws -> (stdout: String, stderr: String, status: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutBox = OutputBox()
            let stderrBox = OutputBox()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutBox.append(data)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrBox.append(data)
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (stdoutBox.string, stderrBox.string, proc.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Plain accumulation buffer for one pipe's output, written only from
    /// `FileHandle.readabilityHandler`'s dispatch queue — `NSLock`-guarded
    /// since that queue is not this actor, and `terminationHandler` (which
    /// reads `string`) can run on yet another thread.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var string: String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
#endif
