import Foundation
import Testing
@testable import MailTransportMailCore
import MailCore
import MailTransport

/// Task #167 / F5 (`CLAUDE-SECURITY-20260729-134850/CLAUDE-SECURITY-RESULTS.md`):
/// `vanishedUIDs(from:)`/`uidSet(from:)` used to enumerate a server-controlled
/// `MCOIndexSet` and trap-convert every 64-bit element to `UInt32` — an
/// adversarial QRESYNC `* VANISHED` response mapping to a range that runs
/// past `UInt32.max` (or is simply enormous) crashed the process or
/// exhausted memory. These tests exercise the fixed range-based
/// implementation directly against `MCOIndexSet`, without needing a live
/// IMAP server.
struct VanishedUIDMappingTests {
    @Test
    func vanishedUIDsNilForNoIndexSet() {
        #expect(MailCoreIMAPSession.vanishedUIDs(from: nil) == nil)
    }

    @Test
    func vanishedUIDsSmallNormalRange() {
        let indexSet = MCOIndexSet()
        // MCOIndexSet(range:) covers the *closed* interval
        // [location, location+length] (length is not an element count).
        indexSet.add(range: MailCoreRange(location: 100, length: 5))
        let result = MailCoreIMAPSession.vanishedUIDs(from: indexSet)
        #expect(result == Set<UInt32>(100...105))
    }

    @Test
    func vanishedUIDsMultipleDisjointRanges() {
        let indexSet = MCOIndexSet()
        indexSet.add(range: MailCoreRange(location: 10, length: 2))
        indexSet.add(range: MailCoreRange(location: 100, length: 0))
        let result = MailCoreIMAPSession.vanishedUIDs(from: indexSet)
        #expect(result == Set<UInt32>([10, 11, 12, 100]))
    }

    /// `* VANISHED (EARLIER) 4294967290:*` — libetpan maps the trailing
    /// `*` to 0, which mailcore2's `indexSetFromSet` turns into a range
    /// ending at `UINT64_MAX`. Must not trap and must not hang materializing
    /// an effectively-infinite set; the right edge is clipped to
    /// `UInt32.max`, well within this test's safety cap.
    @Test
    func vanishedUIDsClipsOpenEndedRangeToUInt32Max() {
        let indexSet = MCOIndexSet()
        indexSet.add(range: MailCoreRange(location: 4_294_967_290, length: UInt64.max))
        let result = MailCoreIMAPSession.vanishedUIDs(from: indexSet)
        #expect(result == Set<UInt32>(4_294_967_290...UInt32.max))
    }

    /// A range entirely beyond what a 32-bit UID could ever be (RFC 3501)
    /// contributes no elements at all rather than being clamped into range
    /// (which could otherwise collide with real, unrelated UIDs).
    @Test
    func vanishedUIDsSkipsRangeEntirelyBeyondUInt32Max() {
        let indexSet = MCOIndexSet()
        indexSet.add(range: MailCoreRange(location: UInt64(UInt32.max) + 100, length: 5))
        let result = MailCoreIMAPSession.vanishedUIDs(from: indexSet)
        #expect(result == [])
    }

    /// `* VANISHED 1:4294967295` — a technically-`UInt32`-representable but
    /// enormous (~4.3 billion element) range. Must not materialize a huge
    /// `Set` (OOM); the mapping bails out to `nil`, and `MailboxSyncer`'s
    /// existing `nil` handling falls back to `detectAndRemoveVanishedByUIDSearch`.
    @Test
    func vanishedUIDsNilForOversizedRange() {
        let indexSet = MCOIndexSet()
        indexSet.add(range: MailCoreRange(location: 1, length: UInt64(UInt32.max) - 1))
        let result = MailCoreIMAPSession.vanishedUIDs(from: indexSet)
        #expect(result == nil)
    }

    @Test
    func uidSetEmptyForNoIndexSet() throws {
        let result = try MailCoreIMAPSession.uidSet(from: nil)
        #expect(result == [])
    }

    @Test
    func uidSetSmallNormalRange() throws {
        let indexSet = MCOIndexSet()
        indexSet.add(range: MailCoreRange(location: 5, length: 2))
        let result = try MailCoreIMAPSession.uidSet(from: indexSet)
        #expect(result == Set<UInt32>([5, 6, 7]))
    }

    /// Unlike `vanishedUIDs(from:)`, `uidSet(from:)` must never silently
    /// collapse an oversized/unsafe range to an *empty* set — the caller
    /// (`detectAndRemoveVanishedByUIDSearch`) treats an empty `UID SEARCH`
    /// result as "the server confirms none of these UIDs exist anymore"
    /// and deletes every locally-stored message in the window. Throwing
    /// instead is what keeps that non-destructive.
    @Test
    func uidSetThrowsRatherThanReturningEmptyForOversizedRange() {
        let indexSet = MCOIndexSet()
        indexSet.add(range: MailCoreRange(location: 1, length: UInt64(UInt32.max) - 1))
        #expect(throws: MailTransportError.self) {
            _ = try MailCoreIMAPSession.uidSet(from: indexSet)
        }
    }
}
