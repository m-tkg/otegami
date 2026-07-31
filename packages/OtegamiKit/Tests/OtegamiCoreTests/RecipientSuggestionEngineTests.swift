import Foundation
import Testing
@testable import OtegamiCore

@Suite("RecipientSuggestionEngine")
struct RecipientSuggestionEngineTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86400) }

    @Test("empty query yields no suggestions")
    func emptyQueryYieldsNothing() {
        let occurrences = [RecipientOccurrence(name: "Tanaka Taro", address: "tanaka@example.com", date: now)]
        #expect(RecipientSuggestionEngine.suggestions(for: "", occurrences: occurrences, now: now) == [])
        #expect(RecipientSuggestionEngine.suggestions(for: "   ", occurrences: occurrences, now: now) == [])
    }

    @Test("matches a Japanese display name by partial string")
    func matchesJapaneseDisplayName() {
        let occurrences = [RecipientOccurrence(name: "たなか たろう", address: "tanaka@example.com", date: now)]
        let results = RecipientSuggestionEngine.suggestions(for: "たなか", occurrences: occurrences, now: now)
        #expect(results.map(\.address) == ["tanaka@example.com"])
    }

    @Test("matches the address itself, case-insensitively")
    func matchesAddressCaseInsensitively() {
        let occurrences = [RecipientOccurrence(name: "Taro", address: "Tanaka@Example.com", date: now)]
        let results = RecipientSuggestionEngine.suggestions(for: "tanaka@", occurrences: occurrences, now: now)
        #expect(results.count == 1)
        #expect(results[0].address == "Tanaka@Example.com")
    }

    @Test("query matching neither name nor address yields nothing")
    func noMatchYieldsNothing() {
        let occurrences = [RecipientOccurrence(name: "Taro", address: "tanaka@example.com", date: now)]
        #expect(RecipientSuggestionEngine.suggestions(for: "suzuki", occurrences: occurrences, now: now) == [])
    }

    @Test("dedups by address (case-insensitive), summing frequency and keeping the most recent display name")
    func dedupsByAddress() {
        let occurrences = [
            RecipientOccurrence(name: "Tanaka Taro", address: "tanaka@example.com", date: days(400)),
            RecipientOccurrence(name: "田中太郎", address: "TANAKA@example.com", date: days(1)),
            RecipientOccurrence(name: "田中太郎", address: "tanaka@Example.com", date: days(30)),
        ]
        let results = RecipientSuggestionEngine.suggestions(for: "tanaka", occurrences: occurrences, now: now)
        #expect(results.count == 1)
        #expect(results[0].name == "田中太郎")
        #expect(results[0].address == "TANAKA@example.com")
    }

    @Test("a frequent-but-old correspondent can still be outranked by someone contacted more recently")
    func recencyCanOutweighOldFrequency() {
        // 2 exchanges yesterday vs. 2 exchanges 400 days ago: same
        // frequencyScore, but only the recent one gets a recencyScore
        // bonus (400 days is past the 180-day half-life floor).
        let occurrences = [
            RecipientOccurrence(name: "Recent", address: "recent@example.com", date: days(1)),
            RecipientOccurrence(name: "Recent", address: "recent@example.com", date: days(2)),
            RecipientOccurrence(name: "Old", address: "old@example.com", date: days(400)),
            RecipientOccurrence(name: "Old", address: "old@example.com", date: days(401)),
        ]
        let results = RecipientSuggestionEngine.suggestions(for: "@example.com", occurrences: occurrences, now: now)
        #expect(results.map(\.address) == ["recent@example.com", "old@example.com"])
    }

    @Test("higher frequency outranks a single more-recent message")
    func frequencyCanOutweighSingleRecentMessage() {
        // One message today (frequencyScore = log2(2) ≈ 1, recencyScore ≈ 1
        // → total ≈ 2) vs. 10 messages 60 days ago (frequencyScore =
        // log2(11) ≈ 3.46, recencyScore ≈ 0.67 → total ≈ 4.13): the
        // frequent correspondent should win even though contacted less
        // recently, since one-off contact shouldn't permanently trump a
        // regular correspondent.
        var occurrences = [RecipientOccurrence(name: "OneOff", address: "oneoff@example.com", date: days(0))]
        for _ in 0..<10 {
            occurrences.append(RecipientOccurrence(name: "Regular", address: "regular@example.com", date: days(60)))
        }
        let results = RecipientSuggestionEngine.suggestions(for: "@example.com", occurrences: occurrences, now: now)
        #expect(results.map(\.address) == ["regular@example.com", "oneoff@example.com"])
    }

    @Test("result count is capped at limit, highest-scoring first")
    func respectsLimit() {
        let occurrences = (0..<20).map { i in
            RecipientOccurrence(name: "Person\(i)", address: "person\(i)@example.com", date: days(Double(i)))
        }
        let results = RecipientSuggestionEngine.suggestions(for: "@example.com", occurrences: occurrences, now: now, limit: 3)
        #expect(results.count == 3)
        // Lower `i` was contacted more recently (fewer days ago) so should
        // rank first.
        #expect(results.map(\.address) == ["person0@example.com", "person1@example.com", "person2@example.com"])
    }

    @Test("an address with no display name falls back to the bare address, formatted verbatim")
    func fallsBackToBareAddress() {
        let occurrences = [RecipientOccurrence(name: nil, address: "noname@example.com", date: now)]
        let results = RecipientSuggestionEngine.suggestions(for: "noname", occurrences: occurrences, now: now)
        #expect(results.count == 1)
        #expect(results[0].name == nil)
        #expect(results[0].formatted == "noname@example.com")
    }

    @Test("formatted matches EmailAddress.description's \"Name <address>\" shape")
    func formattedMatchesEmailAddressDescription() {
        let suggestion = RecipientSuggestion(name: "田中太郎", address: "tanaka@example.com")
        #expect(suggestion.formatted == "田中太郎 <tanaka@example.com>")
    }

    // MARK: - Performance

    /// Task #200 の性能要件「入力のたびに検索が走るので、メールが多い環境でも
    /// 引っかからないように」に対する実測: この純粋関数はキーストロークの
    /// たびに直接呼ばれる想定 (`RecipientSuggestionSource`はDBスキャン結果
    /// を1回だけキャッシュし、以降はこの関数だけを毎回呼ぶ設計 — 詳細は
    /// そちらのdoc comment参照)。20,000件の履歴 (相当に大規模なメール
    /// アーカイブを想定) を1回集計・フィルタ・ソートするのに要する時間を
    /// 実測し、キーストローク毎に許容できる範囲(数十ms未満)に収まって
    /// いることを確認する — 収まっているので、この関数自体をさらにキャッシュ
    /// ・インクリメンタル化する追加の複雑さは(先回りして複雑にしないという
    /// 方針どおり)導入していない。
    @Test("stays fast for a large history (20,000 occurrences), so per-keystroke calls don't need extra caching")
    func performanceWithLargeHistory() {
        var occurrences: [RecipientOccurrence] = []
        occurrences.reserveCapacity(20_000)
        for i in 0..<20_000 {
            occurrences.append(
                RecipientOccurrence(
                    name: "Person \(i % 5000)",
                    address: "person\(i % 5000)@example.com",
                    date: days(Double(i % 400))
                )
            )
        }
        let start = Date()
        let results = RecipientSuggestionEngine.suggestions(for: "person1", occurrences: occurrences, now: now)
        let elapsed = Date().timeIntervalSince(start)
        #expect(!results.isEmpty)
        // Generous bound (real measurement on a dev Mac was well under
        // 50ms) — this is a regression guard, not a tight perf target.
        #expect(elapsed < 0.5)
    }
}
