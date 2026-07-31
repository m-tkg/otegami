import Foundation
import Testing

@testable import PushRelayClient

/// Unit coverage for the pure list-management logic behind Task #213's
/// "プッシュ通知の診断" screen — `PushDiagnosticsHistory.inserting(_:into:)`
/// (newest-first insert + cap) and the JSON `encode`/`decode` round trip.
/// Deliberately does not exercise `appending(_:toSuite:)`/`loadRuns(fromSuite:)`
/// against a real `UserDefaults` suite (would need an App Group entitlement
/// to mean anything close to production; the pure functions underneath are
/// what actually needs coverage, same split `NotificationServiceDiagnosticsTests`
/// uses for the OSLog-adjacent classifier next to it).
@Suite("PushDiagnosticsHistory")
struct PushDiagnosticsStoreTests {
    private func makeRun(stages: [PushDiagnosticsRun.StageRecord] = [.init(stage: .parsePayload, outcome: .success, elapsedMs: 1)]) -> PushDiagnosticsRun {
        PushDiagnosticsRun(stages: stages, totalElapsedMs: 42)
    }

    @Test("inserting puts the new run at the front (newest first)")
    func insertsAtFront() {
        let older = makeRun()
        let newer = makeRun()
        let updated = PushDiagnosticsHistory.inserting(newer, into: [older])
        #expect(updated.map(\.id) == [newer.id, older.id])
    }

    @Test("inserting trims to maxRuns, dropping the oldest entries")
    func trimsToMaxRuns() {
        let existing = (0..<PushDiagnosticsHistory.maxRuns).map { _ in makeRun() }
        let newest = makeRun()
        let updated = PushDiagnosticsHistory.inserting(newest, into: existing)
        #expect(updated.count == PushDiagnosticsHistory.maxRuns)
        #expect(updated.first?.id == newest.id)
        // The single oldest entry (last in `existing`) must have been
        // dropped to make room.
        #expect(!updated.contains { $0.id == existing.last?.id })
    }

    @Test("inserting below the cap keeps every run, doesn't pad or drop")
    func keepsEverythingBelowCap() {
        let existing = [makeRun(), makeRun()]
        let updated = PushDiagnosticsHistory.inserting(makeRun(), into: existing)
        #expect(updated.count == 3)
    }

    @Test("encode/decode round-trips a run with every Outcome case, byte for byte")
    func encodeDecodeRoundTrips() throws {
        let run = PushDiagnosticsRun(
            stages: [
                .init(stage: .parsePayload, outcome: .success, elapsedMs: 0),
                .init(stage: .fetchBody, outcome: .skipped(reason: "showsBodyPreview off"), elapsedMs: nil),
                .init(
                    stage: .connect,
                    outcome: .failure(category: "connectionFailed", looksRateLimited: false, logDetail: "Could not connect to the host"),
                    elapsedMs: 1234
                ),
            ],
            totalElapsedMs: 1500
        )
        let encoded = try #require(PushDiagnosticsHistory.encode([run]))
        let decoded = PushDiagnosticsHistory.decode(encoded)
        #expect(decoded == [run])
    }

    @Test("decode of nil data returns an empty list, not an error")
    func decodeOfNilDataIsEmpty() {
        #expect(PushDiagnosticsHistory.decode(nil).isEmpty)
    }

    @Test("decode of garbage data returns an empty list rather than crashing")
    func decodeOfGarbageDataIsEmpty() {
        let garbage = Data("not json".utf8)
        #expect(PushDiagnosticsHistory.decode(garbage).isEmpty)
    }

    @Test("a rate-limited failure outcome round-trips its looksRateLimited flag")
    func rateLimitedFailureRoundTrips() throws {
        let outcome = PushDiagnosticsRun.Outcome.failure(category: "serverError", looksRateLimited: true, logDetail: "A87 NO [LIMIT] STATUS Rate limit hit.")
        let run = makeRun(stages: [.init(stage: .select, outcome: outcome, elapsedMs: 55)])
        let decoded = PushDiagnosticsHistory.decode(try #require(PushDiagnosticsHistory.encode([run])))
        #expect(decoded.first?.stages.first?.outcome == outcome)
    }
}
