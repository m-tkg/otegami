import Foundation
import Testing

@testable import PushRelayClient

/// Unit coverage for `NotificationPermissionResolver` — the pure
/// authorized/denied/not-determined decision `PushTokenCenter.requestToken()`
/// applies before calling `registerForRemoteNotifications()`. Nothing here
/// touches `UNUserNotificationCenter`/`UIApplication`; that real,
/// OS-driven path is what `scripts/verify-ios-push-simulated.sh` exercises
/// end-to-end (documented in `docs/verify.md`'s "M9 追補" section).
@Suite("NotificationPermissionResolver")
struct NotificationPermissionResolverTests {
    private final class FakeChecker: NotificationPermissionChecking, @unchecked Sendable {
        var status: NotificationAuthorizationStatus
        var requestResult: Result<Bool, Error> = .success(true)
        private(set) var requestAuthorizationCallCount = 0

        init(status: NotificationAuthorizationStatus) {
            self.status = status
        }

        func currentAuthorizationStatus() async -> NotificationAuthorizationStatus {
            status
        }

        func requestAuthorization() async throws -> Bool {
            requestAuthorizationCallCount += 1
            return try requestResult.get()
        }
    }

    @Test("already authorized proceeds without prompting")
    func alreadyAuthorized() async {
        let checker = FakeChecker(status: .authorized)
        let outcome = await NotificationPermissionResolver.resolve(using: checker)
        #expect(outcome == .granted)
        #expect(checker.requestAuthorizationCallCount == 0)
    }

    @Test("already denied stops without prompting again")
    func alreadyDenied() async {
        let checker = FakeChecker(status: .denied)
        let outcome = await NotificationPermissionResolver.resolve(using: checker)
        #expect(outcome == .denied)
        #expect(checker.requestAuthorizationCallCount == 0)
    }

    @Test("not determined prompts and follows the user's grant")
    func notDeterminedGranted() async {
        let checker = FakeChecker(status: .notDetermined)
        checker.requestResult = .success(true)
        let outcome = await NotificationPermissionResolver.resolve(using: checker)
        #expect(outcome == .granted)
        #expect(checker.requestAuthorizationCallCount == 1)
    }

    @Test("not determined prompts and follows the user's denial")
    func notDeterminedDenied() async {
        let checker = FakeChecker(status: .notDetermined)
        checker.requestResult = .success(false)
        let outcome = await NotificationPermissionResolver.resolve(using: checker)
        #expect(outcome == .denied)
        #expect(checker.requestAuthorizationCallCount == 1)
    }

    @Test("not determined treats a thrown error from requestAuthorization as denied")
    func notDeterminedThrows() async {
        let checker = FakeChecker(status: .notDetermined)
        checker.requestResult = .failure(NSError(domain: "test", code: 1))
        let outcome = await NotificationPermissionResolver.resolve(using: checker)
        #expect(outcome == .denied)
    }
}
