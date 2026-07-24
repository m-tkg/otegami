# Gmail OAuth Client ID の取得 (M6)

otegami は Gmail アカウントに OAuth2 (Authorization Code + PKCE) で接続します。
OSS のため、Google Cloud の Client ID をリポジトリには含めません。ビルドする人
各自が Google Cloud Console で発行し、`Config/Local.xcconfig` (git 管理外) に
設定してください。設定しない場合、アプリ内の「アカウントを追加」→「Gmail」
ボタンは無効化され、この手順への案内が表示されます (`GoogleOAuthConfig`)。

作者本人の配布ビルド (App Store / TestFlight) だけは Google の OAuth 審査が
必要になりますが、**各自が自分の Client ID で開発・テストする分には審査は
不要**です (Google Cloud プロジェクトを「テスト」モードのままにし、自分の
Google アカウントを「テストユーザー」に追加しておけば動作します)。

## 1. Google Cloud プロジェクトを作成する

1. [Google Cloud Console](https://console.cloud.google.com/) を開く。
2. 画面上部のプロジェクト選択メニューから「新しいプロジェクト」を作成する
   (名前は任意。例: `otegami-dev`)。
3. 作成したプロジェクトを選択した状態で以降の手順を進める。

## 2. OAuth 同意画面を設定する

1. 左メニュー「API とサービス」→「OAuth 同意画面」を開く。
2. User Type は「外部」を選択 (Google Workspace 組織に属していない限り、
   「内部」は選べません)。
3. アプリ名 (例: `otegami (dev)`)・ユーザーサポートメール・デベロッパーの
   連絡先メールを入力して保存する。
4. スコープの追加は不要 (otegami は実行時に必要なスコープを直接リクエストする
   — `https://mail.google.com/` と `https://www.googleapis.com/auth/userinfo.email`。
   後者は XOAUTH2 の SASL に必要なメールアドレスを、id_token を要求せずに
   取得するために使っている。詳細は `GoogleOAuthEndpoints` のコメント参照)。
5. 「テストユーザー」に自分の Gmail アドレスを追加する。**公開ステータスが
   「テスト」のままなら審査は不要**。テストユーザー以外のアカウントはログイン
   できない点に注意 (複数アカウントでテストしたい場合はそれぞれ追加する)。

## 3. iOS 用 OAuth クライアント ID を作成する

1. 左メニュー「API とサービス」→「認証情報」を開く。
2. 「認証情報を作成」→「OAuth クライアント ID」。
3. アプリケーションの種類で **「iOS」** を選択する
   (シークレットが発行されない種類 — otegami は PKCE のみでシークレット不要な
   iOS クライアントタイプを前提にしている。「ウェブ アプリケーション」等
   *シークレットが必要な*種類を選んでしまうと動作しない)。
4. バンドル ID に `com.m-tkg.otegami` を入力する
   (`Config/Signing.xcconfig` の `OTEGAMI_BUNDLE_ID` を上書きしている場合は
   その値に合わせること)。
5. 作成すると `1234567890-abcdefg.apps.googleusercontent.com` のような
   Client ID が発行される (iOS クライアントタイプにシークレットは無い)。

## 4. `Config/Local.xcconfig` に設定する

```sh
cp apps/Otegami/Config/Local.xcconfig.sample apps/Otegami/Config/Local.xcconfig
```

`Local.xcconfig` に以下を追記する (発行された Client ID をそのまま):

```
GOOGLE_OAUTH_CLIENT_ID = 1234567890-abcdefg.apps.googleusercontent.com
```

`make mac` / `make ios` で再ビルドすれば、`Info.plist` の
`GOOGLE_OAUTH_CLIENT_ID` キー経由でアプリが実行時に読み込む
(`GoogleOAuthConfig.clientId`)。「アカウントを追加」→「Gmail」ボタンが
有効になっていれば設定成功。

## リダイレクト URI について (登録不要)

otegami は Client ID を逆順にした固定のカスタム URL スキーム
(`com.googleusercontent.apps.<Client ID を逆順にしたもの>:/oauth2redirect`)
を `redirect_uri` として使う (`GoogleOAuthEndpoints.redirectScheme(forClientId:)`)。
これは Google の iOS クライアントタイプが標準で受け付ける規約で、
**Google Cloud Console 側にリダイレクト URI を個別登録する必要はない**。
また `Info.plist` の `CFBundleURLTypes` にも何も追加していない —
`ASWebAuthenticationSession` はこのスキームへのナビゲーションを、システムの
URL スキームルーティングに渡す前に自分自身で捕捉するため、アプリ側で
URL スキームを宣言する必要がない (`ASWebAuthenticationSessionRunner` の
コメント参照)。

## スコープについて

計画時点のスコープ案は `https://mail.google.com/` (IMAP/SMTP フルアクセス)
のみだったが、実装時に `https://www.googleapis.com/auth/userinfo.email` を
追加した。理由: XOAUTH2 の SASL 応答 (`user=<email>\x01auth=Bearer <token>...`)
を組み立てるには IMAP 接続を試みる**前に**メールアドレスが分かっている
必要があり、`https://mail.google.com/` だけのスコープでは `id_token` も
`userinfo` エンドポイントの `email` フィールドも取得できない。追加した
`userinfo.email` スコープは Google の同意画面上でも「メールアドレスの
表示」という控えめな権限としてしか見えず、`https://mail.google.com/`
(メールの完全な管理) に比べて実質的に権限を拡大するものではない。

## 実機での最終確認手順 (Client ID 発行後、ユーザー自身が行う)

1. 上記手順で Client ID を発行し `Local.xcconfig` に設定する。
2. `make ios` (またはシミュレータではなく実機の場合 `make ios-device`) で
   ビルドし、実機/シミュレータにインストールする。
3. アプリを起動し、「アカウントを追加」→「Gmail」を選択 (ボタンが有効に
   なっていることを確認)。
4. 「Google でログイン」をタップし、Safari 経由の Google ログイン画面で
   テストユーザーに追加した Gmail アカウントでログイン・同意する。
5. アプリに戻り、アカウントが追加され (表示名・メールアドレスが Google
   から取得したものになっている)、INBOX の同期が始まることを確認する。
6. 新規作成 → 送信し、Gmail の「送信済み」に反映されること (Gmail 自身の
   SMTP 送信が Sent コピーを作るため、`OpQueueProcessor` 側の明示的な
   IMAP APPEND はスキップされる — `account.kind == .gmail` 分岐) を確認する。
7. しばらく (アクセストークンの有効期限を跨いで) 使い続け、再ログイン無しに
   同期が継続することを確認する (`TokenStore` の自動リフレッシュ)。
8. (任意) Google アカウント側でアプリのアクセス権を取り消し
   (myaccount.google.com → セキュリティ → サードパーティのアクセス) た後に
   同期を試み、`AccountsSettingsView` に「再認証が必要です」バナーが出て
   「再認証」ボタンから復旧できることを確認する。

上記はユーザー本人の Google アカウント/実機が必要なため自動検証の対象外
(`scripts/verify-ios-m6.sh` は型選択 UI・Client ID 未設定時のボタン無効化・
iCloud フォームの見た目・「その他」経路が従来通り動くことのみを自動確認する
— 詳細は `docs/verify.md` の M6 節、既知の課題は `PENDING.md` を参照)。
