# PENDING — ユーザー対応待ち事項

このファイルは、開発を進める上でユーザー本人の判断・手動作業が必要になった項目を記録する。
実装は各項目をモック/スキップ/dev mailstack 代替で進めており、開発の手を止めていない。
都合の良いときに対応し、必要であれば `Config/Local.xcconfig` 等の git 管理外ファイルに値を設定すること。

## M6: Google OAuth Client ID の発行

**実装状況**: M6 のロジック・UI は実装済み・単体テスト済み (PKCE 生成/token
交換/refresh/invalid_grant→要再認証を `URLProtocol` スタブ + `FakeAuthorizationFlow`
でモック検証、`make test` に含まれる `GoogleOAuthTests`)。**残っているのは
実 Google アカウントでの最終確認のみ。** 詳細手順は `docs/oauth-setup.md`
にまとめた。

- **理由**: Gmail 連携は OAuth2 (PKCE) で行うが、OSS のためリポジトリに Client ID を含めない方針。
  ビルドする人が各自 Google Cloud Console で Client ID を発行する必要がある。
- **ブロックしている機能**: Gmail アカウントの追加・同期・送受信の**実サービスでの動作確認**
  (コード自体は実装済み。`AccountTypeSelectionView` の Gmail ボタンは
  `GOOGLE_OAUTH_CLIENT_ID` 未設定の間ずっと無効化され続ける)。
- **対応手順** (`docs/oauth-setup.md` に詳細版あり):
  1. [Google Cloud Console](https://console.cloud.google.com/) で新規プロジェクトを作成する。
  2. 「OAuth 同意画面」を設定する (テストモードで良い。自分の Google アカウントを
     テストユーザーに追加すれば審査不要。審査は作者配布ビルドのみ必要)。
  3. 「認証情報」→「OAuth クライアント ID」で **iOS アプリ**タイプ (シークレット不要) を作成し、
     Bundle ID (`com.m-tkg.otegami`) を指定する。リダイレクト URI は Google Cloud
     Console 側への個別登録が不要 (`docs/oauth-setup.md` の該当節参照)。
  4. 発行された Client ID を `apps/Otegami/Config/Local.xcconfig` に設定する
     (`cp apps/Otegami/Config/Local.xcconfig.sample apps/Otegami/Config/Local.xcconfig`
     の上で追記)。
  5. `make ios` で再ビルドし、「アカウントを追加」→「Gmail」ボタンが有効になっている
     ことを確認する。
  6. 実際に Google でログインし、アカウント追加・INBOX 同期・送信 (Sent への
     二重保存が起きないこと)・アクセストークン失効後の自動リフレッシュ・
     Google 側でのアクセス取り消し後に「再認証」バナーから復旧できることを
     確認する (`docs/oauth-setup.md` の「実機での最終確認手順」に詳細チェック
     リストあり)。

## M6: iCloud App 用パスワードでの実アカウント確認

- **理由**: iCloud (`ICloudAccountSetupView`) は `imap.mail.me.com`/
  `smtp.mail.me.com` への実接続が必要で、dev/mailstack (Dovecot/Mailpit) では
  代替できない。実装・単体テストは完了しているが、実 iCloud アカウントでの
  接続テストは未実施。
- **ブロックしている機能**: iCloud アカウントでの実際の送受信確認 (フォーム自体の
  UI・プリセット値は `scripts/verify-ios-m6.sh` で自動確認済み)。
- **未確定事項**: IMAP/SMTP のユーザー名をメールアドレスの**フル**
  (`user@icloud.com`) で実装したが、iCloud が短縮形 (`user` のみ) も/のみ
  受け付けるかは実アカウントでの確認が必要 (`ICloudAccountSetupView` のドキュ
  メントコメント参照)。フルアドレスで失敗する場合は `imapUsername`/
  `smtpUsername` の組み立てを短縮形に切り替える (影響範囲はこの1ファイルの
  数行のみ)。
- **対応手順**:
  1. [appleid.apple.com](https://appleid.apple.com/account/manage) で
     「App 用パスワード」を発行する (iCloud のログインパスワードそのもの
     ではログインできない)。
  2. アプリの「アカウントを追加」→「iCloud」で iCloud メールアドレス +
     発行した App 用パスワードを入力し、「接続テスト」→「保存して同期開始」。
  3. INBOX の同期、新規作成→送信 (Sent への反映)、返信のスレッド接続が
     generic IMAP アカウントと同様に動くことを確認する。
  4. もしログインに失敗する場合、上記の「未確定事項」(ユーザー名の形式) を
     疑い、必要なら実装を短縮形に切り替えて再確認する。

## M9: APNs .p8 キー発行 + 実機での最終確認

**実装状況**: M9 のリレーサーバー・アプリ側オプトイン UI・NotificationService
Extension は実装済み・大部分を自動検証済み (詳細は `docs/relay-deployment.md`
と本セッションの最終報告を参照)。**残っているのは `.p8` キー発行と、それを
使った実機での「実際に通知が届く」確認のみ。**

- **理由**: プッシュ通知リレーサーバーは token-based (.p8) 認証で APNs に
  接続する。self-host 前提のため、リレーを立てる人が自分の Apple
  Developer アカウントで発行する必要がある。また iOS シミュレータは
  APNs デバイストークンを発行しないため、「実際に端末に通知が届く」
  確認はシミュレータでは原理的に不可能 (`PushTokenCenter` はシミュレータ
  上では `.noDeviceToken` を返し、`PushNotificationSettingsView` がその旨
  を表示する — ここまでは自動検証済み)。
- **ブロックしている機能**: 実 APNs 経由でのプッシュ通知 (アプリ kill 状態
  での新着通知)。ConsolePushSender へのフォールバック経路・IDLE 監視・
  push 発火判定・API・アプリ側登録 UI はすべて `.p8` なしで自動検証済み
  (`server/otegami-relay/Tests/OtegamiRelayTests/`、
  `scripts/verify-relay.sh` — 実 Dovecot に対する IDLE→新着→push 発火の
  E2E)。
- **対応手順** (`docs/relay-deployment.md` に詳細版あり):
  1. [Apple Developer](https://developer.apple.com/account/) の
     「証明書、識別子とプロファイル」→「キー」で APNs 用キーを新規作成する。
  2. ダウンロードした `.p8` ファイル (一度しかダウンロードできない点に注意) と、
     Key ID・Team ID を控える (Bundle ID は `com.m-tkg.otegami`、
     `Config/Signing.xcconfig`/`Local.xcconfig` で変更可)。
  3. リレーサーバーの環境変数 `APNS_KEY_PATH`/`APNS_KEY_ID`/`APNS_TEAM_ID`/
     `APNS_BUNDLE_ID` (4 つ全て設定して初めて `APNsSender` が有効になる。
     1 つでも欠けると `ConsolePushSender` にフォールバックする) を設定する。
     `docker-compose.yml`/`.env.sample` 参照。
  4. `.p8` ファイルはリポジトリに含めない (`.gitignore` で
     `server/otegami-relay/secrets/` ごと除外済み)。
  5. 実機に `make ios-device` でビルド・インストールし、DEVELOPMENT_TEAM
     が実際に登録済みの Apple Developer アカウントであることを確認する
     (現状 `G72M73C546` — mytty と共有のチーム。別アカウントを使う場合は
     `Local.xcconfig` で上書き)。
  6. 実機上でアプリの「設定」→「プッシュ通知」からリレー URL (https 必須。
     手前に reverse proxy を立てて TLS 終端すること —
     `docs/relay-deployment.md` の「6. HTTPS の終端」参照) を入力し
     「有効にする」→ 通知の許可 → デバイストークン取得 → 登録、まで進む
     ことを確認する。
  7. アプリをバックグラウンド/kill した状態で該当 IMAP アカウントに新着
     メールを送り、数秒〜十数秒 (IDLE の反応速度次第) で通知が届くこと、
     差出人・件名が正しく表示されること (`NotificationService` が
     `mutable-content` を書き換えている証拠) を確認する。
  8. `DELETE /v1/watches/:id` (アプリの「無効にする」、またはアカウント
     削除) 後、同じ操作で通知が届かなくなることを確認する。

### 既知の未検証事項 (実機がないと検証できない/優先度を下げた項目)

- 上記の実機 E2E そのもの。
- Gmail (`.oauth2`) アカウントのプッシュ通知: v1 のリレーは
  `WatchAuth.Kind.password` のみ対応 (プラン: "LOGIN/XOAUTH2 なし可:
  password のみ v1")。`AppEnvironment.enablePushNotifications` は
  `.password` アカウントのみ watch を作成し、Gmail アカウントは黙って
  スキップする — UI 上に「Gmail は現バージョン未対応」という文言は
  `PushNotificationSettingsView` の同意ダイアログに含めたが、Gmail
  アカウント一覧上で個別に無効化理由を出す UI までは実装していない。
  XOAUTH2 対応 (refresh token を預かる形) は M10 以降の課題。
- macOS 版のプッシュ通知: `NotificationService` Extension は iOS のみ
  (理由は `NotificationService.swift`/`Config/Otegami-iOS.entitlements`
  のコメント参照)。`AppEnvironment.enablePushNotifications` は macOS では
  `PushError.unsupportedPlatform` を返し、UI がその旨を表示する — ここ
  までは自動検証済みだが、macOS 版プッシュ通知の実装自体は範囲外。
- `xcrun simctl push` によるシミュレータへのペイロード注入テスト、
  `NotificationService` のユニットテスト単体は本セッションでは未実施
  (時間の都合)。`scripts/verify-ios-m9.sh` 自体は M9 で追加済みで、M10 の
  最終回帰チェックでも引き続き green (プッシュ設定 UI の opt-in フロー・
  無効な URL の拒否・シミュレータでの `.noDeviceToken` グレースフル
  デグレードを確認)。

## 公開時に必要な対応 (まとめ)

以下は「今すぐ開発を止める理由」ではなく、実際に公開・配布する段になったら
対応が必要な項目 (計画書の合意事項)。

- **リポジトリの public 化**: 現状 private。公開時にリポジトリ名を
  `mailapp` から `otegami` に変更する。
- **Google OAuth の審査**: 各自の Client ID でのテスト利用には審査不要だが、
  作者本人が配布ビルド (App Store/TestFlight) を出す場合は Google の OAuth
  審査が必要になる (`docs/oauth-setup.md`)。
- **macOS ビルドの配布**: `make mac-app` で `dist/Otegami.app` を生成できる
  ようになった (M10) が、現状は開発チームでのアドホック署名のまま。
  Developer ID 署名 + notarization (Gatekeeper 対応) は未実施 — 自分の
  Mac 以外に配る場合はこの対応が必要。
