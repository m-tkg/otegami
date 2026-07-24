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

## M9: APNs .p8 キー発行

- **理由**: プッシュ通知リレーサーバーは token-based (.p8) 認証で APNs に接続する。
  self-host 前提のため、リレーを立てる人が自分の Apple Developer アカウントで発行する必要がある。
- **ブロックしている機能**: プッシュリレーによる新着通知 (M9 で実装予定)。
- **対応手順** (M9 実装時に `docs/relay-deployment.md` として詳細化予定):
  1. [Apple Developer](https://developer.apple.com/account/) の
     「証明書、識別子とプロファイル」→「キー」で APNs 用キーを新規作成する。
  2. ダウンロードした `.p8` ファイル (一度しかダウンロードできない点に注意) と、
     Key ID・Team ID・Bundle ID を控える。
  3. リレーサーバーの環境変数 (`APNS_KEY_PATH` 等、M9 で定義) に `.p8` のパスと ID 類を設定する。
  4. `.p8` ファイルはリポジトリに含めない (`.gitignore` で除外済み)。
