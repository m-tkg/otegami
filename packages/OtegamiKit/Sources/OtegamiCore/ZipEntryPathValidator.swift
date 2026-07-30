import Foundation

/// Task #182 (macOS アプリ内アップデート): zip-slip defense for the
/// downloaded release archive. Spec: "ダウンロードした zip の展開時に zip
/// slip (`../` を含むエントリでディレクトリ外に書き出す) を踏まないこと" —
/// the same class of bug SEC-A fixed for attachment file names (path
/// traversal via a crafted file name), applied here to zip *entry* names
/// instead.
///
/// `AppUpdateInstaller` (app layer, macOS-only) lists a downloaded zip's
/// entry names (`/usr/bin/unzip -Z1`) and rejects the whole archive if
/// `isSafe` returns `false` for any entry, **before** ever handing the file
/// to `ditto -x -k` for actual extraction — defense in depth alongside
/// `ditto` itself (an Apple-maintained tool that already sanitizes entry
/// paths), not a replacement for it.
///
/// Pure string logic, no filesystem access — kept in `OtegamiCore` so the
/// safety rule itself is unit-testable with hand-written entry-name
/// fixtures, independent of any real zip file or app-layer target.
public enum ZipEntryPathValidator {
    /// - Returns: `false` for anything that could plausibly escape a
    ///   destination directory once joined onto it: empty names, absolute
    ///   paths, any path component equal to `".."`, and (defensively, even
    ///   though this project only ships on Apple platforms) a leading `~`
    ///   that a naive shell-style joiner might expand.
    public static func isSafe(entryPath: String) -> Bool {
        guard !entryPath.isEmpty else { return false }
        if entryPath.hasPrefix("/") { return false }
        if entryPath.hasPrefix("~") { return false }
        let components = entryPath.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..")
    }

    /// Convenience for the whole list `unzip -Z1` prints at once — the
    /// caller only needs the yes/no "is this archive safe to extract"
    /// answer, not which specific entry tripped it (that detail is still
    /// worth logging at the call site for diagnosis, just not part of this
    /// pure function's contract).
    public static func allSafe(entryPaths: [String]) -> Bool {
        entryPaths.allSatisfy(isSafe(entryPath:))
    }
}
