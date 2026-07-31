# Gmail OAuth Client ID の取得

otegami は Gmail アカウントに OAuth2 (Authorization Code + PKCE) で接続します。
OSS のため、Google Cloud の Client ID をリポジトリには含めません。ビルドする人
各自が Google Cloud Console で発行し、`Config/Local.xcconfig` (git 管理外) に
設定してください。設定しない場合、アプリ内の「アカウントを追加」→「Gmail」
ボタンは無効化され、この手順への案内が表示されます (`GoogleOAuthConfig`)。
既存の Gmail アカウントで「再認証」ボタンを押した場合も同様に無効化され、
「このビルドには Google OAuth Client ID が設定されていないため…」という
案内が表示されます (`AccountEditView`)。

**GitHub Release で配布される macOS ビルドで Gmail 認証を有効にするには**、
リポジトリの GitHub Secrets に `OTEGAMI_GOOGLE_CLIENT_ID` を登録する必要が
ある (`.github/workflows/release-macos.yml` がビルド時にこの secret から
`Config/Local.xcconfig` を生成する)。未登録でもビルド自体は失敗しない —
その場合は上記と同じ「無効化 + 案内表示」になるだけ。詳細は
[docs/release.md](release.md#必要な-github-secrets) 参照。

**既知の制限**: 作者本人の配布ビルド (App Store / TestFlight) だけは
Google の OAuth 審査が必要になる。**各自が自分の Client ID で開発・
テストする分には審査は不要** — Google Cloud プロジェクトを「テスト」
モードのままにし、自分の Google アカウントを「テストユーザー」に追加
しておけば動作する。

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
4. スコープの追加は不要 (otegami は実行時に必要なスコープを直接リクエスト
   する — 下記「スコープについて」参照。詳細は `GoogleOAuthEndpoints` の
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

**プッシュ通知を使う場合**: Gmail アカウントの push watch はこの Client
ID が発行した refresh token をリレーへ送信し、リレー側が同じ Client ID
でアクセストークンに交換する — リレーを運用する側は relay の環境変数
`RELAY_GOOGLE_CLIENT_ID` に**ここと同じ値**を設定する必要がある
([docs/relay-deployment.md](relay-deployment.md) の環境変数表参照)。
設定を忘れても Gmail の watch 自体は作成できるが、認証に失敗し続けて
自動停止する。

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

`https://mail.google.com/` (IMAP/SMTP フルアクセス) に加え、
`https://www.googleapis.com/auth/userinfo.email` を要求する。理由:
XOAUTH2 の SASL 応答 (`user=<email>\x01auth=Bearer <token>...`) を組み
立てるには IMAP 接続を試みる**前に**メールアドレスが分かっている必要が
あり、`https://mail.google.com/` だけのスコープでは `id_token` も
`userinfo` エンドポイントの `email` フィールドも取得できないため。追加
した `userinfo.email` スコープは Google の同意画面上でも「メールアドレス
の表示」という控えめな権限としてしか見えず、`https://mail.google.com/`
(メールの完全な管理) に比べて実質的に権限を拡大するものではない。

### `contacts.other.readonly`・`contacts.readonly`・`userinfo.profile` (差出人のプロフィール写真)

差出人一覧のアイコンに Google のプロフィール写真を使うため、上記2つに
加えて3つのスコープを要求する (`GoogleOAuthEndpoints.scope`)。**新規に
追加する Gmail アカウントはすべて最初から含む** — 何もする必要はない。
**既存の Gmail アカウントは、再接続 (「アカウント編集」→「再認証」) する
まで新しいスコープを持たない。**

- `https://www.googleapis.com/auth/contacts.other.readonly` — People API
  の `otherContacts.list` (Gmail が自動収集した「メールのやり取りは
  あるが保存はしていない相手」) への読み取り専用アクセス。
- `https://www.googleapis.com/auth/contacts.readonly` — People API の
  `people/me/connections` (ユーザー本人が明示的に保存した Google 連絡先)
  への読み取り専用アクセス。`contacts.other.readonly` だけでは「保存済み
  連絡先」からの写真は取得できない (Gmail が自動収集した「other
  contacts」の集合には保存済み連絡先が含まれない) ため両方必要。
- `https://www.googleapis.com/auth/userinfo.profile` — 自分自身の
  プロフィール写真 (`people/me?personFields=emailAddresses,photos`) の
  取得に必要。`contacts.other.readonly`/`contacts.readonly` だけでは
  `people/me` へのアクセスは 403 (`Request requires one of the
  following scopes: [profile]`) になる。Google の**非機密 (basic)
  スコープ** (`userinfo.email` と同じ層で、下の2つより緩い) — 同意画面
  の審査要件への影響はない。

**実装方式**: 差出人アドレスごとに都度 People API へ問い合わせるのでは
なく、`otherContacts.list`/`people/me/connections` をそれぞれ全件
ページングで走査し、(メールアドレス → 写真 URL) の索引をアカウントごと
に構築してディスクキャッシュする方式 (`GoogleProfilePhotoAvatarResolver`)。
個々の差出人の解決はこの索引を引くだけなので、一覧をスクロールするたび
に People API を連打することはない。

**両方とも Google の「機密性の高いスコープ (sensitive scope)」に分類
される** (`userinfo.email`/`mail.google.com` より一段厳しい審査対象)。
影響するのは公開ステータスを「テスト」から「本番」に切り替えて配布ビルド
を出す場合の OAuth 審査のみ — 各自の Client ID で「テスト」モードのまま
確認する分には審査は不要 (このファイル冒頭の注記のとおり)。配布を検討
する際は OAuth 同意画面でこれらのスコープの使用目的 (「差出人の
プロフィール写真の表示」) を申告する準備をしておくこと。

スコープを追加で有効化した既存プロジェクトでは、「OAuth 同意画面」→
「データへのアクセス」で対象スコープを追加してから、既存の Gmail
アカウントを全て再接続 (「アカウント編集」→「再認証」) する必要がある —
「アカウント編集」画面の「権限の診断」表示 (下記) で確認できる。

**トラブルシューティング: 再認証してもスコープが増えない場合**: 原因は
ほぼ常に Google Cloud Console 側の設定不足 — People API を有効化して
いない、または OAuth 同意画面の「データへのアクセス」に該当スコープを
追加していない状態だと、アプリが正しくリクエストしても Google 側が
そのスコープだけ静かに許可しない (アプリのリクエスト自体はエラーになら
ず完了するため、アプリ側からは「再認証は成功したのにスコープが増えない」
としか見えない)。「アカウント編集」画面の「権限の診断」表示
(`TokenStore.diagnosticScope(for:)` — キャッシュを使わず必ずリフレッシュ
リクエストを送って Google が実際に返した `scope` を読む) で「連絡先の
写真: 許可済み (完全/基本)/未許可」を確認でき、myaccount.google.com の
確認画面を開かなくても切り分けられる。People API の有効化・同意画面への
スコープ追加を行い、もう一度「再認証」すれば解消する。

### 再認証時に同意画面を省略する

「アプリは Google で確認されていません」という未検証アプリ警告自体は、
OAuth 同意画面の公開ステータスを「本番」に切り替えて審査を通すまで消せない
(このファイル冒頭の注記参照)。ただし、この警告と同意画面を**毎回**踏む
必要はない — 「アクセストークンが切れただけで、許可済みのスコープは
何も変わっていないアカウントを再認証する」場合、Google は `prompt`
パラメータを省略したリクエストに対して、要求スコープが既存の許可を
超えていなければサイレントに (同意画面もアプリ未検証警告も出さずに)
新しいコードを発行する。

`AppEnvironment.reauthenticateGmailAccount(_:)` は再認証のたびに:

1. `TokenStore.diagnosticScope(for:)` (「アカウント編集」の「権限の診断」
   と同じ、キャッシュを使わず強制的にリフレッシュリクエストを送る問い
   合わせ) でこのアカウントの現在の付与スコープを取得する。
2. `GoogleOAuthEndpoints.isSatisfied(byGrantedScope:)` で、その付与
   スコープが現在の `scope` 全体を含むか判定する。
3. 含む場合は `promptConsent: false` で `requestGmailAuthorization(promptConsent:)`
   を呼び、`prompt` パラメータ自体を省略する。ユーザーから見ると、
   ブラウザシートが一瞬開いて (Google 側のサイレント承認を経て) すぐ
   閉じるだけのワンタップで再認証が完了する。
4. 付与スコープが不足している場合 (新しいスコープが `scope` に追加された
   直後でまだ再接続していないアカウントなど) や、診断問い合わせ自体が
   失敗した場合は、従来通り `promptConsent: true` で同意画面を強制する
   — 「わからない場合は安全側 (同意画面を出す) に倒す」という判断。

**refresh token の保全**: `prompt` を省略したリクエストへのトークン応答は
`refresh_token` を含まないことがある (Google の仕様通り — 同一クライアント
/スコープへの再同意はデフォルトで `refresh_token` を省略する)。
`TokenStore.storeInitialTokens` はレスポンスに `refresh_token` が含まれる
場合だけ Keychain の値を上書きする (含まれない場合は何もせず既存の値を
そのまま残す) ため、この経路でも既存の refresh token が失われることは
ない。

新規アカウント追加は引き続き常に `promptConsent: true` (デフォルト) —
初回はまだ何も許可されていないので同意画面が必須であり、かつ初回の交換
で確実に `refresh_token` を得る必要があるため。

## 実機での最終確認手順 (Client ID 発行後、ユーザー自身が行う)

実 Google アカウント/実機が必要なため自動検証の対象外 (ユニットテストは
`GoogleOAuthEndpointsTests`/`GoogleOAuthClientTests`/`TokenStoreTests`
の `URLProtocol` スタブ・フェイクで、トークン交換/リフレッシュ/
invalid_grant/再認証の同意省略ロジックを検証している)。

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
   SMTP 送信が Sent コピーを作るため、明示的な IMAP APPEND はスキップ
   される) を確認する。
7. しばらく (アクセストークンの有効期限を跨いで) 使い続け、再ログイン無しに
   同期が継続することを確認する (`TokenStore` の自動リフレッシュ)。
8. (任意) Google アカウント側でアプリのアクセス権を取り消し
   (myaccount.google.com → セキュリティ → サードパーティのアクセス) た後に
   同期を試み、「再認証が必要です」バナーが出て「再認証」ボタンから
   復旧できることを確認する。
9. アクセス権を取り消さずスコープも変わっていない状態のまま「アカウント
   編集」→「再認証」を実行する。同意画面もアプリ未検証警告も出ず、
   ブラウザシートが一瞬開いてすぐ閉じるだけでワンタップで完了することを
   確認する。逆に、`contacts.readonly` のようなスコープをまだ許可して
   いないアカウントで同じ操作をすると、従来通り同意画面が出ることも
   確認する。
10. 「アカウント編集」→ 対象の Gmail アカウントを開き、「認証」節の
    「連絡先の写真: 許可済み (完全/基本)/未許可」表示を確認する。
    「許可済み (完全)」になれば、Gravatar 未登録の差出人からのメールで
    一覧のプロフィールアイコンが Google のプロフィール写真に変わることも
    あわせて確認する。

# Microsoft OAuth Client ID の取得 (Outlook.com/Office365)

Microsoft は IMAP の Basic 認証 (ID/パスワードでのログイン) を廃止済み
のため、Outlook.com/Office 365 アカウントは XOAUTH2 (OAuth2) でしか
接続できない。実装は Gmail の `GoogleOAuth`(Authorization Code + PKCE、
`ASWebAuthenticationSession`)をひな形にした `MicrosoftOAuth`
(`packages/OtegamiKit/Sources/MicrosoftOAuth/`)。Gmail と同じく OSS の
ため、Azure の Client ID をリポジトリには含めない。ビルドする人各自が
Azure Portal で発行し、`Config/Local.xcconfig`(git 管理外)に設定する。
設定しない場合、「アカウントを追加」→「Outlook」/「Office365」ボタンは
無効化され、この手順への案内が表示される
(`AccountTypeSelectionView.outlookButton`/`MicrosoftOAuthConfig`)。
既存アカウントの「再認証」ボタンも同様に無効化される (`AccountEditView`)。

**GitHub Release で配布される macOS ビルドで Microsoft 認証を有効にする
には**、GitHub Secrets に `OTEGAMI_MICROSOFT_CLIENT_ID` を登録する必要が
ある。Gmail 側と同じ仕組み・同じ「未登録でも失敗しない」挙動 —
[docs/release.md](release.md#必要な-github-secrets) 参照。

## 1. Azure AD アプリを登録する

1. [Azure Portal](https://portal.azure.com/) → 「Microsoft Entra ID」
   (旧 Azure Active Directory) → 「アプリの登録」→「新規登録」を開く。
2. 名前は任意 (例: `otegami-dev`)。
3. **サポートされているアカウントの種類**は「任意の組織ディレクトリ内の
   アカウントと個人の Microsoft アカウント」を選ぶ — Outlook.com (個人)
   と Microsoft 365 (組織) の両方を1つの Client ID でカバーするために
   必須 (`MicrosoftOAuthEndpoints`が `common` テナントの1エンドポイント
   だけを使っているのはこの前提に基づく)。
4. リダイレクト URI はこの時点では未設定のままでよい (次の手順で追加)。
5. 登録すると「アプリケーション (クライアント) ID」が発行される —
   これが `OTEGAMI_MICROSOFT_CLIENT_ID` の値。

## 2. リダイレクト URI を登録する (Google と違い**必須**)

Google の iOS クライアントタイプと違い、Azure AD は使う `redirect_uri`
を事前登録しないと認可リクエスト自体が `redirect_uri_mismatch` で
拒否される。

1. 登録したアプリの「認証」ページを開く。
2. 「プラットフォームを追加」→「モバイルアプリケーションおよびデスク
   トップアプリケーション」を選ぶ。
3. 「カスタムリダイレクト URI」に次の値を**そのまま**入力する
   (`MicrosoftOAuthEndpoints.standardRedirectURI`と一致させる必要が
   あり、この値は otegami 側で固定・変更不可):
   ```
   com.mtkg.otegami.msauth://oauth2redirect
   ```
4. 「パブリック クライアント フローを許可する」を **はい** にする —
   otegami はクライアントシークレットを持たない PKCE のみの構成
   (Gmail の「iOS」クライアントタイプと同じ思想)。シークレットを要求
   する構成のままだとトークン交換が失敗する。**この設定を忘れると
   `redirect_uri_mismatch` で失敗する。**

## 3. API のアクセス許可 (スコープ) を確認する

`MicrosoftOAuthEndpoints.scope`が実行時に直接リクエストするため、
Azure Portal 側でスコープを追加登録する必要は**無い**
(`https://outlook.office.com/IMAP.AccessAsUser.All`・
`https://outlook.office.com/SMTP.Send`・`offline_access`・`openid`・
`email` の5つ — 1つ目が IMAP フルアクセス、2つ目が SMTP 送信、3つ目が
リフレッシュトークン発行、4・5つ目が id_token からのメールアドレス
取得用)。同意画面はユーザーの初回サインイン時に Microsoft 側が自動で
出す。

## 4. `Config/Local.xcconfig` に設定する

```sh
cp apps/Otegami/Config/Local.xcconfig.sample apps/Otegami/Config/Local.xcconfig
# 既に Gmail 用に作成済みなら不要
```

`Local.xcconfig` に以下を追記する (発行された Client ID をそのまま):

```
OTEGAMI_MICROSOFT_CLIENT_ID = your-azure-app-client-id
```

`make mac` / `make ios` で再ビルドすれば、`Info.plist` の
`OTEGAMI_MICROSOFT_CLIENT_ID` キー経由でアプリが実行時に読み込む
(`MicrosoftOAuthConfig.clientId`)。「アカウントを追加」→「Outlook」/
「Office365」ボタンが有効になっていれば設定成功。

**プッシュ通知を使う場合**: Google と同様、relay の環境変数
`RELAY_MICROSOFT_CLIENT_ID` にここと同じ Client ID を設定する
([docs/relay-deployment.md](relay-deployment.md) の環境変数表参照)。

## メールアドレスの取得方法 (Google との違い)

Gmail は `https://mail.google.com/` スコープだけでは識別情報が一切
取れないため、`userinfo.email`スコープを追加した上で別途 userinfo
エンドポイントへ HTTP リクエストしてメールアドレスを取得している
(このファイル前半の「スコープについて」節参照)。Microsoft は
`openid email` スコープを付けるだけで、トークン応答の `id_token`
(JWT) に `email`(取れない場合は `preferred_username`)クレームが
そのまま載ってくるため、**追加のネットワーク往復が不要**
(`MicrosoftOAuthClient.fetchUserEmail(idToken:)`)。id_token の署名検証は
行っていない — Azure AD のトークンエンドポイントから TLS 越しに直接
受け取ったものだけを読むので、なりすまされたトークンを渡されるリスクが
無く、検証には JWKS 取得+JWT ライブラリという余分な依存が要るため、
このアプリの用途 (表示用のメールアドレス取得のみ、認可判断には使わな
い) には見合わないと判断した。

## kind: `.microsoft` と `TokenStore` の使い分け

`AccountRecord.kind`に `.gmail`と並んで `.microsoft`を追加した
(`.oauth2`な `authType`だけでは「どちらのプロバイダのトークンか」が
わからないため)。`AppEnvironment.auth(for:)`/
`CloudAccountDirectory.resolveAuth(for:)`はどちらも`account.kind`で
`GoogleOAuth.TokenStore`/`MicrosoftOAuth.TokenStore`のどちらを使うかを
分岐する。1ビルドで Gmail・Microsoft の両方・片方・どちらも未設定、の
どの組み合わせでも動く (`isGmailOAuthConfigured`/
`isMicrosoftOAuthConfigured`がそれぞれ独立)。

## 実機での最終確認手順 (Client ID 発行後、ユーザー自身が行う)

実 Azure AD アプリ/実 Microsoft アカウントが必要なため自動検証の対象外
(ユニットテストは `MicrosoftOAuthEndpointsTests`/`MicrosoftOAuthClientTests`/
`TokenStoreTests`、`packages/OtegamiKit/Tests/MicrosoftOAuthTests/` が
`URLProtocol`スタブ + フェイク認可フローで、Gmail 側のテスト構造をその
まま踏襲してトークン交換/リフレッシュ/invalid_grant/id_token からの
メールアドレス抽出を検証している)。

1. 上記手順で Client ID を発行し、リダイレクト URI を登録し、
   `Local.xcconfig`に設定する。
2. `make ios` (または実機の場合 `make ios-device`) でビルドし、
   実機/シミュレータにインストールする。
3. アプリを起動し、「アカウントを追加」→「Outlook」(個人の
   Outlook.com/Hotmail アカウントの場合) または「Office365」(会社・
   学校の Microsoft 365 アカウントの場合) を選択 (ボタンが有効になって
   いることを確認)。
4. 「Microsoft でログイン」をタップし、Safari 経由の Microsoft
   サインイン画面でアカウントを選択・サインイン・同意する。
5. アプリに戻り、アカウントが追加され (表示名は3.で入力した値、空欄
   だった場合は id_token から取得したメールアドレスがそのまま使わ
   れる)、INBOX の同期が始まることを確認する。
6. 新規作成 → 送信し、正常に送信できることを確認する。
7. しばらく使い続け、再ログイン無しに同期が継続することを確認する
   (`MicrosoftOAuth.TokenStore`の自動リフレッシュ、Gmail と同じ5分前
   リフレッシュ)。
8. (任意) Microsoft アカウント側でアプリのアクセス権を取り消し
   (account.microsoft.com or myapps.microsoft.com → アプリのアクセス
   許可)た後に同期を試み、「アカウント編集」に「再認証が必要です」
   バナーが出て「再認証」ボタンから復旧できることを確認する。
9. リダイレクト URI の登録漏れ・「パブリック クライアント フロー」
   未許可などの設定ミスがあると、Safari 上で `AADSTS...` から始まる
   Microsoft 側のエラーページがそのまま表示される — その場合は上記
   2〜3の Azure Portal 設定を見直すこと。
