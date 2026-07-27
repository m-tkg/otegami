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
   — `https://mail.google.com/`・`https://www.googleapis.com/auth/userinfo.email`・
   `https://www.googleapis.com/auth/contacts.other.readonly` の3つ。2番目は
   XOAUTH2 の SASL に必要なメールアドレスを id_token を要求せずに取得する
   ため、3番目はアバター強化バッチ「Google プロフィール写真」用 (下記
   「`contacts.other.readonly`」節参照)。詳細は `GoogleOAuthEndpoints` の
   コメント参照)。
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
4. バンドル ID に `com.mtkg.otegami` を入力する
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

### `contacts.other.readonly` (アバター強化バッチ「Google プロフィール写真」)

差出人一覧のアイコンを Gmail 公式アプリに近づけるため、
`https://www.googleapis.com/auth/contacts.other.readonly`
(People API の `otherContacts.search` で読み取り専用アクセス) を追加した
(`GoogleOAuthEndpoints.scope`)。**新規に追加する Gmail アカウントは
このスコープを最初から含む** — 何もする必要はない。

**既存の Gmail アカウントは、再接続 (「アカウント編集」→「再認証」) する
までこのスコープを持たない**。People API がスコープ不足で 401/403 を返す
限り `GoogleProfilePhotoAvatarResolver` は静かに次の情報源 (Gravatar →
企業ロゴ → イニシャル) にフォールバックするだけなので、再接続しなくても
アプリは問題なく動く — Google のプロフィール写真が一覧に出ないだけ。

**このスコープは Google の「機密性の高いスコープ (sensitive scope)」に
分類される** (`userinfo.email`/`mail.google.com` より一段厳しい審査対象)。
影響するのは**公開ステータスを「テスト」から「本番」に切り替えて配布ビル
ド (App Store/TestFlight) を出す場合の OAuth 審査**のみ — 各自の Client ID
で「テスト」モードのまま自分を「テストユーザー」に追加して開発・確認する
分には、このスコープを追加していても審査は不要 (このファイル冒頭の注記の
とおり)。配布を検討する際は Google Cloud Console の OAuth 同意画面で
このスコープの使用目的 (「差出人のプロフィール写真の表示」) を申告する
準備をしておくこと。

#### 実機バグ: 再接続してもスコープが増えない場合

実機で「アカウント編集」→「再認証」を実行しても、
myaccount.google.com/connections でこのアプリの付与日・付与スコープが
更新されない (連絡先系スコープが増えない) 症状が報告されたことがある。
切り分けの結果は次のとおりで、**アプリの認可リクエスト自体には問題は
無かった**:

- `GoogleOAuthEndpoints.authorizationURL(pkce:state:)` は最初の実装
  (M6) の時点から常に `prompt=consent`・`access_type=offline` を含む
  リクエストを送っており、`reauthenticateGmailAccount(_:)` はこの関数を
  経由する完全な Authorization Code + PKCE フローを毎回実行している
  (アクセストークンの単純なリフレッシュで済ませてしまう、といった
  近道は無い)。`scope` にも `contacts.other.readonly` 追加コミット
  (8f2aba5) の時点から新スコープが含まれている。
- 実際の原因は **Google Cloud Console 側の OAuth 同意画面設定**
  だった — People API を有効化していない、または同意画面の「データへの
  アクセス」にこのスコープを追加していない状態だと、アプリが
  `prompt=consent`付きで正しくリクエストしても、Google 側がこの
  スコープだけ静かに許可しない (アプリのリクエスト自体はエラーに
  ならず完了するため、アプリ側からは「再認証は成功したのにスコープが
  増えない」としか見えない)。People API の有効化・同意画面へのスコープ
  追加を行うと解消する (`HUMAN_TASKS.md`の該当項目参照)。

上記の切り分けをアプリ内で完結させるため、以下を追加した:

- `authorizationURL`に`include_granted_scopes=true`を追加 (Google の
  推奨デフォルト。今回のように毎回フルスコープをリクエストする限り
  実害は無いが、将来インクリメンタル認可に切り替える場合への保険)。
- 「アカウント編集」画面 (Gmail アカウント) に**「権限の診断」表示**を
  追加した。画面を開くたびに `TokenStore.diagnosticScope(for:)`
  (キャッシュを使わず必ずリフレッシュリクエストを送って、Google が
  実際に返した`scope`フィールドを読む) で問い合わせ、「連絡先の写真:
  許可済み/未許可」を表示する。これで
  myaccount.google.com/connections のスクリーンショットを取らなくても
  アプリ内で同じ切り分けができる。
- 再認証成功時に `GoogleProfilePhotoAvatarResolver` の「このプロセスでは
  このアカウントはスコープ不足」という記憶
  (`scopeInsufficientAccountIds`) を即座にクリアするようにした —
  以前は次回起動までこの記憶が残り、再認証で新スコープを得た直後でも
  写真取得が試みられないままだった。
- `otherContacts.search`は本検索の前に空クエリの「ウォームアップ」
  リクエストを送らないと検索インデックスが温まっておらず空の結果を
  返すことがある、という Google の仕様に対応し、アカウント (トークン)
  ごとにプロセス内で最初の1回だけウォームアップを送るようにした
  (`GooglePeopleAvatarClient.warmupSearchIndex(accessToken:)`)。
- 上記のウォームアップ未対応だった旧実装が書いた 7日 negative cache
  (「見つからなかった」というディスクキャッシュ) を無効化するため、
  `GoogleProfilePhotoAvatarResolver`のキャッシュディレクトリ名に
  `v2`を追加した。

## 実機での最終確認手順 (Client ID 発行後、ユーザー自身が行う)

1. 上記手順で Client ID を発行し `Local.xcconfig` に設定する。
2. `make ios` (またはシミュレータではなく実機の場合 `make ios-device`) で
   ビルドし、実機/シミュレータにインストールする。
3. アプリを起動し、「アカウントを追加」→「Gmail」を選択 (ボタンが有効に
   なっていることを確認)。任意で「表示名」欄に名前を入力する (空欄なら
   後述の通りメールアドレスが表示名になる)。
4. 「Google でログイン」をタップし、Safari 経由の Google ログイン画面で
   テストユーザーに追加した Gmail アカウントでログイン・同意する。
5. アプリに戻り、アカウントが追加され (表示名は3.で入力した値、空欄
   だった場合は Google から取得したメールアドレスがそのまま使われる)、
   INBOX の同期が始まることを確認する。
6. 新規作成 → 送信し、Gmail の「送信済み」に反映されること (Gmail 自身の
   SMTP 送信が Sent コピーを作るため、`OpQueueProcessor` 側の明示的な
   IMAP APPEND はスキップされる — `account.kind == .gmail` 分岐) を確認する。
7. しばらく (アクセストークンの有効期限を跨いで) 使い続け、再ログイン無しに
   同期が継続することを確認する (`TokenStore` の自動リフレッシュ)。
8. (任意) Google アカウント側でアプリのアクセス権を取り消し
   (myaccount.google.com → セキュリティ → サードパーティのアクセス) た後に
   同期を試み、`AccountsSettingsView` に「再認証が必要です」バナーが出て
   「再認証」ボタンから復旧できることを確認する。
9. (`contacts.other.readonly`スコープの確認) 「アカウント編集」→ 対象の
   Gmail アカウントを開き、「認証」節の「連絡先の写真: 許可済み/未許可」
   表示を確認する。**「未許可」のままなら**: (a) まだ「再認証」を一度も
   実行していないアカウントか、(b) 再認証済みでも Google Cloud Console
   の OAuth 同意画面にこのスコープが追加されていない・People API が
   有効化されていない可能性が高い (上の「実機バグ」節参照) — その場合は
   Console 側の設定を直し、もう一度「再認証」してから開き直して確認する。
   「許可済み」になれば、Gravatar 未登録の差出人からのメールで一覧の
   プロフィールアイコンが Google のプロフィール写真に変わることも
   あわせて確認する。

上記はユーザー本人の Google アカウント/実機が必要なため自動検証の対象外
(`scripts/verify-ios-m6.sh` は型選択 UI・Client ID 未設定時のボタン無効化・
iCloud フォームの見た目・「その他」経路が従来通り動くことのみを自動確認する
— 詳細は `docs/verify.md` の M6 節、既知の課題は `PENDING.md` を参照)。
