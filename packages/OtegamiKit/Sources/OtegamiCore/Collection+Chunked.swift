/// Splits `self` into consecutive slices of at most `size` elements — used
/// by `OtegamiStore.ThreadAssigner`'s batched `assignAllUnthreaded` to keep
/// every bulk `IN (...)`/`CASE ... WHEN` statement's parameter count
/// comfortably under SQLite's bound-parameter limit, regardless of how
/// large a single batch (or its candidate-key fan-out) gets.
///
/// Moved here from a `private extension Array` inside
/// `OtegamiStore/ThreadAssigner.swift` — `OtegamiCore` has no dependencies
/// of its own (every other module depends on it), making it the natural
/// home for a small generic utility like this one that isn't specific to
/// sync/storage. `public` (unlike the original `private extension`) since
/// it now needs to be visible across the module boundary to
/// `OtegamiStore`, which imports `OtegamiCore`.
public extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
