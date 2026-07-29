import Foundation
import Testing
@testable import OtegamiCore

/// Task #166 (SEC-A, F1/F10): the defense-in-depth containment check
/// `ComposerView.stageAttachments` runs immediately before writing a
/// staged attachment's bytes to disk — see
/// `FileSystemPathContainment`'s doc comment.
@Suite("FileSystemPathContainment")
struct FileSystemPathContainmentTests {
    @Test("a plain child file is a descendant")
    func plainChild() {
        let directory = URL(fileURLWithPath: "/tmp/staging/abc-123", isDirectory: true)
        let url = directory.appendingPathComponent("invoice.pdf")
        #expect(FileSystemPathContainment.isDescendant(of: directory, url: url))
    }

    @Test("a nested child file is a descendant")
    func nestedChild() {
        let directory = URL(fileURLWithPath: "/tmp/staging/abc-123", isDirectory: true)
        let url = directory.appendingPathComponent("nested/invoice.pdf")
        #expect(FileSystemPathContainment.isDescendant(of: directory, url: url))
    }

    @Test("traversal that escapes the directory via '..' is not a descendant")
    func traversalEscapes() {
        let directory = URL(fileURLWithPath: "/tmp/staging/abc-123", isDirectory: true)
        let url = directory.appendingPathComponent("../../../../etc/passwd")
        #expect(!FileSystemPathContainment.isDescendant(of: directory, url: url))
    }

    @Test("an unrelated absolute path is not a descendant")
    func unrelatedAbsolutePath() {
        let directory = URL(fileURLWithPath: "/tmp/staging/abc-123", isDirectory: true)
        let url = URL(fileURLWithPath: "/Users/someone/.zshrc")
        #expect(!FileSystemPathContainment.isDescendant(of: directory, url: url))
    }

    @Test("a sibling directory that merely shares the parent's path as a string prefix is not a descendant")
    func siblingPrefixCollision() {
        // Regression guard for a naive `hasPrefix` on unadorned paths:
        // "/tmp/staging/abc" is a *string* prefix of "/tmp/staging/abc-evil/x"
        // but "abc-evil" is a sibling directory, not a child of "abc".
        let directory = URL(fileURLWithPath: "/tmp/staging/abc", isDirectory: true)
        let url = URL(fileURLWithPath: "/tmp/staging/abc-evil/x")
        #expect(!FileSystemPathContainment.isDescendant(of: directory, url: url))
    }

    @Test("the directory itself (no filename) is not a descendant of itself")
    func directoryItselfIsNotADescendant() {
        let directory = URL(fileURLWithPath: "/tmp/staging/abc-123", isDirectory: true)
        #expect(!FileSystemPathContainment.isDescendant(of: directory, url: directory))
    }
}
