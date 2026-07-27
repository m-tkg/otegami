import XCTest

/// Shared XCUITest steps for driving the app against the dev mailstack's
/// `test1@otegami.test` Dovecot account through `AccountSetupView`. Used by
/// both `OtegamiM1VerificationUITests` (initial sync) and
/// `OtegamiM2VerificationUITests` (body fetch / HTML rendering) so the
/// "add account" flow isn't duplicated across verification suites.
extension XCTestCase {
    /// Dismisses the simulator's "Save Password?" prompt if it's up. iOS's
    /// Keychain AutoFill heuristic fires after typing into
    /// `accountSetup.password`'s `SecureField` and tapping "保存して同期開始"
    /// (treating it like a submitted login form) — that system alert is
    /// presented by a separate process (not the app under test), so it
    /// silently steals the *next* synthesized tap/query if left up: e.g. a
    /// message-list row tap intended to select a message ends up hitting
    /// the alert instead, leaving the app on the list with no visible
    /// symptom beyond "nothing after this point ever matches".
    /// `addUIInterruptionMonitor` is the documented API for this but is
    /// unreliable for the Password AutoFill sheet specifically in this
    /// simulator/OS combination; querying `com.apple.springboard` directly
    /// is slower to write but deterministic.
    /// M10: `timeout` is now a parameter (was a hardcoded 3s) — the prompt
    /// doesn't always appear within a fixed window right after saving the
    /// account (its trigger is the password's first real *network* use,
    /// which can land anywhere from immediately to well into the initial
    /// sync depending on how much else is happening), so a caller that's
    /// polling for it repeatedly during some other wait (e.g. between
    /// scroll attempts, `OtegamiM1VerificationUITests`) should pass a much
    /// shorter timeout than the original one-shot post-save check — each
    /// call blocks for the full `timeout` when the prompt *isn't* up, so a
    /// tight polling loop needs this to stay cheap.
    ///
    /// M10: also now checks the app under test's *own* element tree first,
    /// not just `com.apple.springboard` — confirmed via `app.debugDescription`
    /// that on this iOS 26 toolchain the "Save Password?" prompt is hosted
    /// as an in-process `Sheet` attached to the app's own window (not a
    /// cross-process SpringBoard-presented alert the way it evidently was
    /// when this helper was first written), so querying springboard alone
    /// never found it — the `notNow.waitForExistence` timeout always just
    /// ran out, silently leaving the real prompt up to swallow whatever
    /// touch came next. Both queries stay (belt-and-suspenders) since which
    /// process actually hosts this system UI isn't something app code
    /// should have to keep re-diagnosing every OS revision.
    /// M10: waits for `subject` to appear in `messageList.list`, scrolling
    /// down (retrying) if it isn't found immediately, and defensively
    /// dismissing the "Save Password?" prompt before every attempt.
    ///
    /// Needed because `dev/mailstack/seed/fixtures/` grew from 4 files at
    /// M1 to 16 by M8, all seeded into the same INBOX together — the
    /// oldest-dated fixtures (like "ようこそ otegami へ", 01-welcome.eml)
    /// now sort to the *bottom* of the newest-first unified-inbox thread
    /// list, off the initial screen. `messageList.list`'s SwiftUI `List`
    /// only materializes visible rows, so a bare `waitForExistence` can't
    /// find a row that was never off-screen (not the "exact lookup fails
    /// on visible content" pitfall documented elsewhere in this file — the
    /// row genuinely isn't mounted yet). Every UITest that asserts one of
    /// these older seeded subjects appears (`OtegamiM1VerificationUITests`,
    /// `OtegamiM3SetupUITests`, `OtegamiM4SetupUITests`,
    /// `OtegamiM5SetupUITests`, `OtegamiM6OtherAccountFlowUITests`) should
    /// go through this instead of a bare `app.staticTexts[subject]
    /// .waitForExistence(...)` — harmless/near-instant when the subject is
    /// already on screen (checked before any scroll), so this is a safe
    /// drop-in replacement regardless of how far down a given subject
    /// happens to sit.
    ///
    /// Also folds in the "Save Password?" dismiss because that AutoFill
    /// prompt (an in-process sheet on this iOS 26 toolchain, not a
    /// cross-process SpringBoard alert — see `dismissSavePasswordPromptIfNeeded`'s
    /// doc comment) can appear *after* the one-shot post-save dismiss call
    /// already ran (its trigger is the password's first real network use,
    /// which can land well into the initial sync), and once it's up it
    /// swallows every touch including a scroll drag — so scrolling alone,
    /// without this, still doesn't reliably reach a subject further down.
    @discardableResult
    func waitForSeededSubjectScrollingIfNeeded(_ subject: String, in app: XCUIApplication, maxScrollAttempts: Int = 10) -> Bool {
        waitForElementScrollingIfNeeded(app.staticTexts[subject], in: app, maxScrollAttempts: maxScrollAttempts)
    }

    /// General form of `waitForSeededSubjectScrollingIfNeeded(_:in:)` for
    /// any element query, not just an exact-subject `staticTexts` lookup —
    /// e.g. `OtegamiM4SetupUITests`'s `list.cells.containing(...)`
    /// thread-row lookups, which need the exact same "scroll down,
    /// dismissing the Save Password prompt along the way" treatment.
    @discardableResult
    func waitForElementScrollingIfNeeded(_ element: XCUIElement, in app: XCUIApplication, maxScrollAttempts: Int = 10) -> Bool {
        var found = element.waitForExistence(timeout: 10)
        let list = app.collectionViews["messageList.list"]
        var scrollAttempts = 0
        while !found && scrollAttempts < maxScrollAttempts {
            dismissSavePasswordPromptIfNeeded(timeout: 0.5)
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
            start.press(forDuration: 0.05, thenDragTo: end)
            found = element.waitForExistence(timeout: 2)
            scrollAttempts += 1
        }
        return found
    }

    /// D8 「しきい値で自動実行」バッチ: drags `element` horizontally by exactly
    /// `distancePoints` and releases, driving `MessageListRow`'s custom
    /// `DragGesture`-based swipe directly. There is no more "reveal a
    /// button, then tap it" step to drive with `XCUIElement.swipeLeft()`/
    /// `.swipeRight()` (those convenience methods targeted SwiftUI's
    /// built-in `.swipeActions` recognizer specifically, which
    /// `MessageListRow` no longer uses) — the action now fires the instant
    /// this drag's synthesized touch-up event lands, so callers should
    /// assert on the *effect* (a row disappearing, a pin indicator
    /// appearing, ...) right after calling this, not on some intermediate
    /// revealed-button state.
    ///
    /// Point-based (not normalized) so callers can target
    /// `MessageListRow`'s exact `shortSwipeThreshold`/`longSwipeThreshold`
    /// values precisely regardless of the simulator's screen width — see
    /// that type if these drift. Positive `distancePoints` drags right
    /// (arms/fires a *leading* action), negative drags left (*trailing*).
    @discardableResult
    func performThresholdSwipe(on element: XCUIElement, distancePoints: CGFloat, in app: XCUIApplication) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // ObjC `-[XCUICoordinate coordinateWithOffset:]` imports into Swift
        // as `withOffset(_:)` (the Clang importer drops the leading
        // "coordinate" word since it repeats the receiver's own type name).
        let end = start.withOffset(CGVector(dx: distancePoints, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end)
        return true
    }

    /// M9 bug fix follow-up: accepts the `UNUserNotificationCenter`
    /// alert/badge/sound authorization prompt (`"“Otegami” Would Like to
    /// Send You Notifications"` / "Allow" — "許可" if the simulator's
    /// system language happens to be Japanese) that now appears the first
    /// time `PushTokenCenter.requestToken()` runs (`NotificationPermissionResolver`
    /// resolving a `.notDetermined` status — see that type's doc comment).
    /// Same "check the app's own tree first, then springboard" pattern as
    /// `dismissSavePasswordPromptIfNeeded` above, since which process hosts
    /// a given system alert isn't consistent across OS/toolchain versions
    /// on this dev machine (that helper's own doc comment already found
    /// this out for the Keychain AutoFill prompt) — belt-and-suspenders
    /// rather than a guess. A no-op (not a failure) if the prompt never
    /// shows within `timeout`, e.g. a re-run against a simulator install
    /// that's already `.authorized`/`.denied` from an earlier, not-yet-erased
    /// run (iOS never re-prompts once a decision is recorded).
    @discardableResult
    func allowNotificationPermissionIfNeeded(timeout: TimeInterval = 10) -> Bool {
        let app = XCUIApplication()
        let inAppAllow = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Allow", "許可")
        ).firstMatch
        if inAppAllow.waitForExistence(timeout: timeout) {
            inAppAllow.tap()
            return true
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardAllow = springboard.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Allow", "許可")
        ).firstMatch
        if springboardAllow.waitForExistence(timeout: timeout) {
            springboardAllow.tap()
            return true
        }
        return false
    }

    func dismissSavePasswordPromptIfNeeded(timeout: TimeInterval = 3) {
        let app = XCUIApplication()
        let inAppNotNow = app.buttons["Not Now"]
        if inAppNotNow.waitForExistence(timeout: timeout) {
            inAppNotNow.tap()
            return
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardNotNow = springboard.buttons["Not Now"]
        if springboardNotNow.waitForExistence(timeout: timeout) {
            springboardNotNow.tap()
        }
    }

    /// Task #51: a message row rendering its sender (e.g. an avatar lookup)
    /// can trigger iOS's one-time "Allow "Otegami" to access your
    /// contacts?" system prompt (`com.apple.springboard`) asynchronously,
    /// and XCTest's *default* interruption handling — which does fire and
    /// does dismiss it (confirmed via `xcodebuild test`'s own log:
    /// "Default interruption handler attempting to dismiss alert by
    /// tapping 'Continue' Button", "Confirmed successful handling of
    /// interrupting element") — isn't reliably enough for the *specific*
    /// gesture it interrupted to still land correctly afterward if that
    /// gesture happened to be a row tap meant to push message detail: a
    /// press synthesized during exactly this window observably completed
    /// (no error, `app` returns to idle) without the app actually
    /// navigating anywhere, leaving `OtegamiSecurityNoticeDarkModeUITests`
    /// stuck on `messageList.list` for the rest of the test — the same
    /// broad "tap not truly delivered right after a system UI
    /// interruption" class of issue `restartAppToRecoverTouchDelivery`'s
    /// doc comment documents for `.sheet()` dismissal specifically, just
    /// triggered by a different kind of interruption. Rather than
    /// reproducing that heavier terminate+relaunch recovery here, this
    /// gives the async permission check a moment to fire and resolves it
    /// *before* the row tap ever happens, so the tap and the alert can no
    /// longer race — called from `openMessage` right before pressing a row.
    /// A no-op (not a failure) if no such alert shows within `timeout`,
    /// same reasoning as `allowNotificationPermissionIfNeeded`'s doc
    /// comment (e.g. a simulator install where this decision is already
    /// recorded from an earlier, not-yet-erased run never re-prompts).
    func dismissContactsPermissionPromptIfNeeded(timeout: TimeInterval = 3) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dismissButton = springboard.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@ OR label == %@ OR label == %@", "Continue", "OK", "Allow", "許可")
        ).firstMatch
        if dismissButton.waitForExistence(timeout: timeout) {
            dismissButton.tap()
        }
    }

    /// Opens the account-setup sheet, fills in the dev mailstack's `test1`
    /// Dovecot credentials, runs (and asserts) the connection test, and
    /// saves — leaving the sheet dismissed and initial sync kicked off.
    func addDovecotTest1Account(in app: XCUIApplication) {
        openAccountSetup(in: app)
        fillDovecotAccountForm(in: app)
        runConnectionTest(in: app)
        saveAccount(in: app)
        dismissSavePasswordPromptIfNeeded()
    }

    /// M9 bug fix follow-up (`docs/verify.md`'s "M9 追補" section,
    /// `PENDING.md`): drives "設定 → プッシュ通知 → 有効にする" far enough to
    /// trigger `PushTokenCenter.requestToken()`'s new
    /// `UNUserNotificationCenter.requestAuthorization(...)` call and accept
    /// the resulting system prompt (`allowNotificationPermissionIfNeeded`) —
    /// the goal is the *side effect* (this simulator install's notification
    /// authorization status becomes `.authorized`, which `xcrun simctl
    /// push` requires — see this repo's `scripts/verify-ios-push-simulated.sh`),
    /// not a successful relay registration. The relay URL doesn't need to
    /// be reachable: `AppEnvironment.enablePushNotifications` requests
    /// notification authorization *before* ever making a network call to
    /// the relay, and the simulator's inherent inability to produce a real
    /// APNs device token means the flow always ends in
    /// `AppEnvironment.PushError.noDeviceToken` (a visible, non-crashing
    /// `settings.push.errorMessage`) regardless — expected, and not what
    /// this helper's callers care about.
    ///
    /// A no-op past the URL/enable-button check if push is already enabled
    /// (`settings.push.enableButton` doesn't exist because
    /// `settings.push.disableButton` is showing instead) — e.g. a re-run
    /// against a simulator install this test suite already granted
    /// permission on without an intervening `simctl erase`.
    func grantNotificationPermissionViaPushSettings(in app: XCUIApplication) {
        // 新画面構成: "設定" is reached via the hamburger menu (bottom row,
        // `FolderListSheet.settingsSection`), not a tab bar or a gear-icon
        // sheet off the old sidebar.
        openSettingsFromHamburgerMenu(in: app)
        // 実機フィードバック第3弾 (I): プッシュ通知は「アカウントの設定」
        // カテゴリの下に移動した (旧「その他」カテゴリは廃止 —
        // `AccountsListContent`の doc comment参照)。
        XCTAssertTrue(navigateToAccountSettingsCategory(in: app), "「アカウントの設定」カテゴリへの遷移に失敗した")
        // ラベルテキストではなくアクセシビリティ識別子で検索 — ロケールに
        // 依存しない (`tapPlainSecurityMenuOption(in:)`のドキュメントコメント
        // が記録している「カタログ拡張で既存のラベル検索が壊れる」class の
        // 問題を避ける)。
        let pushLink = app.buttons["settings.pushNotificationsLink"]
        XCTAssertTrue(pushLink.waitForExistence(timeout: 10), "settings screen did not appear")
        pushLink.tap()

        let relayURLField = app.textFields["settings.push.relayURLField"]
        XCTAssertTrue(relayURLField.waitForExistence(timeout: 10), "push settings screen did not appear")

        guard !app.staticTexts["settings.push.enabledLabel"].exists else {
            // Already enabled from an earlier, not-yet-erased run — the
            // permission prompt was already answered then too.
            return
        }

        type("http://localhost:9", into: relayURLField)

        let enableButton = app.buttons["settings.push.enableButton"]
        XCTAssertTrue(enableButton.waitForExistence(timeout: 5))
        XCTAssertTrue(enableButton.isEnabled, "enable button should be enabled once a valid URL is entered")
        enableButton.tap()

        let consentConfirm = app.buttons["settings.push.consentConfirmButton"].firstMatch
        XCTAssertTrue(consentConfirm.waitForExistence(timeout: 10), "expected the credential-sharing consent alert")
        consentConfirm.tap()

        allowNotificationPermissionIfNeeded(timeout: 15)

        // Simulator can't produce a real device token, so this always ends
        // in a visible error message (`.noDeviceToken`) — what matters for
        // this helper's callers is that the OS-level authorization prompt
        // above was answered, not this outcome.
        _ = app.staticTexts["settings.push.errorMessage"].waitForExistence(timeout: 40)
    }

    /// Works around a confirmed simulator/OS defect (found while building
    /// `OtegamiM2VerificationUITests`): after `AccountSetupView`'s
    /// `.sheet()` dismisses, every subsequent synthesized tap/press in this
    /// simulator computes an invalid `{-1, -1}` hit point — reproduced even
    /// for a plain toolbar button, not just `List` rows, so it isn't
    /// specific to this app's view structure. `app.activate()` does *not*
    /// clear it; a full terminate+relaunch does. Call this once, right
    /// after `addDovecotTest1Account`, before any test that needs to tap
    /// something beyond the account-setup sheet itself (M1's test never
    /// taps after that point, which is why it never hit this). The
    /// account/mailbox are already persisted in GRDB, so relaunching
    /// resumes on the same INBOX list with nothing to re-enter.
    /// `legacyAutoAdvanceToContent` (default `true`) passes
    /// `-uiTestsAutoAdvanceToContent` on the relaunch, restoring the
    /// pre-fix "cold launch with an existing account jumps straight to the
    /// message list" shortcut (`OtegamiApp.uiTestsShouldAutoAdvanceToContent`'s
    /// doc comment) — every *existing* caller of this helper wants exactly
    /// that (they're testing something else entirely and just want the
    /// message list reachable without an extra tap), so the default keeps
    /// them all working unchanged. Pass `false` for a test that's
    /// specifically exercising the real cold-launch navigation behavior
    /// itself (`OtegamiColdLaunchAndSidebarSelectionUITests`).
    /// `legacyAutoAdvanceToContent` (and the `-uiTestsAutoAdvanceToContent`
    /// launch argument it passes) predates design-phase-2's iOS tab-bar
    /// restructuring (`OtegamiRootView`) — iOS no longer has a
    /// `NavigationSplitView`/sidebar "column" to auto-advance past at all
    /// (the Mail tab's `MessageListView` is reachable directly, no tap
    /// needed), so this parameter is a no-op on iOS now. Left in place
    /// (rather than removed) since `RootView.uiTestsShouldAutoAdvanceToContent`
    /// still reads it for macOS's still-unchanged `NavigationSplitView`, and
    /// every existing call site here already passes it — harmless either
    /// way.
    func restartAppToRecoverTouchDelivery(_ app: XCUIApplication, legacyAutoAdvanceToContent: Bool = true) {
        app.terminate()
        if legacyAutoAdvanceToContent {
            app.launchArguments += ["-uiTestsAutoAdvanceToContent"]
        }
        app.launch()
    }

    /// Waits for the message list to appear. 新画面構成: iOS no longer has a
    /// bottom tab bar at all — `MailScreenView` (`OtegamiRootView`'s only
    /// child) shows `MessageListView` directly, so there's no "switch back
    /// to the Mail tab" step anymore. The only thing that can keep the list
    /// out of the accessibility tree within an already-running process is
    /// the hamburger drawer being open (`HamburgerMenuContainer` hides the
    /// main content from the accessibility tree while `isOpen`) — closing
    /// it via the drawer's own "閉じる" button covers that case; otherwise
    /// this is a plain wait.
    @discardableResult
    func navigateToUnifiedInboxIfNeeded(in app: XCUIApplication, timeout: TimeInterval = 20) -> Bool {
        let list = app.collectionViews["messageList.list"]
        if list.waitForExistence(timeout: 2) { return true }
        let closeMenuButton = app.buttons["folderSheet.closeButton"]
        if closeMenuButton.waitForExistence(timeout: 3) {
            closeMenuButton.tap()
        }
        return list.waitForExistence(timeout: timeout)
    }

    /// 新画面構成: opens the hamburger menu (`mail.hamburgerButton`) and taps
    /// its bottom "設定" row (`folderSheet.settings`), waiting for
    /// `SettingsSheetView`'s sheet to be up.
    ///
    /// I「設定画面の再構成」の検証中に発見: `settingsRow.tap()`(素の`.tap()`)
    /// が、この simulator/toolchain で確認済みの「スクロールしてから hit
    /// point を計算する内部処理が `{-1, -1}` を返す」既知の不具合
    /// (`.claude/skills/verify/SKILL.md`のM2節) にたまに引っかかり、
    /// `kAXErrorFailure performing AXAction kAXScrollToVisibleAction`で
    /// 失敗することを確認した (同じスクリプト内で複数回`xcodebuild test`を
    /// 呼ぶうちの後の方のフェーズで再現しやすい)。座標ベースの
    /// `.coordinate(...).press(forDuration:)`はこの内部スクロール処理を
    /// 経由しないため、同じ M2 節が他の行タップに対してすでに採用している
    /// 回避策をここにも適用した。
    @discardableResult
    func openSettingsFromHamburgerMenu(in app: XCUIApplication) -> Bool {
        app.buttons["mail.hamburgerButton"].tap()
        let settingsRow = app.buttons["folderSheet.settings"]
        guard settingsRow.waitForExistence(timeout: 10) else { return false }
        settingsRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        return app.otherElements["settingsSheet.navigationStack"].waitForExistence(timeout: 10)
    }

    /// I「設定画面の再構成」: the settings root (`AccountsListContent`) no
    /// longer shows individual controls directly — it's a list of category
    /// links (`settings.category.accounts`/`.mailViewer`/`.mailList`/
    /// `.mailCompose`). Any UITest that used to find a control right after
    /// `openSettingsFromHamburgerMenu(in:)` now needs one extra tap into
    /// the category that control moved to first — these `navigateToXCategory
    /// (in:)` helpers are that one tap, shared by every affected test so
    /// the category identifier string itself lives in exactly one place.
    ///
    /// 実機フィードバック第3弾 (I): the fifth category, "その他"
    /// (`navigateToOtherSettingsCategory(in:)`), was removed along with
    /// `OtherSettingsView` itself — every control that used to live there
    /// moved into one of the four categories below (`AccountsListContent`'s
    /// doc comment has the full mapping), so every caller that used to
    /// navigate to "その他" now navigates to whichever category actually
    /// owns the control it's testing.
    @discardableResult
    func navigateToAccountSettingsCategory(in app: XCUIApplication) -> Bool {
        let link = app.buttons["settings.category.accounts"]
        guard link.waitForExistence(timeout: 5) else { return false }
        link.tap()
        return true
    }

    @discardableResult
    func navigateToMailViewerSettingsCategory(in app: XCUIApplication) -> Bool {
        let link = app.buttons["settings.category.mailViewer"]
        guard link.waitForExistence(timeout: 5) else { return false }
        link.tap()
        return true
    }

    @discardableResult
    func navigateToMailListSettingsCategory(in app: XCUIApplication) -> Bool {
        let link = app.buttons["settings.category.mailList"]
        guard link.waitForExistence(timeout: 5) else { return false }
        link.tap()
        return true
    }

    @discardableResult
    func navigateToMailComposeSettingsCategory(in app: XCUIApplication) -> Bool {
        let link = app.buttons["settings.category.mailCompose"]
        guard link.waitForExistence(timeout: 5) else { return false }
        link.tap()
        return true
    }

    /// 新画面構成: closes `SettingsSheetView`'s sheet (`settingsSheet
    /// .closeButton`) — replaces the design-phase-2 "switch back to the
    /// Mail tab" step now that 設定 is a sheet, not a tab.
    @discardableResult
    func closeSettingsSheet(in app: XCUIApplication) -> Bool {
        let closeButton = app.buttons["settingsSheet.closeButton"]
        guard closeButton.waitForExistence(timeout: 5) else { return false }
        closeButton.tap()
        return true
    }

    /// M4: adds the dev mailstack's second seeded account (`test2
    /// @otegami.test`) — used by the unified-inbox verification, which
    /// needs a second account already present. Assumes `test1` (or no
    /// account at all) is already the Mail tab's state, so `openAccountSetup`
    /// finds whichever of the empty-state/chip-row "add account" buttons is
    /// currently showing.
    func addDovecotTest2Account(in app: XCUIApplication) {
        openAccountSetup(in: app)
        fillDovecotAccountForm(
            in: app,
            displayName: "Dovecot Test2",
            email: "test2@otegami.test",
            username: "test2@otegami.test",
            password: "test1234"
        )
        runConnectionTest(in: app)
        saveAccount(in: app)
        dismissSavePasswordPromptIfNeeded()
    }

    /// Generalized form of `fillDovecotAccountForm(in:)` (below) for any of
    /// the dev mailstack's seeded users, not just `test1`.
    func fillDovecotAccountForm(in app: XCUIApplication, displayName: String, email: String, username: String, password: String) {
        type(displayName, into: app.textFields["accountSetup.displayName"])
        type(email, into: app.textFields["accountSetup.email"])
        type("localhost", into: app.textFields["accountSetup.imapHost"])
        type("1143", into: app.textFields["accountSetup.imapPort"], clearingExisting: true)

        app.buttons["accountSetup.imapSecurity"].tap()
        tapPlainSecurityMenuOption(in: app)

        type(username, into: app.textFields["accountSetup.imapUsername"], clearingExisting: true)
        type(password, into: app.secureTextFields["accountSetup.password"])
    }

    /// M4: pops back one level (detail → content, i.e. `ThreadDetailView`
    /// → `MessageListView`) via the navigation bar's leading button, for
    /// any test that might launch straight into a restored
    /// `ThreadDetailView` (`RootView`'s "last opened thread" `@AppStorage`
    /// restoration, the same mechanism M2 relies on for its offline
    /// checkpoint) rather than the message list. On this simulator/device
    /// ("iPhone 17 Pro Max") `NavigationSplitView` is compact-width —
    /// sidebar → content → detail is a real push stack with a back button
    /// at each level, not a side-by-side layout. A no-op if no back button
    /// is present (already at the message list, or nothing was ever
    /// opened).
    func popBackOnceIfNeeded(in app: XCUIApplication) {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.waitForExistence(timeout: 5) {
            backButton.tap()
        }
    }

    /// 画面構造改修バッチ (Task #33, 1): tapping a thread row no longer
    /// always lands on `ThreadDetailView` directly — a 2+ message thread
    /// now interposes `ThreadSelectionView` first (`ThreadEntryView`'s doc
    /// comment). Several existing QA-sweep-style tests tap "whichever
    /// thread happens to sort first" without asserting a specific subject
    /// (deliberately, to churn-test general resilience rather than one
    /// fixture) and then hard-assert `threadDetail.scrollView` appears —
    /// which thread that turns out to be, and therefore whether it's a
    /// 1- or 2+-message thread, isn't something those tests control. This
    /// waits for *either* screen after a row's already been tapped, and
    /// taps through the first selection row if the selection screen (not
    /// the message body) is what actually came up — so those tests keep
    /// asserting "did opening a thread work at all," the thing they
    /// actually care about, regardless of which screen a given seeded
    /// thread's message count happens to route through this run.
    @discardableResult
    func waitForThreadDetailPossiblyThroughSelectionScreen(in app: XCUIApplication, timeout: TimeInterval = 20) -> Bool {
        let detail = app.scrollViews["threadDetail.scrollView"]
        let selection = app.scrollViews["threadSelection.scrollView"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if detail.exists { return true }
            if selection.exists { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard selection.exists else { return detail.waitForExistence(timeout: 1) }
        let firstSelectionRow = selection.buttons
            .matching(NSPredicate(format: "identifier CONTAINS %@", "threadSelection.message."))
            .firstMatch
        guard firstSelectionRow.waitForExistence(timeout: 5) else { return false }
        firstSelectionRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1)
        return detail.waitForExistence(timeout: timeout)
    }

    /// Like `popBackOnceIfNeeded`, but keeps popping (up to 3 times — the
    /// deepest `MailScreenView`'s own `NavigationStack` gets) until the
    /// hamburger button — the one always-present entry point back to
    /// `MailScreenView`'s root, whether or not any account exists yet — is
    /// reachable, for a test that needs to add another account and can't
    /// assume how many levels deep a restored launch left off at. 新画面構成:
    /// no tab bar to switch back to anymore (design-phase-2's
    /// `returnToSidebarRootIfNeeded` rename already dropped the sidebar
    /// equivalent; this drops the Mail-tab-switch step design-phase-2 itself
    /// added, now that there's only ever one always-visible screen). 実機
    /// フィードバック: this used to also check for the account filter chip
    /// row's trailing "＋" (`mail.chip.addAccount`), removed along with that
    /// chip (`AccountFilterChipRow`'s doc comment) — the hamburger button
    /// alone is a strictly more reliable "am I at the mail root" signal
    /// since it's present regardless of account count.
    func returnToMailTabRootIfNeeded(in app: XCUIApplication) {
        for _ in 0..<3 {
            if app.buttons["mail.hamburgerButton"].exists || app.buttons["mail.addAccountButton"].exists {
                return
            }
            let backButton = app.navigationBars.buttons.element(boundBy: 0)
            guard backButton.waitForExistence(timeout: 3) else { return }
            backButton.tap()
        }
    }

    /// Reaches `AccountTypeSelectionView` — either from the Mail tab's
    /// empty-state button (zero accounts) or, once at least one account
    /// exists, via 設定 →「アカウントの設定」→「アカウントを追加」(実機
    /// フィードバック: the account filter chip row's trailing "＋" that used
    /// to cover this case directly from the mail root was removed — see
    /// `AccountFilterChipRow`'s doc comment; account setup already has an
    /// always-available entry point in Settings, so duplicating it in the
    /// chip row was redundant). Shared by `openAccountSetup(in:)` below and
    /// any test that needs to pick a *different* account type (Gmail/
    /// iCloud) than "その他".
    func openAccountTypeSelection(in app: XCUIApplication) {
        let emptyStateButton = app.buttons["mail.addAccountButton"]
        if emptyStateButton.waitForExistence(timeout: 5) {
            emptyStateButton.tap()
        } else {
            let hamburgerButton = app.buttons["mail.hamburgerButton"]
            XCTAssertTrue(hamburgerButton.waitForExistence(timeout: 10), "Hamburger menu button not found")
            hamburgerButton.tap()

            let settingsButton = app.buttons["folderSheet.settings"]
            XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button not found in folder sheet")
            settingsButton.tap()

            let accountsCategoryLink = app.buttons["settings.category.accounts"]
            XCTAssertTrue(accountsCategoryLink.waitForExistence(timeout: 5), "Accounts settings category link not found")
            accountsCategoryLink.tap()

            let addAccountButton = app.buttons["settings.addAccountButton"]
            XCTAssertTrue(addAccountButton.waitForExistence(timeout: 5), "Add account button not found in account settings")
            addAccountButton.tap()
        }
    }

    /// M6: "add account" now opens `AccountTypeSelectionView` first (plan:
    /// "種別選択: Gmail / iCloud / その他 (IMAP)") rather than jumping straight
    /// into `AccountSetupView` — this taps through to "その他 (IMAP)" so
    /// every M1–M5 test that calls this (via `fillDovecotAccountForm`/
    /// `addDovecotTest1Account`/etc.) keeps working unchanged from here on.
    /// `AccountTypeSelectionView` and `AccountSetupView` are presented as a
    /// single continuous `.sheet(item:)` (see `AccountEntryRoute`'s doc
    /// comment), so there's no intermediate sheet-dismiss animation to wait
    /// out between the two taps below.
    func openAccountSetup(in app: XCUIApplication) {
        openAccountTypeSelection(in: app)

        let otherButton = app.buttons["accountTypeSelection.otherButton"]
        XCTAssertTrue(otherButton.waitForExistence(timeout: 5), "Account type selection sheet did not appear")
        otherButton.tap()

        XCTAssertTrue(app.textFields["accountSetup.displayName"].waitForExistence(timeout: 5), "Account setup sheet did not appear")
    }

    func fillDovecotAccountForm(in app: XCUIApplication) {
        type("Dovecot Test1", into: app.textFields["accountSetup.displayName"])
        type("test1@otegami.test", into: app.textFields["accountSetup.email"])
        type("localhost", into: app.textFields["accountSetup.imapHost"])
        type("1143", into: app.textFields["accountSetup.imapPort"], clearingExisting: true)

        app.buttons["accountSetup.imapSecurity"].tap()
        tapPlainSecurityMenuOption(in: app)

        type("test1@otegami.test", into: app.textFields["accountSetup.imapUsername"], clearingExisting: true)
        type("test1234", into: app.secureTextFields["accountSetup.password"])
    }

    /// M5: adds the `test1` Dovecot account with SMTP fields also filled in
    /// (pointing at the dev mailstack's Mailpit, `localhost:1025`, plain —
    /// see `dev/mailstack/compose.yml`) and runs the SMTP connection test
    /// too, so the saved account can actually send. `addDovecotTest1Account`
    /// (above) intentionally leaves SMTP blank — M1–M4's tests don't need
    /// it, and M1's account form documents SMTP as optional-to-save.
    func addDovecotTest1AccountWithSMTP(in app: XCUIApplication) {
        openAccountSetup(in: app)
        fillDovecotAccountForm(in: app)
        runConnectionTest(in: app)
        fillMailpitSMTPFields(in: app)
        runSMTPConnectionTest(in: app)
        saveAccount(in: app)
        dismissSavePasswordPromptIfNeeded()
    }

    /// Fills the SMTP section with the dev mailstack's Mailpit
    /// (`localhost:1025`, plain). Deliberately leaves `smtpUsername`
    /// blank: Mailpit's EHLO doesn't advertise `AUTH` at all and rejects
    /// an attempt outright, and `OpQueueProcessor.smtpAuth`/
    /// `MailCoreSMTPSession.connect` both treat a blank SMTP username as
    /// "this relay needs no authentication" — see their doc comments.
    func fillMailpitSMTPFields(in app: XCUIApplication) {
        type("localhost", into: app.textFields["accountSetup.smtpHost"])
        type("1025", into: app.textFields["accountSetup.smtpPort"], clearingExisting: true)

        app.buttons["accountSetup.smtpSecurity"].tap()
        tapPlainSecurityMenuOption(in: app)
    }

    /// A「実機フィードバック第2弾」のローカライズ拡張作業中に発見: この開発機
    /// のシミュレータのシステム言語は英語がデフォルトで、`AppLanguageOption
    /// .system`(このアプリの既定設定) はそれにそのまま従うため、
    /// `Localizable.xcstrings`へ`"なし (平文)"`の英訳を追加した瞬間、この
    /// 文字列に依存していた既存のラベルテキスト検索
    /// (`app.buttons["なし (平文)"]`) が「なし (平文)」ではなく「None
    /// (Plain)」を見るようになり、3箇所とも壊れた — カタログの網羅を進める
    /// ほど、ラベル文字列に依存する既存 XCUITest がロケール次第で無言で
    /// 壊れうるという、今後同じ轍を踏まないための教訓。`identifier CONTAINS`
    /// ではなく日本語/英語どちらのラベルにもマッチする`OR`述語にすることで
    /// 両方のロケールで動くようにした。
    func tapPlainSecurityMenuOption(in app: XCUIApplication) {
        let option = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "なし (平文)", "None (Plain)")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "「なし (平文)」/「None (Plain)」のメニュー項目が見つからない")
        option.tap()
    }

    func runSMTPConnectionTest(in app: XCUIApplication) {
        let testButton = app.buttons["accountSetup.testSMTPConnectionButton"]
        XCTAssertTrue(testButton.waitForExistence(timeout: 5), "SMTP test button should exist")
        XCTAssertTrue(testButton.isEnabled, "SMTP test button should be enabled once host/port are filled")
        testButton.tap()

        let result = app.staticTexts["accountSetup.smtpTestResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), "SMTP connection test result did not appear")
        XCTAssertTrue(result.label.contains("成功"), "Expected an SMTP success message, got: \(result.label)")
    }

    func runConnectionTest(in app: XCUIApplication) {
        let testButton = app.buttons["accountSetup.testConnectionButton"]
        XCTAssertTrue(testButton.isEnabled, "Test-connection button should be enabled once the form is filled")
        testButton.tap()

        let result = app.staticTexts["accountSetup.testResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), "Connection test result did not appear")
        XCTAssertTrue(result.label.contains("成功"), "Expected a success message, got: \(result.label)")
    }

    func saveAccount(in app: XCUIApplication) {
        let saveButton = app.buttons["accountSetup.saveButton"]
        XCTAssertTrue(saveButton.isEnabled, "Save button should be enabled after a successful connection test")
        saveButton.tap()

        // The sheet dismisses once the account row + Keychain password are
        // saved; its absence is the signal the save completed.
        XCTAssertTrue(
            app.textFields["accountSetup.displayName"].waitForNonExistence(timeout: 5),
            "Account setup sheet did not dismiss after saving"
        )

        // 実機フィードバック: once at least one account already exists,
        // `openAccountSetup(in:)` reaches this sheet via 設定 →
        // 「アカウントの設定」(the chip row's "＋" that used to add an account
        // without ever leaving the mail root was removed — see
        // `AccountFilterChipRow`'s doc comment). Saving only dismisses this
        // `AccountSetupView` sheet itself, leaving the Settings sheet open
        // underneath — close it too so every caller of `saveAccount(in:)`
        // keeps landing back on the mail root afterward, exactly as it did
        // before that chip was removed.
        let settingsCloseButton = app.buttons["settingsSheet.closeButton"]
        if settingsCloseButton.exists {
            settingsCloseButton.tap()
        }
    }

    /// 下書き lives in `FolderListSheet`'s content, now the hamburger menu's
    /// drawer (`mail.hamburgerButton`) rather than a tappable nav title —
    /// this walks both steps (open the drawer, tap "下書き") and waits for
    /// `DraftsView`'s sheet to be up, so callers can then look for their own
    /// draft rows exactly as before.
    @discardableResult
    func openDraftsList(in app: XCUIApplication) -> Bool {
        returnToMailTabRootIfNeeded(in: app)
        app.buttons["mail.hamburgerButton"].tap()
        let draftsRow = app.buttons["folderSheet.drafts"]
        guard draftsRow.waitForExistence(timeout: 10) else { return false }
        draftsRow.tap()
        return app.otherElements["drafts.sheet"].waitForExistence(timeout: 10)
    }

    /// Same shape as `openDraftsList(in:)`, for "送信待ち" (`OutboxView`).
    @discardableResult
    func openOutboxList(in app: XCUIApplication) -> Bool {
        returnToMailTabRootIfNeeded(in: app)
        app.buttons["mail.hamburgerButton"].tap()
        let outboxRow = app.buttons["folderSheet.outbox"]
        guard outboxRow.waitForExistence(timeout: 10) else { return false }
        outboxRow.tap()
        return app.otherElements["outbox.sheet"].waitForExistence(timeout: 10)
    }

    /// Opens `FolderListSheet`, checks whether its "送信待ち" (`OutboxView`
    /// entry, `folderSheet.outbox`) row is present within `timeout`, then
    /// closes the sheet again before returning — a fresh open/check/close
    /// each call, meant for polling loops (`OtegamiM5OfflineUITests`)
    /// rather than leaving the sheet up across an extended wait.
    @discardableResult
    func folderSheetShowsOutboxRow(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        returnToMailTabRootIfNeeded(in: app)
        app.buttons["mail.hamburgerButton"].tap()
        guard app.collectionViews["folderSheet.list"].waitForExistence(timeout: 10) else { return false }
        let found = app.buttons["folderSheet.outbox"].waitForExistence(timeout: timeout)
        app.buttons["folderSheet.closeButton"].tap()
        return found
    }

    func type(_ text: String, into element: XCUIElement, clearingExisting: Bool = false) {
        element.tap()
        if clearingExisting, let value = element.value as? String, !value.isEmpty {
            let deleteKeys = String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)
            element.typeText(deleteKeys)
        }
        element.typeText(text)
    }
}

extension XCUIElement {
    /// The inverse of `waitForExistence`: polls until the element is gone
    /// (or the timeout elapses), for asserting a sheet dismissed or a
    /// banner was dismissed.
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !exists
    }
}
