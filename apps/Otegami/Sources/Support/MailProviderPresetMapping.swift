import OtegamiCore
import OtegamiStore

/// Task #116「アカウント追加画面のプロバイダ拡充」: bridges `OtegamiCore
/// .MailConnectionSecurityKind` (the Linux-compatible, dependency-free
/// security tag `MailProviderPreset` carries) to `OtegamiStore
/// .ConnectionSecurityRecord` (what `AccountRecord`/`AccountConnectionTesting`
/// actually need) — the one place every preset-driven setup view
/// (`YahooAccountSetupView`, `YahooJapanAccountSetupView`,
/// `AccountSetupView`'s `.exchange` preset) converts between the two, so a
/// future preset never has to duplicate this mapping inline.
extension MailConnectionSecurityKind {
    var connectionSecurityRecord: ConnectionSecurityRecord {
        switch self {
        case .plain: .plain
        case .startTLS: .startTLS
        case .tls: .tls
        }
    }
}
