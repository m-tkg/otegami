import AccountCloudSync
import Foundation
import OtegamiStore

@MainActor
extension AppEnvironment {
    // MARK: - iCloud account sync (M11)

    /// Real-device contamination fix (`docs/icloud-sync.md`'s "開発用ビル
    /// ドでの iCloud KVS 汚染" section): a developer's own Mac is, by
    /// construction, signed into that developer's *real* Apple ID, and
    /// every local build of this app — the iOS Simulator included — shares
    /// the exact same `com.apple.developer.ubiquity-kvstore-identifier`
    /// (Team ID + bundle id, `Otegami-iOS.entitlements`/
    /// `Otegami-macOS.entitlements`) as the Ad-Hoc-signed build this repo
    /// ships to a real device (`make deploy-ota`). There is no separate
    /// sandboxed/fake iCloud a dev/verify run talks to instead — confirmed
    /// on this dev machine by `cloudd`'s own unified log, which shows real
    /// `"TCC approved access for container containerID=iCloud.com.mtkg
    /// .otegami:Sandbox"` entries firing in lockstep with `xcodebuild test`
    /// (verify-script) runs against the iOS *Simulator*. This is what
    /// actually reseeded a real iPhone with `test1@otegami.test`
    /// ("Dovecot Test1"/"test") every time a verify script or a plain
    /// `make ios` run added that dev-mailstack account: `AccountCloudSync
    /// Engine.reconcile()`'s launch-time push reached the real account's
    /// real iCloud KVS key, not a Simulator-local stand-in.
    ///
    /// The Simulator therefore defaults to **not talking to
    /// `AccountCloudSyncEngine` at all** — this gates every push
    /// (`pushLocalChange`/`pushLocalDeletion`) *and* every pull
    /// (`reconcile()`'s cloud→local phase), since pulling a real account
    /// down into a disposable Simulator database is its own, reverse form
    /// of contamination (`CloudAccountDirectory`'s doc comment). A
    /// developer who genuinely wants to exercise real cloud-sync behavior
    /// on the Simulator (e.g. driving `reconcile()` end-to-end against a
    /// real second "device") can opt back in with the
    /// `-otegamiEnableCloudSyncInSimulator` launch argument.
    ///
    /// `OTEGAMI_UITEST_DISABLE_CLOUD_SYNC` is a second, independent
    /// override in the opposite direction: forces sync off even outside
    /// `targetEnvironment(simulator)` (a `make mac` build driven for UI
    /// verification, say) — belt-and-suspenders alongside the Simulator
    /// default above, matching this file's other `OTEGAMI_UITEST_*`
    /// escape hatches (`init()`'s duplicate-merge/credential-relocation
    /// flags).
    ///
    /// This gate is layer 1 of the fix; layer 2
    /// (`CloudAccountSnapshot.isDevelopmentAccount`) is what protects a
    /// Mac-*native* `make mac`/verify run, which — being neither the
    /// Simulator nor a UI test process — this gate alone can't reach, and
    /// is also what self-heals a cloud payload already contaminated
    /// before this fix shipped. Doesn't affect
    /// `AccountCloudSyncEngineTests`/`AccountCloudSyncSnapshotTests` at
    /// all — those drive the engine directly against an in-memory fake
    /// `UbiquitousStoring`, never through this gate or `AppEnvironment`.
    ///
    /// `nonisolated`: pure `ProcessInfo` reads, no `AppEnvironment` state —
    /// matching `validatedRelayURL`'s reasoning, this has to be callable
    /// from the plain `@Sendable () -> Bool` closure `init()` hands
    /// `AccountCloudSyncEngine` as `isEnabled`, which runs on that engine's
    /// own actor, not `@MainActor`.
    nonisolated static func isCloudSyncPermittedOnThisBuild() -> Bool {
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_DISABLE_CLOUD_SYNC"] == "1" {
            return false
        }
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("-otegamiEnableCloudSyncInSimulator")
        #else
        return true
        #endif
    }

    /// `GeneralSettingsView`'s "iCloud でアカウントを同期" toggle (moved
    /// there from `AccountSettingsCategoryView` by Task #189; the identifier
    /// string above is stale history, not this method's current call site).
    /// Flipping it
    /// on runs a full `reconcile()` immediately (plan: "OFF→ON で full
    /// reconcile") rather than waiting for the next launch/external-change
    /// notification; flipping it off just persists the flag — every
    /// in-flight `accountCloudSync` call already no-ops once
    /// `cloudSyncSettings.isEnabled` reads `false` (`AccountCloudSyncEngine`
    /// reads it fresh on every call, not just at construction time), so
    /// there's nothing further to tear down.
    func setCloudSyncEnabled(_ enabled: Bool) async {
        let wasEnabled = cloudSyncSettings.isEnabled
        cloudSyncSettings.isEnabled = enabled
        setCloudSyncEnabledState(enabled)
        if enabled, !wasEnabled {
            await accountCloudSync.reconcile()
            // Task #89: same toggle, same "just turned back on" trigger —
            // see `settingsCloudSync`'s doc comment for why this piggybacks
            // on the account-sync toggle instead of getting its own.
            await settingsCloudSync.reconcile()
        }
    }

    /// Pushes a locally-added or locally-changed account to iCloud right
    /// away — called after every account-creation flow's local DB insert
    /// (`AccountSetupView`/`ICloudAccountSetupView`/`createGmailAccount`
    /// below) instead of waiting for the next full `reconcile()`.
    func pushAccountToCloud(_ account: AccountRecord) async {
        await accountCloudSync.pushLocalChange(CloudAccountSnapshot(account: account))
    }

    /// Task #186: `pushAccountToCloud`'s counterpart for a locally-added or
    /// -edited signature — called from `SignatureTemplateEditView.save()`
    /// right after its `dbWriter.write` insert/update, instead of waiting
    /// for the next full `templateCloudSync.reconcile()`.
    func pushSignatureToCloud(_ signature: SignatureTemplateRecord) async {
        await templateCloudSync.pushLocalSignatureChange(CloudSignatureSnapshot(record: signature))
    }

    /// Called from `SignatureTemplatesSettingsView.deleteSignature(_:)`
    /// right after the local `deleteOne`.
    func pushSignatureDeletionToCloud(syncId: String) async {
        await templateCloudSync.pushLocalSignatureDeletion(syncId: syncId)
    }

    /// `pushSignatureToCloud`'s counterpart for mail templates (C8) —
    /// called from `TemplateEditView.save()`.
    func pushMailTemplateToCloud(_ template: MailTemplateRecord) async {
        await templateCloudSync.pushLocalMailTemplateChange(CloudMailTemplateSnapshot(record: template))
    }

    /// Called from `TemplatesSettingsView.deleteTemplate(_:)`.
    func pushMailTemplateDeletionToCloud(syncId: String) async {
        await templateCloudSync.pushLocalMailTemplateDeletion(syncId: syncId)
    }
}
