import Testing
@testable import OtegamiCore

/// Task #182 (macOS アプリ内アップデート): covers the zip-slip guard applied
/// to a downloaded release archive's entry names before extraction — see
/// `ZipEntryPathValidator`'s doc comment.
struct ZipEntryPathValidatorTests {
    @Test("accepts an ordinary nested app-bundle entry")
    func acceptsOrdinaryEntry() {
        #expect(ZipEntryPathValidator.isSafe(entryPath: "Otegami.app/Contents/MacOS/Otegami"))
        #expect(ZipEntryPathValidator.isSafe(entryPath: "Otegami.app/"))
    }

    @Test("rejects a parent-directory traversal component")
    func rejectsParentTraversal() {
        #expect(!ZipEntryPathValidator.isSafe(entryPath: "../../etc/launchd.conf"))
        #expect(!ZipEntryPathValidator.isSafe(entryPath: "Otegami.app/../../../etc/passwd"))
        #expect(!ZipEntryPathValidator.isSafe(entryPath: ".."))
    }

    @Test("rejects an absolute path entry")
    func rejectsAbsolutePath() {
        #expect(!ZipEntryPathValidator.isSafe(entryPath: "/etc/launchd.conf"))
    }

    @Test("rejects a home-directory-relative entry")
    func rejectsTildeEntry() {
        #expect(!ZipEntryPathValidator.isSafe(entryPath: "~/Library/LaunchAgents/evil.plist"))
    }

    @Test("rejects an empty entry name")
    func rejectsEmptyEntry() {
        #expect(!ZipEntryPathValidator.isSafe(entryPath: ""))
    }

    @Test("a single unsafe entry fails allSafe for the whole list")
    func allSafeFailsOnSingleBadEntry() {
        let entries = ["Otegami.app/Contents/Info.plist", "../evil"]
        #expect(!ZipEntryPathValidator.allSafe(entryPaths: entries))
    }

    @Test("allSafe passes when every entry is safe")
    func allSafePassesWhenEveryEntrySafe() {
        let entries = ["Otegami.app/", "Otegami.app/Contents/Info.plist", "Otegami.app/Contents/MacOS/Otegami"]
        #expect(ZipEntryPathValidator.allSafe(entryPaths: entries))
    }
}
