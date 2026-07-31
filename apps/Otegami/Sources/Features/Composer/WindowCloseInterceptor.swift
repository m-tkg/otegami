import SwiftUI

#if os(macOS)
/// Reaches AppKit's `NSWindowDelegate.windowShouldClose(_:)` — the only way
/// to intercept the titlebar's native close button — from pure SwiftUI.
/// `WindowGroup`/`Settings` scenes don't expose a delegate hook directly,
/// so this is the standard workaround: a zero-size `NSViewRepresentable`
/// that, once AppKit has actually placed it into a window's view hierarchy,
/// swaps in a delegate that forwards the one question this Composer cares
/// about (`shouldClose`) back into SwiftUI state. Fixes the gap noted in
/// `docs/roadmap.md`'s "既知の制約" list: closing the Composer via the
/// titlebar red button used to bypass the save-draft/discard confirmation
/// entirely, silently losing unsaved text — only the toolbar "キャンセル"
/// button (and, on iOS, the sheet's own swipe-to-dismiss block) went
/// through `handleCloseRequested()`/`hasUnsavedChanges`.
struct WindowCloseInterceptor: NSViewRepresentable {
    /// Forwarded to `Coordinator.shouldClose` on every `updateNSView` call
    /// (cheap — a closure property assignment) so it always reflects the
    /// current SwiftUI-side handler, even though the delegate itself is
    /// only ever assigned once per window (see `updateNSView`).
    var shouldClose: () -> Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        // `nsView.window` is `nil` until AppKit actually places this view
        // into a window's hierarchy; `updateNSView` re-runs on every
        // SwiftUI body re-evaluation, so the first call after the window
        // exists is what wires this up. Guarding on `!==` avoids fighting
        // any other code that might reassign the delegate later, and
        // avoids redundantly reassigning it on every re-render once set.
        guard let window = nsView.window, window.delegate !== context.coordinator else { return }
        window.delegate = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldClose: shouldClose)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldClose: () -> Bool
        init(shouldClose: @escaping () -> Bool) {
            self.shouldClose = shouldClose
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            shouldClose()
        }
    }
}
#endif
