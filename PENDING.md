# PENDING — ユーザー対応待ち事項

このファイルは、開発を進める上でユーザー本人の判断・手動作業が必要になった項目を記録する。
実装は各項目をモック/スキップ/dev mailstack 代替で進めており、開発の手を止めていない。
都合の良いときに対応し、必要であれば `Config/Local.xcconfig` 等の git 管理外ファイルに値を設定すること。

## M6: Google OAuth Client ID の発行

- **理由**: Gmail 連携は OAuth2 (PKCE) で行うが、OSS のためリポジトリに Client ID を含めない方針。
  ビルドする人が各自 Google Cloud Console で Client ID を発行する必要がある。
- **ブロックしている機能**: Gmail アカウントの追加・同期・送受信 (M6 で実装予定)。
- **対応手順** (M6 実装時に `docs/oauth-setup.md` として詳細化予定):
  1. [Google Cloud Console](https://console.cloud.google.com/) で新規プロジェクトを作成する。
  2. 「OAuth 同意画面」を設定する (テストモードで良い。審査は作者配布ビルドのみ必要)。
  3. 「認証情報」→「OAuth クライアント ID」で **iOS アプリ**タイプ (シークレット不要) を作成し、
     Bundle ID (`com.m-tkg.otegami`) を指定する。
  4. 発行された Client ID を `apps/Otegami/Config/Local.xcconfig` に設定する
     (未設定の場合、アプリ内の Gmail 追加ボタンは無効化される想定)。

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
