import Foundation

/// C7 「送信取り消し」猶予: how long `PendingSendCoordinator` waits after
/// "送信" is tapped before actually handing the message to `OpQueueProcessor`
/// .replay — the window a blue countdown bar (`SendCountdownBar`) covers and
/// "送信を取り消す" can still cancel within.
///
/// **30秒/60秒はあえて選択肢から外している**: iOS can suspend/freeze a
/// backgrounded app's process at any point past a few seconds of grace
/// (`beginBackgroundTask`'s expiration handler has no fixed guaranteed
/// window, and iOS 26 has progressively tightened background execution
/// budgets) — a 30s/60s window would imply a promise ("your cancel window
/// is still open") this app cannot actually keep if the user leaves the
/// foreground partway through, so it isn't offered at all rather than
/// silently breaking sometimes. This is also why leaving the foreground
/// (`PendingSendCoordinator.finalizeNow()`, wired from `OtegamiTabRootView`'s
/// scene-phase observer) always cuts the window short immediately instead of
/// letting it keep counting down in the background — see that method's doc
/// comment.
enum SendCancelWindow: Int, CaseIterable, Identifiable {
    case none = 0
    case fiveSeconds = 5
    case tenSeconds = 10

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: "なし"
        case .fiveSeconds: "5秒"
        case .tenSeconds: "10秒"
        }
    }

    var duration: TimeInterval? {
        self == .none ? nil : TimeInterval(rawValue)
    }
}

enum SendCancelSettingsStore {
    static let windowKey = "sendCancel.window"
    static let defaultWindow = SendCancelWindow.fiveSeconds
}
