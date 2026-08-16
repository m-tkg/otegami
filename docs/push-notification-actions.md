# プッシュ通知のアクション（既読にする／アーカイブ／タップで開く）

プッシュ通知（`docs/relay-deployment.md`）を長押し、または左スワイプした
際に表示される「既読にする」「アーカイブ」ボタンから、アプリを開かずに
メールを操作できる機能と、通知本体をタップしてアプリを開いた際に該当
メールへ直接遷移する機能。全体のプッシュ通知の仕組み（silent push →
`NotificationService` Extension による内容の書き換え）は
[`docs/relay-deployment.md`](relay-deployment.md) を参照。本ドキュメントは
「通知をタップ／操作したときに何が起きるか」だけを扱う。

## 仕組み

1. **カテゴリ指定（push relay側）**: `server/otegami-relay-go/internal/push/apns.go`
   が APNs ペイロードの `aps.category` に固定文字列 `NEW_MAIL_ACTIONS` を
   積む。
2. **カテゴリ/アクションの登録（アプリ起動時）**:
   `apps/Otegami/Sources/Support/PushNotificationActionCategory.swift` が
   同じ識別子 `NEW_MAIL_ACTIONS` で `UNNotificationCategory` を、
   `MARK_READ`/`ARCHIVE` の2つの `UNNotificationAction`（いずれも
   `options: []` — バックグラウンド実行、アプリを前面に出さない）を
   `UNUserNotificationCenter.setNotificationCategories(_:)` に登録する。
   `AppDelegate.application(_:didFinishLaunchingWithOptions:)`
   （`apps/Otegami/Sources/Support/PushTokenCenter.swift`）から毎起動時に
   呼ばれる。
3. **アクションのハンドリング**: 同じ `AppDelegate` が
   `UNUserNotificationCenterDelegate` に準拠し、
   `userNotificationCenter(_:didReceive:withCompletionHandler:)` で
   `actionIdentifier` が `MARK_READ`/`ARCHIVE` の場合のみ、通知の
   `userInfo`（`accountId`/`uidNext`）を取り出して
   `PushNotificationActionHandler.handle(action:accountId:uidNext:)`
   （`apps/Otegami/Sources/Support/PushNotificationActionHandler.swift`）
   へ処理を委譲する。
4. **実行本体**:
   `PushNotificationActionHandler` は共有 App Group の `AppDatabase` を
   開き、この端末の Keychain/OAuth トークンストアから資格情報を解決した
   うえで、`SyncEngine` の
   `PushNotificationActionExecutor.execute(...)`
   （`packages/OtegamiKit/Sources/SyncEngine/PushNotificationActionExecutor.swift`）
   を呼ぶ。この関数がドメインロジック本体:
   - 対象メッセージ（後述）がローカル DB に既に同期済みなら、通常の
     スワイプ操作と同じ `MessagePinReadState.applyReadState`/
     `MessageRemoval.commit(.archive, ...)` を使う（ピン留めメールへの
     アーカイブがブロックされる等、既存の安全策もそのまま効く）。
   - 未同期なら、`mailboxId`/`uidValidity`/`uid` を直接指定して
     `opQueue` に enqueue する。既読化はこの場合
     **`FlagOp.add`（IMAP `+FLAGS`）** で送信する
     （`OpQueue.enqueueSetFlags(..., op: .add, ...)`） — ローカルに情報の
     無いメッセージへ `\Seen` だけを絶対値（`FlagOp.replace`）で送ると、
     サーバー側の `\Answered`/`\Flagged` 等の既存フラグを消してしまう
     ため。通常のUI操作（既にローカルに全フラグ情報がある場合）は従来
     どおり絶対値（`.replace`、デフォルト）のまま。
   - ローカル DB への反映（上記のいずれか）は同期的に確定させ、実際の
     IMAP への反映（`OpQueueProcessor` の replay）は**ベストエフォート**
     で1回だけ試みる。失敗しても、次回のフォアグラウンド復帰や IDLE
     wake が通常どおり `opQueue` を replay するため、通知アクションの
     ハンドラ自体はネットワーク到達性を気にする必要がない
     （オフラインファーストの設計、`docs/architecture.md` 参照）。

## 送信者アバター通知（Communication Notification）

新着メールの通知を、送信者のアバターがある場合に限り OS が丸い画像 +
右下に小さくアプリアイコンを重ねて描く形（iOS の Communication
Notification）に装飾する機能。この節では「装飾がどう実現されているか」と
「装飾が上記のアクション・タップ遷移を壊さないための設計」だけを扱う —
判定ロジック本体・アバターの正規化・共有キャッシュの実装コメントは
`apps/Otegami/NotificationService/CommunicationNotification.swift` と
`packages/OtegamiKit/Sources/PushRelayClient/SharedAvatarStore.swift` が
より詳しい一次情報。

1. **装飾の仕組み**: `NotificationService` が送信者を `INPerson` として
   持つ `INSendMessageIntent` を組み立て、`INInteraction(direction:
   .incoming).donate()` してから `deliver()` の中で
   `content.updating(from:)` を適用する。donate が成功していない intent を
   `updating(from:)` に渡すことはない。
2. **アバターの入手経路**: NSE は自分でアバターを解決しない — アプリ本体が
   一覧描画のために解決したアバター（`docs/design-system.md`「アカウント
   色とアバター」参照）を `MirroringAvatarImageResolver` が 128×128 の
   不透明 PNG に正規化し、App Group 共有ディレクトリ（`SharedAvatarStore`）
   へ書き出す。NSE 側で解決し直す案（Contacts の権限ダイアログを出せない・
   プッシュのたびに外部通信が発生する・5秒の表示バジェットを食う）は
   採らなかった。共有キャッシュにエントリが無ければ intent を作らず、
   従来どおりのアプリアイコン通知のまま配信する（アバターが無い場合に
   イニシャル画像を描く案は採らなかった、明示的な決定）。
3. **`INImage` はファイル URL で渡す**: `INImage(imageData:)` ではなく
   `INImage(url:)` に共有ディレクトリ内のファイル URL を渡す — 前者は
   Debug では動くが Release/TestFlight ビルドでは内部の
   `intents-remote-image-proxy` の生成に失敗しアバターが出なくなる既知の
   不具合があるため（詳細は `docs/architecture.md` の Known pitfalls
   参照）。共有ファイルは `.completeFileProtectionUntilFirstUserAuthentication`
   で書き込む — 既定の保護クラスのままだと端末ロック中に NSE がファイルを
   読めず「ロック画面の通知にだけアバターが出ない」状態になるため。
4. **既存のアクション・タップ遷移を壊さないための再代入**:
   `content.updating(from:)` がどのプロパティを保持するかは Apple が保証
   していないため、装飾後に `userInfo`（上記「対象メッセージの解決」が
   読む）・`categoryIdentifier`（`NEW_MAIL_ACTIONS` — これが無いと「既読に
   する」「アーカイブ」ボタン自体が表示されない）・`badge`・`sound` を
   無条件で再代入する。これを怠ると、見た目は正しく装飾されているのに
   通知アクションとタップ遷移だけが静かに壊れる、という発見しづらい不具合
   になる。装飾は常にベストエフォートで、`updating(from:)` が throw した
   場合は装飾前の内容（＝この節の対象外、通常のアクション/タップ遷移が
   そのまま効く内容）がそのまま配信される。
5. **グルーピング**: `threadIdentifier` に会話識別子
   (`"<accountId>/正規化した差出人アドレス"`) を入れ、同じ差出人からの
   連続した通知を OS が Notification Center 上でまとめて表示する。スレッド
   単位にしていない理由は、push のエンベロープ時点では対象メッセージの
   `threadId` がまだ分からず、Apple が要求する「会話識別子は不変」を
   満たせないため。
6. **設定との連動**: 「差出人を表示」(`notification.showsSender`、下記
   「通知の内容」) と「送信者のプロフィールアイコンを表示」
   (`listDisplay.showAvatar`、`docs/settings.md`「一覧・表示」節) の
   どちらかが OFF ならアバターを出さない。後者は本来一覧の設定だが、
   `MailListSettingsView` の変更時に `NotificationContentSettingsStore
   .mirrorToAppGroup()` を呼んで App Group へミラーし、NSE がそれを読む。
7. **entitlement**: `com.apple.developer.usernotifications.communication`
   を `Config/Otegami-iOS.entitlements`/`Otegami-iOS-MailClient.entitlements`
   に追加（macOS には追加していない — Communication Notifications は
   iOS/iPadOS 限定の機能で、`NotificationService` 自体も iOS 限定の
   Extension のため）。**Developer Portal で App ID の Communication
   Notifications capability を有効化しないと署名が通らない**
   (`docs/xcode-cloud.md`/`docs/release.md` 参照)。
8. **診断**: `PushDiagnosticsRun.Stage.communicationNotification` が
   端末内診断画面に「送信者アバター通知」として出る。`.skipped(reason:)`
   は "showsSender off" / "showAvatar off" / "no sender address" /
   "avatar cache miss" を区別する — 実機でしか検証できない機能のため、
   これが唯一の手がかりになる。

## 通知本体タップ（アプリを開いて該当メールへ遷移）

通知の「既読にする」「アーカイブ」ボタンではなく、通知本体（バナー／
通知センターの行そのもの）をタップした場合の挙動。デフォルトの
`actionIdentifier`（`UNNotificationDefaultActionIdentifier`）としてアプリ
が起動または前面化した際、対象メールのスレッド詳細画面へ自動的に遷移
する。

1. **対象メッセージの解決**: `AppDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`
   （`apps/Otegami/Sources/Support/PushTokenCenter.swift`）が
   `actionIdentifier == UNNotificationDefaultActionIdentifier` を検知すると、
   `PushNotificationActionHandler.resolveOpenTarget(accountId:uidNext:)`
   （`apps/Otegami/Sources/Support/PushNotificationActionHandler.swift`）
   経由で `SyncEngine` の
   `PushNotificationActionExecutor.fetchAndResolveOpenTarget(accountId:uidNext:database:auth:sessionFactory:)`
   （`packages/OtegamiKit/Sources/SyncEngine/PushNotificationActionExecutor.swift`）
   を呼ぶ。対象メッセージの特定方法（`uid = uidNext - 1` の推測、INBOX
   固定）は上記「既読にする／アーカイブ」と同じ。
2. **未同期メッセージの優先取得**: 対象メッセージがまだローカル DB に
   同期されていない場合、`fetchAndResolveOpenTarget` はその場でこの
   アカウントの INBOX だけを対象にした差分同期（`SyncCoordinator
   .syncAccountIncrementally(scope: .inboxOnly)`）を1回試み、完了後に
   再度対象メッセージの解決を試みる。これは `OtegamiApp
   .syncAllAccountsOnce()`（起動時の全アカウント・全メールボックス同期）
   を待たない、独立した優先取得経路 — 通知をタップしてから他の通信より
   先に対象メールだけを読み込むための仕組み。資格情報が解決できない、
   同期そのものが失敗する、同期後も対象 UID が見つからない場合は `nil`
   が返り、遷移は行わない（通常どおり統合受信トレイが表示されるだけ）。
   **`didReceive` の `completionHandler()` はこの解決を待たずに即座に
   呼ぶ**（v1.3.8 のクラッシュ修正、次項「既知の制限」の直下参照）—
   `resolveOpenTarget`/`fetchAndResolveOpenTarget` は `completionHandler()`
   を呼んだ後も別 `Task` として継続し、完了後に `setPendingTarget` する。
3. **SwiftUI 側への橋渡し**: `AppDelegate` は `AppEnvironment`（SwiftUI
   `App` の `@State`）に直接アクセスできないため、
   `PushNotificationOpenCoordinator`
   （`apps/Otegami/Sources/Support/PushNotificationOpenCoordinator.swift`）
   という共有 shared singleton（`PushTokenCenter`/`BadgeCenter` と同じ
   パターン）を仲介させる。解決した `threadId`/`messageId` をここに積み、
   `MailScreenView`（`apps/Otegami/Sources/Features/Root/MailScreenView.swift`）
   が起動時の `.task`（コールドスタート — アプリが未起動の状態で通知を
   タップした場合）と、
   `PushNotificationOpenCoordinator.didUpdateNotification` の
   `.onReceive`（ウォームスタート — アプリ起動中に通知をタップした場合）
   の両方でこれを消費し、`selectedRoute` へ反映してスレッド詳細画面へ
   遷移する。

## 既知の制限

- **操作対象は「push が届いた時点での INBOX 最新1通」の推測**:
  push ペイロードはプライバシー設計上 `accountId`/`uidNext` のみを運び、
  メッセージを一意に特定する情報（UID そのものや message-id）を持たない
  （`docs/relay-deployment.md` 参照）。`NotificationService` Extension が
  通知本文を書き換える際と同じ `uid = uidNext - 1` という推測で対象を
  特定する。1回の push に複数の新着メールがまとまって届いた場合、
  通知アクションは最新の1通のみに作用する。
- **監視対象は INBOX のみ**: push watch はメールボックスを INBOX に
  固定して作成される（`CreateWatchRequest(..., mailbox: "INBOX")`）ため、
  他フォルダの新着メールに対する通知アクションはそもそも発生しない。
- **push リレーを運用していないビルドでは使えない**: プッシュ通知機能
  自体がビルド時設定に依存するオプション機能のため
  （`docs/relay-deployment.md` の「未設定時の挙動」参照）、この通知
  アクションも同様に無効になる。
- **オフライン時は即座に反映されない**: 上記のとおりローカル DB への
  反映は即座に行われるが、実際の IMAP サーバーへの反映は次のオンライン
  復帰を待つ（ベストエフォート replay が失敗した場合）。
- **純粋な背景起動のまま終わる場合、ローカル DB への反映自体が失敗する
  ことが稀にある**: 実クラッシュ調査 (TestFlight v1.14.1, 0xDEAD10CC) の
  副作用 — アプリは `.background`/`.inactive` を観測した瞬間に GRDB の
  suspend 通知を積極的に post するようになった (`docs/architecture.md`の
  Known pitfalls e. 追記参照)。この post が通知アクション自身のローカル
  DB write と競合すると、その write が `SQLITE_INTERRUPT`/`SQLITE_ABORT`
  で失敗しうる。`PushNotificationActionExecutor.execute`はこの場合を検知
  して数回だけ短い間隔で書き込みを再試行する
  (`applyWithSuspensionRetry`) が、この起動中に一度も`.active`へ遷移しない
  純粋な背景起動 (通知アクションの通常ケース) では resume 通知が来ない
  ため、サスペンションが解消されずリトライも尽きる可能性が残る — その
  場合、ボタン操作そのものが（ローカル・サーバーどちらにも）反映され
  ないまま黙って失われる。発生頻度は実機観測で未確認 (このリトライを
  追加した時点でまだ再現条件を意図的に作れていない) — 今後実機で「既読
  にする/アーカイブがロック画面から効かないことがある」という報告が
  あれば、まずこの経路を疑うこと。
- **通知本体タップの遷移は優先取得後も見つからない場合は発生しない**:
  上記「通知本体タップ」節のとおり、未同期メッセージへは INBOX 限定の
  優先同期を1回試みるが、それでも対象メッセージが見つからない場合
  （push 到達から実際のメール到着までのタイムラグが大きい、対象メール
  ボックスが INBOX でない等）は遷移せず、通常どおり統合受信トレイが
  表示される。
- **送信者アバター通知は実機未検証**: 特に「装飾後もアクションのボタンが
  表示され動くか」（上記「送信者アバター通知」節4） が最大のリスク —
  `content.updating(from:)` 適用後の再代入は実装上の対策であり、実機での
  最終確認は行っていない。
- **`RELAY_CONTENT_PREVIEW` が off のリレーではアバターが出にくい**:
  NSE が差出人を知るのが IMAP 同期後になり、5秒の表示バジェットに間に
  合わない可能性が高いため（`docs/relay-deployment.md`「アプリ側の挙動
  (NSE のリレー先読み統合)」参照）。
- **一度も一覧で解決していない差出人（コールドミス）はアバターが出ない**:
  共有キャッシュはアプリ本体の一覧描画がトリガーなので、一覧で一度も
  表示していない差出人からの初回メールにはエントリが無い。受信トレイ
  最新 N 件の差出人を同期後に先読みするプリウォームは検討したが、この
  機能の第一段階では見送った。
- **「送信者のプロフィールアイコンを表示」は他デバイスへ同期されない**:
  `AppSettingsCloudDirectory` の settings.v2 allowlist に含まれていない
  ため（既存の仕様、今回の変更では対象にしていない）。
- **`INPerson` の連絡先候補への露出**: `isContactSuggestion: false`/
  `suggestionType: .none` で作っており Siri/共有シート/集中モードの
  連絡先候補への露出を抑えているはずだが、数日運用しての確認が必要。

### v1.3.8 の実機クラッシュと修正（v1.3.9）

v1.3.8（INBOX優先同期の初回導入）で、通知本体タップ直後に
`UIApplication._updateStateRestorationArchiveForBackgroundEvent:...` の
内部アサーションで実機クラッシュする不具合が報告された
（`EXC_CRASH`/`SIGABRT`、クラッシュ時 `procRole` は `Foreground`）。原因:
`didReceive(...):withCompletionHandler:` の `completionHandler()` を、
IMAP接続を伴いうる `resolveOpenTarget`（優先同期込み）の完了まで待って
から呼んでいた。通知本体タップは同時に (1) アプリをフォアグラウンド
起動させつつ、(2) `UNUserNotificationCenter` 視点では
`completionHandler()` が呼ばれるまで「バックグラウンド通知処理」が
継続中という状態になる。IMAP接続で数秒かかる間この2つの状態が併存し、
UIKit 側のフォアグラウンド/バックグラウンド状態保存処理と競合して
クラッシュしたと推測される。

v1.3.9 で修正: 通知本体タップの分岐だけ `completionHandler()` を即座に
呼ぶよう変更し、対象解決（優先同期含む）はその後も別 `Task` として
継続する設計にした（`PushTokenCenter.swift` の該当メソッドの doc
comment参照）。「既読にする」「アーカイブ」ボタン側（アプリを
フォアグラウンドに出さない）は影響を受けないため、従来どおり処理完了を
待ってから `completionHandler()` を呼ぶ実装のまま。

## 実機での確認ポイント

自動検証（シミュレータの既知不調、特に XCUITest のタップ不達 — 
`docs/verify.md` 参照）が難しい領域のため、実機での確認をユーザー側で
行う:

1. 新着メールの通知を長押し、または左スワイプすると「既読にする」
   「アーカイブ」ボタンが表示されること。
2. いずれかをタップした後、アプリを開かずに通知が消え、アプリを開くと
   該当メールが既読/アーカイブ済みになっていること。
2a. **本命 (実クラッシュ調査 TestFlight v1.14.1, 0xDEAD10CC)**: アプリを
   （バックグラウンドではなく）**完全に終了させた**状態でロック画面上の
   新着メール通知を長押しし、「既読にする」または「アーカイブ」を数回
   連続でタップしてもアプリがクラッシュしないこと。実クラッシュはこの
   操作 (通知アクションによる背景冷間起動) から数秒後に発生していた —
   `docs/architecture.md`のKnown pitfalls e.追記参照。
3. 機内モード等オフライン状態でタップした場合、その場では反映されなくても
   オンライン復帰後（アプリをフォアグラウンドに戻す等）に反映されること。
4. アプリが完全に終了している状態で新着メールの通知本体をタップすると、
   アプリが起動し該当メールのスレッド詳細画面が直接表示されること
   （統合受信トレイ経由でのタップ操作なしで）。
5. アプリがバックグラウンドで起動中の状態で新着メールの通知本体を
   タップした場合も、同様に該当メールのスレッド詳細画面へ遷移すること。
6. 通知が届いた直後、まだメッセージがローカルに同期されていない状態で
   タップした場合も、INBOX の優先同期が走ったうえで該当メールのスレッド
   詳細画面へ遷移すること（同期に数秒かかる分、遷移が少し遅れることは
   ある）。優先同期後も対象メッセージが見つからない場合（例: push 到達
   から実際のメール到着までのタイムラグが極端に大きい）は、遷移せず
   統合受信トレイが表示されること。
7. 送信者のアバターが解決済みの相手からの新着メール通知に、丸いアバター
   画像が表示され、その右下に小さくアプリアイコンが重なっていること。
8. 一度も一覧で表示していない差出人（コールドミス）からの新着メールは、
   従来どおりのアプリアイコンだけの通知になること。
9. アバター付きの通知でも「既読にする」「アーカイブ」ボタンが表示され、
   タップすると通常どおり動作すること（上記「送信者アバター通知」節4の
   最大のリスク）。
10. アバター付きの通知本体をタップした場合も、該当メールのスレッド詳細
    画面へ通常どおり遷移すること。
11. アプリアイコンの未読バッジが正しく反映されること。
12. 端末がロックされている状態でも、ロック画面の通知にアバターが表示
    されること（表示されない場合はファイル保護クラスの設定を疑う）。
13. 同じ差出人から連続して新着メールが届いた場合、通知が1つにグルー
    ピングされること。
14. 設定の「差出人を表示」または「送信者のプロフィールアイコンを表示」
    をオフにすると、以後の通知にアバターが出なくなること。
15. TestFlight (Release 署名) で配布したビルドでもアバターが表示される
    こと — Debug ビルドだけで確認して満足しないこと（`INImage(imageData:)`
    の既知の不具合が Release 限定で再現するため、上記「送信者アバター
    通知」節3参照）。
