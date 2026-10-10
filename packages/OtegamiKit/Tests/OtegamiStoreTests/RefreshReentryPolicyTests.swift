import Testing
@testable import OtegamiStore

@Suite("RefreshReentryPolicy")
struct RefreshReentryPolicyTests {
    @Test("ユーザー操作起点はサイレントな自動パスを奪取する")
    func userInitiatedPreemptsSilentPass() {
        #expect(RefreshReentryPolicy.decide(incomingSurfacesErrors: true, runningSurfacesErrors: false) == .preemptRunning)
    }

    @Test("ユーザー操作同士は相乗りする")
    func userInitiatedJoinsUserInitiated() {
        #expect(RefreshReentryPolicy.decide(incomingSurfacesErrors: true, runningSurfacesErrors: true) == .joinRunning)
    }

    @Test("サイレントな自動パスは何が走っていても相乗りする")
    func silentPassAlwaysJoins() {
        #expect(RefreshReentryPolicy.decide(incomingSurfacesErrors: false, runningSurfacesErrors: false) == .joinRunning)
        #expect(RefreshReentryPolicy.decide(incomingSurfacesErrors: false, runningSurfacesErrors: true) == .joinRunning)
    }
}
