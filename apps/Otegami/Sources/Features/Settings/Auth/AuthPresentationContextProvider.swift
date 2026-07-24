import AuthenticationServices
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The one piece `ASWebAuthenticationSessionRunner` needs from the app that
/// `GoogleOAuth` (a UI-agnostic package target) can't provide itself: a
/// window to anchor the consent sheet to. `#if os(...)`-scoped rather than
/// split into two files since the two branches are each a couple of lines
/// and sharing the doc comment/class declaration keeps them easy to compare.
final class AuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        // The key window of the foreground-active scene — mirrors the
        // pattern most ASWebAuthenticationSession sample code uses; this
        // app only ever has one scene (`UIApplicationSupportsMultipleScenes`
        // is `false`, see `project.yml`), so there's no ambiguity about
        // which scene's window to anchor to.
        let scene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
        return scene?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #elseif os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
}
