#if os(iOS)
import Foundation
import Intents
import PushRelayClient
import UIKit
import UserNotifications

/// 検証専用フック — iOS Communication Notification (送信者アバター + 右下に
/// アプリアイコンが合成される見た目) を、実際にシミュレータで確認するため
/// だけに存在する。
///
/// **なぜローカル通知経由なのか。** `apps/Otegami/NotificationService/
/// NotificationService.swift` (`UNNotificationServiceExtension`) がこの
/// 機能の本来の実装だが、`docs/verify.md`に記録済みの既知の不調により、
/// この開発機のシミュレータ/ツールチェーンでは `xcrun simctl push` を
/// 受けても Extension プロセスが spawn されず、Extension 経由では見た目を
/// 一切確認できない。`INInteraction.donate()`と`UNNotificationContent
/// .updating(from:)`はどちらも本体アプリのプロセスからでも動作する API
/// なので、本体アプリから同じ形のCommunication Notificationをローカル
/// 通知として1本だけ出し、OSが実際にどう描画するか (アバターの合成、
/// `NEW_MAIL_ACTIONS`のアクションボタン) だけを確認する。
///
/// **`CommunicationNotification.swift`の
/// `CommunicationNotificationBuilder.donate(sender:)`の検証専用の複製。**
/// NotificationService Extension のソースファイルは本体アプリターゲット
/// からimportできない (`OtegamiAppGroup.swift`のdoc comment — 2つの
/// ターゲットは`sources:`ディレクトリを共有しない) ため、`INPerson`/
/// `INSendMessageIntent`の組み立て方 (`INImage(url:)`を`imageData:`ではなく
/// 使う理由を含む) をここへそのまま複製している。**本体側の実装を変えた
/// ら、この複製も合わせて直すこと。**
///
/// `OTEGAMI_UITEST_VERIFY_COMMUNICATION_NOTIFICATION`という検証専用の
/// 起動環境変数が立っている場合にのみ動作する — 他の`OTEGAMI_UITEST_*`
/// フラグ (`UITestSeeder.swift`等) と同じ、通常起動では一切参照されない
/// エスケープハッチのパターン。`runIfRequested()`は`OtegamiApp.swift`の
/// `RootView.body`の`.task`から呼ばれる。
enum CommunicationNotificationVerify {
    /// この検証フックそのものの起動フラグ。`1`のときだけ動作する。
    static let flagName = "OTEGAMI_UITEST_VERIFY_COMMUNICATION_NOTIFICATION"

    /// 架空の差出人 — public リポジトリのため実名・実メールアドレスは
    /// 使わない (`CLAUDE.md`参照、`example.com`+架空の日本語人名)。
    private static let fakeSenderAddress = "hanako@example.com"
    private static let fakeSenderDisplayName = "山田花子"
    private static let fakeSubject = "明日の定例会について(仮)"
    private static let notificationIdentifier = "verify-communication-notification"

    /// フラグが立っていなければ即座に返る — 通常のあらゆる起動(製品ビルド
    /// はもちろん、他の全ての検証シナリオ・UITestを含む)ではこの関数は
    /// 何もしない。
    static func runIfRequested() async {
        guard ProcessInfo.processInfo.environment[flagName] == "1" else { return }

        // 実際の通知許可フローと同じAPI呼び出し — このフラグの下でしか
        // 呼ばれないので、製品ビルドの通知許可タイミングには影響しない。
        // `PushNotificationSettingsView`経由の本来のフロー (リレーURLが
        // ビルドに埋め込まれている必要がある) を経由せずに済むよう、ここで
        // 直接`.alert`込みで要求する。
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])

        // `AppDelegate.application(_:didFinishLaunchingWithOptions:)`が
        // 毎回登録しているはずだが、このタスクの実行順序に依存させたくない
        // ので念のためここでも登録しておく — 「既読にする」「アーカイブ」
        // ボタンがCommunication Notificationでも出るかどうかがこの機能の
        // 最大の検証ポイントのひとつ。
        PushNotificationActionCategory.registerPushNotificationCategories()

        guard let avatarFileURL = writeFakeAvatar() else { return }

        // `NotificationService.conversationIdentifier(accountId:senderAddress:)`
        // と同じ「アカウント×送信者アドレスで1本」という設計を踏襲 — ここでは
        // 実アカウントが無いので固定のプレフィックスにしている。
        let conversationIdentifier = "verify/\(SharedAvatarStore.normalize(fakeSenderAddress))"

        let handle = INPersonHandle(value: fakeSenderAddress, type: .emailAddress)
        let person = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: fakeSenderDisplayName,
            image: INImage(url: avatarFileURL),
            contactIdentifier: nil,
            customIdentifier: nil,
            isContactSuggestion: false,
            suggestionType: .none
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: nil,
            conversationIdentifier: conversationIdentifier,
            serviceName: nil,
            sender: person,
            attachments: nil
        )
        intent.setImage(INImage(url: avatarFileURL), forParameterNamed: \.sender)

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do {
            try await interaction.donate()
        } catch {
            // 実装の`CommunicationNotificationBuilder.donate(sender:)`と
            // 同じく best-effort — donationが失敗したら通知は出さない
            // (装飾できないまま出しても検証の役に立たない)。
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Otegami"
        content.body = "\(fakeSenderDisplayName): \(fakeSubject)"
        content.categoryIdentifier = PushNotificationActionCategory.categoryIdentifier
        content.threadIdentifier = conversationIdentifier
        content.sound = .default
        content.userInfo = ["verify": "communicationNotification"]

        let finalContent: UNMutableNotificationContent
        if let updated = try? content.updating(from: intent),
           let mutable = updated.mutableCopy() as? UNMutableNotificationContent {
            // `NotificationService.decoratedContentIfAvailable(from:)`と同じ
            // 注意点 — `updating(from:)`はカテゴリ/userInfoの引き継ぎを
            // 保証しないので、再度明示的に上書きする。
            mutable.categoryIdentifier = PushNotificationActionCategory.categoryIdentifier
            mutable.threadIdentifier = conversationIdentifier
            mutable.userInfo = content.userInfo
            finalContent = mutable
        } else {
            finalContent = content
        }

        // 起動から数秒後に発火させる — スクリプト側がその間にアプリを
        // バックグラウンドへ送ることで、フォアグラウンドだとバナーが
        // 出ない (または見た目が異なる) 問題を避ける。
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 6, repeats: false)
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: finalContent, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// 単色の丸をコードで生成し`SharedAvatarStore`へ書き込む — 連絡先/
    /// Google/Gravatar/BIMIのどれも使わない、検証専用のダミーアバター。
    /// 中央に白い円を重ねているのは、通知に実際に合成された画像だと
    /// スクリーンショット上で一目でわかるようにするため。
    private static func writeFakeAvatar() -> URL? {
        guard let store = SharedAvatarStore(appGroupIdentifier: OtegamiAppGroup.identifier) else { return nil }
        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemPink.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            let inset: CGFloat = 34
            context.cgContext.fillEllipse(in: CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2))
        }
        guard let pngData = image.pngData(), store.write(pngData, for: fakeSenderAddress) else { return nil }
        return store.imageURL(for: fakeSenderAddress)
    }
}
#endif
