# プッシュ通知のアクション（既読にする／アーカイブ）

プッシュ通知（`docs/relay-deployment.md`）を長押し、または左スワイプした
際に表示される「既読にする」「アーカイブ」ボタンから、アプリを開かずに
メールを操作できる機能。全体のプッシュ通知の仕組み（silent push →
`NotificationService` Extension による内容の書き換え）は
[`docs/relay-deployment.md`](relay-deployment.md) を参照。本ドキュメントは
「通知アクションのボタンをタップしたときに何が起きるか」だけを扱う。

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

## 実機での確認ポイント

自動検証（シミュレータの既知不調、特に XCUITest のタップ不達 — 
`docs/verify.md` 参照）が難しい領域のため、実機での確認をユーザー側で
行う:

1. 新着メールの通知を長押し、または左スワイプすると「既読にする」
   「アーカイブ」ボタンが表示されること。
2. いずれかをタップした後、アプリを開かずに通知が消え、アプリを開くと
   該当メールが既読/アーカイブ済みになっていること。
3. 機内モード等オフライン状態でタップした場合、その場では反映されなくても
   オンライン復帰後（アプリをフォアグラウンドに戻す等）に反映されること。
