# push リレーのデプロイ

otegami のプッシュ通知はオプション機能で、セルフホストする「push リレー」
サーバーが対象アカウントの IMAP を監視し、新着を検知すると APNs 経由で
デバイスへ通知を送る構成で動く。本アプリのビルド元がこのサーバーを自分で
運用する前提 (OSS で Apple Developer アカウント・APNs 認証情報を配布
できないため)。リレーを配置しない/ビルドに設定しない場合はプッシュ通知
機能だけが無効になり、アプリの他の機能には影響しない (後述「未設定時の
挙動」参照)。

コードベース全体の構成については [`docs/architecture.md`](architecture.md)
の「`server/otegami-relay-go/`」節を参照。通知の長押し/左スワイプで出る
「既読にする」「アーカイブ」アクションについては
[`docs/push-notification-actions.md`](push-notification-actions.md) を参照。

## リレーが何をするか

1. 登録されたアカウントごとに IMAP `INBOX` を IDLE で監視する (IDLE 非
   対応サーバーは polling + NOOP キープアライブにフォールバックする —
   仕組みと落とし穴は
   [`docs/architecture.md`](architecture.md#c-idle-非対応の-imap-サーバーには-noop-キープアライブが必須)
   の Known pitfalls (c) を参照)。
2. 新着を検知すると、件名・本文・差出人を含まない**内容なしの** silent
   push (`accountId`/`uidNext` のみ) を APNs 経由でデバイスに送る。
   **`RELAY_CONTENT_PREVIEW=1` を設定した場合はこの既定の挙動が変わる**
   — 詳細は下記「`RELAY_CONTENT_PREVIEW` (opt-in の内容プレビュー)」参照。
3. 実際のメール内容 (差出人・件名・本文プレビュー) は、プッシュを受信
   した端末自身の Notification Service Extension
   (`apps/Otegami/NotificationService/`) が、その端末が持つ資格情報で
   改めて IMAP に接続して取得する。リレーは**既定では**メール内容を一度も
   扱わない — 預かるのは IMAP 資格情報 (パスワードまたは OAuth refresh
   token) のみで、それも暗号化して保存する (詳細は下記「セキュリティ
   設計」)。
   この取得処理は OS が拡張に与える時間予算 (約30秒) の内側で自前の
   表示デッドラインを持ち、IMAP 取得や Gmail の追加エンリッチが間に
   合わない場合は内容なしの汎用通知のまま表示を確定する — 通知自体が
   出ないことよりも内容が薄いことを許容する設計
   (`NotificationService.swift` のデッドライン定数参照)。

## 実装

**`server/otegami-relay-go/`** が本番デプロイ対象。HTTP API・SQLite
スキーマ・暗号化・環境変数の契約は同ディレクトリの README に記載する。

## デプロイ手順 (Docker)

```sh
cp server/otegami-relay-go/.env.sample server/otegami-relay-go/.env
# .env を編集: RELAY_MASTER_KEY を必須で設定 (生成方法は次項)。他は任意。

docker compose -f server/otegami-relay-go/docker-compose.yml up -d
curl http://localhost:8080/health   # "ok" 相当が返れば起動成功
```

`docker-compose.yml` はビルドコンテキストとして Go モジュールの
ディレクトリ自身を使う。データは named volume
(`otegami-relay-data:/app/data`) に永続化される。

### `RELAY_MASTER_KEY` の生成

IMAP 資格情報を暗号化して保存するための AES-256 鍵。32 byte を base64 で:

```sh
openssl rand -base64 32
```

この値は**絶対にリポジトリにコミットしない**。紛失するとリレーに登録
済みの全 watch の IMAP 資格情報が復号不能になる (=実質的に全 watch が
壊れる — 各アカウントで再度プッシュ通知を有効化し直せば復旧できるので、
鍵のバックアップは必須ではない)。

### `.p8` キー (実 APNs 配信を使う場合のみ)

[Apple Developer](https://developer.apple.com/account/) の「証明書、
識別子とプロファイル」→「キー」で APNs 用キーを新規作成し、`.p8`
ファイル・Key ID・Team ID を控える。アプリの Bundle ID も控える (既定
`com.mtkg.otegami`、`Config/Signing.xcconfig` で変更可)。

`.p8` を使う場合は `server/otegami-relay-go/secrets/` (既定、`.env` の
`APNS_KEY_DIR` で変更可) に配置し、`APNS_KEY_PATH` をコンテナ内パス
(例 `/app/secrets/AuthKey_XXXXXXXXXX.p8`) に設定する。このディレクトリ
はリポジトリにコミットしない (`.gitignore` 参照)。

`APNS_KEY_PATH`/`APNS_KEY_ID`/`APNS_TEAM_ID`/`APNS_BUNDLE_ID` の4つが
すべて揃って初めて実 APNs 配信 (`APNsSender`) が有効になる。1つでも欠け
ると `ConsolePushSender` にフォールバックし、実際に端末へ通知が届く手前
まで (IDLE 監視 → 新着検知 → push 発火) の全パイプラインをログ出力で
確認できる。

### Docker を使わない場合

```sh
cd server/otegami-relay-go
export RELAY_MASTER_KEY=$(openssl rand -base64 32)
go run ./cmd/otegami-relay
```

### HTTPS の終端

リレー自体は平文 HTTP しか話さない。アプリ側は「リレー URL は https
必須 (ローカル開発時のみ `http://localhost`/`http://127.0.0.1` を許可)」
という制約を UI で強制するため、公開運用では手前に reverse proxy
(Caddy/nginx/Cloudflare Tunnel 等) を置いて TLS を終端すること。IMAP
資格情報を平文で送信するエンドポイント (`POST /v1/watches`) がある以上、
これは必須の手順。

家庭内 LAN/VPN だけに閉じた運用で自前 CA を使う場合、iOS 側は実機ごとに
ルート証明書をインストール後、**設定 → 一般 → 情報 → 証明書信頼設定**
で明示的に有効化する必要がある — プロファイルのインストールだけでは
信頼されず、これを忘れると TLS ハンドシェイクが失敗し続ける。

## 環境変数リファレンス

### リレー側 (`.env`)

`server/otegami-relay-go/.env.sample` をコピーして編集する。

| 変数 | 必須 | 説明 |
|---|---|---|
| `RELAY_MASTER_KEY` | ○ | IMAP 資格情報の暗号化鍵 (base64, 32 byte)。生成方法は上記。 |
| `RELAY_DATABASE_PATH` | - | SQLite ファイルパス。既定 `otegami-relay.sqlite` (Docker では `/app/data/otegami-relay.sqlite`、named volume に永続化)。 |
| `RELAY_PORT` | - | HTTP リッスンポート。既定 `8080`。 |
| `APNS_KEY_PATH` / `APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_BUNDLE_ID` | - | 実 APNs 配信。4つ全て設定して初めて有効 (`APNsSender`)。1つでも欠けると `ConsolePushSender` にフォールバックする。 |
| `RELAY_DEVICE_REGISTRATION_SECRET` | - | `POST /v1/devices` (新規デバイス登録) を保護する運用者共有シークレット。設定すると `Authorization: Bearer <この値>` が無い/不一致の登録要求を 401 にする。アプリ側の `OTEGAMI_RELAY_REGISTRATION_SECRET` と同じ値にする。未設定 (既定) の場合は無認証で登録できる — 詳細は下記「セキュリティ設計」参照。 |
| `RELAY_EXTRA_IMAP_PORTS` | - | `POST /v1/watches` が受理する IMAP ポートを既定の 143/993 に加えて広げる (カンマ区切り、例 `1143,2143`)。ポート転送した自宅サーバーなど非標準ポート運用のときのみ設定する。 |
| `RELAY_ALLOW_PRIVATE_IMAP_HOSTS` | - | `1` にすると `POST /v1/watches` がループバック/リンクローカル/プライベート (RFC1918/ULA) の IMAP ホストを受理するようになる。IMAP サーバーがリレーと同じプライベートネットワーク上にある構成のときのみ設定する — 既定 (未設定) はこれらを拒否する。 |
| `RELAY_GOOGLE_CLIENT_ID` | - | Gmail の OAuth watch がリフレッシュトークンをアクセストークンへ交換する際に使う Google OAuth Client ID。アプリ側の `GOOGLE_OAUTH_CLIENT_ID`/`OTEGAMI_GOOGLE_CLIENT_ID` と**同じ値**を設定する (同じ Client ID が発行したリフレッシュトークンでないと交換できない)。未設定のままだと Gmail の watch は作成できても認証に失敗し続けて停止する。 |
| `RELAY_MICROSOFT_CLIENT_ID` | - | 同上、Outlook/Office 365 用。アプリ側の `OTEGAMI_MICROSOFT_CLIENT_ID` と同じ値。 |
| `RELAY_CONTENT_PREVIEW` | - | `1`/`true`/`yes` (大文字小文字を区別しない) で opt-in する新着メール内容プレビュー機能。既定 (未設定) は off — リレーはこれまで通りメール内容を一切扱わない。詳細・プライバシー上の意味は下記「`RELAY_CONTENT_PREVIEW` (opt-in の内容プレビュー)」参照。 |
| `APNS_KEY_DIR` | - | (Docker Compose のみ) `.p8` を置くホスト側ディレクトリ。既定 `./secrets`。 |

上記の変数名は `server/otegami-relay-go/internal/config/config.go` の
`FromEnvironment` を実際のソースとして確認済み。

### アプリ側 (ビルド時に埋め込む)

ユーザーがアプリの画面で設定する項目は**無い** — すべてビルド時に
`Config/Local.xcconfig`(または CI/CD の secret・環境変数) から
`Info.plist` 経由で埋め込む。実際の配布経路は3つあり、**同じ値を3箇所
すべてに設定する**必要がある:

| 値 | ローカル (`Config/Local.xcconfig`) | macOS リリース (GitHub Actions secret) | TestFlight/iOS (Xcode Cloud 環境変数) |
|---|---|---|---|
| リレー URL | `OTEGAMI_PUSH_RELAY_URL` | `OTEGAMI_PUSH_RELAY_URL` | `OTEGAMI_PUSH_RELAY_URL` |
| デバイス登録シークレット | `OTEGAMI_RELAY_REGISTRATION_SECRET` | `OTEGAMI_RELAY_REGISTRATION_SECRET` | `OTEGAMI_RELAY_REGISTRATION_SECRET` |
| Google OAuth Client ID | `GOOGLE_OAUTH_CLIENT_ID` | `OTEGAMI_GOOGLE_CLIENT_ID` | `OTEGAMI_GOOGLE_CLIENT_ID` |
| Microsoft OAuth Client ID | `OTEGAMI_MICROSOFT_CLIENT_ID` | `OTEGAMI_MICROSOFT_CLIENT_ID` | `OTEGAMI_MICROSOFT_CLIENT_ID` |

(Google Client ID だけローカル xcconfig 側のキー名が `GOOGLE_OAUTH_
CLIENT_ID` で GitHub secret/Xcode Cloud 側は `OTEGAMI_GOOGLE_CLIENT_ID`
— CI 側が変換して書き込む。他の3つはローカル・CI で同じキー名。)

- **`Config/Local.xcconfig` に URL を書くときだけ形式が違う**: xcconfig
  構文は `//` をコメント開始として扱うため、`https://…` をそのまま書くと
  値が `https:` に切り詰められる。`Config/Shared.xcconfig` が定義済みの
  `OTEGAMI_URL_SLASHES` マクロを使い、
  `OTEGAMI_PUSH_RELAY_URL = https:$(OTEGAMI_URL_SLASHES)relay.example.test`
  の形式で書くこと (`Config/Local.xcconfig.sample` に実例がある)。GitHub
  secret と Xcode Cloud には**素の URL をそのまま**登録する — ワーク
  フロー側 (`.github/workflows/release-macos.yml`/
  `apps/Otegami/ci_scripts/ci_post_clone.sh`) がこの形式へ自動変換する。
- 3箇所のうち抜けがあると、その配布経路のビルドだけプッシュ通知が使え
  ない (画面に「このビルドにはプッシュ中継サーバーが設定されていません」
  と出る)。
- ローカルビルドでの設定手順は `Config/Local.xcconfig.sample` を、
  Xcode Cloud 側の設定手順は [`docs/xcode-cloud.md`](xcode-cloud.md) を
  参照。

## 未設定時の挙動 (段階的な機能低下)

リレー URL・登録シークレットのいずれかがビルドに設定されていない場合、
設定画面の「プッシュ通知を有効にする」トグルは単に無効化される — アプリ
自体は正常に動作し、それ以外の機能に影響はない。これはフォーク元や自分
でビルドする開発者がリレーを持っていなくても困らないようにする意図的な
設計であり、エラーではない。

## 反映の順序 (シークレットのローテーション/初回設定)

`RELAY_DEVICE_REGISTRATION_SECRET`/`OTEGAMI_RELAY_REGISTRATION_SECRET`
を初めて設定する、または値をローテーションするときは、**必ずリレー側を
先に設定・再デプロイしてから、アプリのビルド設定 (Local.xcconfig/GitHub
secret/Xcode Cloud 環境変数) に同じ値を設定して次のビルドを配布する**
こと。これは標準運用ルールであり、逆順で行うとエラーになる:

- `POST /v1/devices` (新規デバイス登録) は設計上、デバイスが最初の資格
  情報を得るための入口であるため認証を要求できない。
  `RELAY_DEVICE_REGISTRATION_SECRET` はこの入口を運用者共有シークレット
  の Bearer 認証で塞ぐ仕組みで、リレー側がこの値を要求し始めた時点から、
  まだ古い (シークレット未設定の) ビルドを使っている端末の新規デバイス
  登録がすべて 401 で失敗するようになる。
- 逆に、**アプリ側を先に配布**した場合は、新しいビルドが送る
  `Authorization: Bearer <値>` をリレー側がまだ検証していない (無認証を
  許可したまま) だけなので安全に許容される — 新規登録・再登録が失敗する
  期間が生じない。
- 影響を受けるのは新規のデバイス登録 (初回のプッシュ通知有効化、または
  端末再インストール後の再登録) のみ — 既に登録済みのデバイスのトークン
  更新・watch 操作には影響しない。

## セキュリティ設計

このリレーは、自分 (またはプッシュ通知を有効にした人) の IMAP 資格情報
(パスワードまたは OAuth refresh token) を**平文で受け取り**、サーバー側
で暗号化して保持する。以下は現在の設計とその前提。

1. **何を預かるか**: `POST /v1/watches` の `auth.secret` — `.password`
   watch なら IMAP パスワード、`.oauth` watch (Gmail/Outlook) なら OAuth
   refresh token。**既定では**件名・本文などのメール内容は一切扱わない —
   push ペイロードは `accountId`/`uidNext` のみで、実際の内容は
   `NotificationService` Extension が改めて IMAP に接続して取得する
   (上記「リレーが何をするか」参照)。`RELAY_CONTENT_PREVIEW=1` を明示的に
   設定した運用者のリレーはこの前提が変わる — 下記「`RELAY_CONTENT_PREVIEW`
   (opt-in の内容プレビュー)」参照。
2. **保存時の扱い**: `RELAY_MASTER_KEY` による AES-256-GCM で暗号化して
   SQLite に保存する。鍵はプロセスの環境変数にしか存在せず、ディスクに
   書かれるのは暗号文のみ。DB ファイルが単独で流出しても、環境変数
   (=鍵) が別途漏れない限り資格情報は読めない。
3. **デバイス認証**: `deviceSecret` はハッシュ (SHA-256) のみを保存し、
   平文はレスポンスで一度返した後サーバー側からは復元できない。以降の
   全リクエストは `Authorization: Bearer <deviceSecret>` で認証する。
   `GET`/`DELETE /v1/watches/:id` は呼び出した device 自身の購読
   (`watch_subscription` 行) だけを対象にし、他 device の購読を削除・
   参照することはできない。**Task #208 以降の補足**: 同じ IMAP アカウン
   ト (同一 host/port/TLS/username/authType/mailbox) を複数 device が
   `watch` として登録すると、内部的には 1本の IMAP 接続 (`watch` 行) を
   複数 device が共有する — device ごとの分離は「その device がその
   watch を購読しているかどうか」の単位で保たれ、他 device の資格情報や
   購読状況そのものは (元々 API で一切返されないため) やはり見えない。
4. **削除のタイミング**: `DELETE /v1/watches/:id` は呼び出した device の
   購読行を DB から物理削除する (論理削除ではない)。**Task #208 以降**:
   その watch を購読している device が他にいなければ、この時点で暗号化
   された資格情報ごと watch 行自体もサーバーから即時に消える。他 device
   がまだ同じ watch を購読している場合は、資格情報は (その device が
   引き続き必要とするため) 残り、削除した device の購読関係だけが消える
   — 「即座に全消去」ではなく「最後の1台が削除した時点で全消去」に
   なった点に注意。アプリはアカウント削除時にもこれを呼ぶ。
5. **通信経路**: `POST /v1/watches` は資格情報を運ぶため、アプリ側は
   リレー URL に https を強制する (ローカル開発の `http://localhost` の
   み例外)。手前の TLS 終端は上記「HTTPS の終端」参照。
6. **信頼境界**: このリレーを運用する人は、登録された全アカウントの
   IMAP 資格情報 (=事実上メールへのフルアクセス) を (暗号化された形で
   はあるが) 自分のサーバー上で預かることになる。第三者が運用するリレー
   を使う場合、その運用者を信頼できるかどうかを利用者自身が判断する
   必要がある — otegami が「セルフホスト可能」を前提にしているのはこの
   ため。`.oauth` watch (Gmail/Outlook) はこのリスクがさらに大きい —
   refresh token はユーザーがパスワードを変更しても失効しないため、侵害
   に気づいてパスワードを変えるという通常の対処が効かない。万一の侵害が
   疑われる場合、ユーザーは Google
   ([myaccount.google.com/permissions](https://myaccount.google.com/permissions))/
   Microsoft ([account.live.com/consent/Manage](https://account.live.com/consent/Manage))
   の「サードパーティアプリのアクセス」からこのアプリのアクセスを直接
   取り消せる。
7. **認証失敗時の自動停止**: 一度も接続に成功したことがない watch は、
   IMAP ログインが連続 (既定3回) して失敗すると自動的に監視を停止する —
   資格情報の登録ミスで無限に再試行し続けることを避けるため。一方、
   **過去に一度でも接続に成功した watch は単純な認証エラーでは停止しない**
   — パスワード変更ではなく一時的なアカウントロック (Yahoo! 等) の
   可能性があるため、リトライ間隔を倍々 (上限1時間) に空けながら回復を
   待ち続ける (Task #187、`pool.go` の `shouldGiveUpAfterAuthFailure`
   参照)。`.oauth` watch は、refresh token 自体が失効/取り消し済み
   (`invalid_grant`) と分かった時点で接続成功歴に関係なく即座に停止する。
8. **デバイス登録の保護**: `RELAY_DEVICE_REGISTRATION_SECRET` を設定
   すると、`POST /v1/devices` を運用者共有シークレットの Bearer 認証で
   保護できる (上記「反映の順序」参照)。未設定の間は無認証のままだが、
   無認証の登録が起きるたびにリレーが warning ログを出す。**限界**:
   バイナリに埋め込んだ値はリバースエンジニアリングで抽出可能なので、
   これは「正当なユーザーだけを通す」決定的な認証ではなく、無認証で
   自動化された大量デバイス登録を弾くための実務的な措置にとどまる。
9. **watch 作成時/接続時の SSRF 防御**: `POST /v1/watches` の
   `imapHost`/`imapPort` はリレーの `RelayNetworkPolicy` (Go 版:
   `internal/security/network_policy.go`) で検証される:
   - ホストを解決し、ループバック・リンクローカル (169.254.0.0/16,
     fe80::/10)・プライベート (RFC1918, ULA fc00::/7)・マルチキャスト・
     未指定 (0.0.0.0/::) を拒否する (既定。IPv4-mapped IPv6 表記での
     迂回も防ぐ)。
   - ポートを 143/993 (+ `RELAY_EXTRA_IMAP_PORTS` で追加した集合) に
     制限する。
   - 接続のたびに (作成時だけでなく再接続のたびに) 同じ検証を再実行し、
     検証した解決先アドレスへそのまま接続する (2回目の名前解決をしない)
     — DNS リバインディング対策。
   - IMAP サーバーがリレーと同じプライベートネットワーク上にある構成を
     使う場合は `RELAY_ALLOW_PRIVATE_IMAP_HOSTS=1` で明示的にオプトイン
     する。
10. **IMAP コマンド行への CRLF インジェクション防御**: `imapUsername`/
    `auth.secret`/`mailbox` に埋め込まれた CR/LF/NUL などの制御文字は、
    `POST /v1/watches` の時点と、実際に IMAP コマンド行へ書き込む直前の
    2箇所で拒否する (エスケープではなく 400/接続エラー) — IMAP の
    `quoted-string` 文法はそもそも CR/LF を運べないため、エスケープでは
    なく拒否が正しい対処 (Go 版: `internal/security/imap_validate.go`)。
11. **`GET /v1/watches` の公開範囲**: このエンドポイントが返す
    `status`/`lastConnectedAt`/`lastErrorKind`/`lastErrorAt` はいずれも
    「watch がいつ・どう繋がらなかったか」という粗い分類情報のみで、
    IMAP 資格情報・メール本文・件名を一切含まない。項目3の Bearer
    `deviceSecret` 認証・自デバイスの watch のみ返す制約もそのまま適用
    される。
12. **メモリ枯渇対策**: `imapHost`/`imapPort` で指定された IMAP サーバー
    (悪意ある、または単に壊れたピア) が応答を返さない/異常な応答を送り
    続けた場合にリレー全体を OOM で落とせないよう、IMAP クライアントは
    コマンドごとに集める未タグ付き行数・合計バイト数・壁時計デッド
    ライン、行フレーミングの最大長、受信済み未消費行の内部バッファに
    それぞれ上限を持つ。超過時は接続をエラーで切断し、通常の再接続
    バックオフに委ねる (watch 自体は自動停止しない)。

## `RELAY_CONTENT_PREVIEW` (opt-in の内容プレビュー)

**既定は off**。設定しない限り、上記「リレーが何をするか」「セキュリティ
設計」に書いた「リレーはメール内容を一度も扱わない」という前提はそのまま
成り立つ。`RELAY_CONTENT_PREVIEW=1`/`true`/`yes` (大文字小文字を区別
しない) を明示的に設定した運用者のリレーだけが、以下の挙動に変わる。

### 何が変わるか

1. 新着検知時 (IDLE/polling いずれの経路でも)、push を送る前に、その watch
   の**既に認証済みの同一 IMAP 接続上**で `UID FETCH` を1回発行し、新しい
   方から最大10通ぶんのヘッダー (From/Subject/Date/Message-ID/Content-Type
   等) と本文の先頭 32KB を取得する。新しい接続は開かない。
2. 取得できた中で最新の1通の差出人名・差出人アドレス・件名を push
   ペイロードに同梱する (`latestFromName`/`latestFromAddress`/
   `latestSubject`/`latestUid`/`previewCount`)。件名・差出人名は
   UTF-8 境界を壊さずそれぞれ 100B/300B に切り詰めてから同梱する。
   取得した全件 (最大10通) は下記の通り暗号化してキャッシュする。
3. 新しい `GET /v1/messages?accountId=<id>&sinceUid=<n>` エンドポイント
   (Bearer `deviceSecret` 認証、`watch_subscription` で自 device の
   accountId にのみ解決) で、そのキャッシュを uid 降順で最大10件取得
   できる。`RELAY_CONTENT_PREVIEW` が off のリレーではこのエンドポイントは
   常に 404 を返す (未知の accountId と区別できない同じ 404 — 「見せる
   ものがない」という点でどちらも同じであり、他 device の存在や機能の
   on/off を推測させないための意図的な設計)。
4. IMAP FETCH が失敗した場合 (タイムアウト、`[LIMIT]` レート制限応答を
   含む) や、対象範囲に1件もプレビューが得られなかった場合は、ログに
   残した上で `RELAY_CONTENT_PREVIEW` が off のときと同じ内容なし push に
   フォールバックする — 内容プレビューの失敗が「新着を検知した」という
   push 自体を失わせることはない。

### 何が保存されるか、どう暗号化されるか

SQLite の `message_preview` テーブル (`watchId`, `uid`, `encryptedContent`,
`fetchedAt`) に、watch ごと最大50件・`fetchedAt` から48時間まで保持する
キャッシュとして保存する (超過分は取得のたびに自動的に prune される)。
`uid` はプルーニング/範囲検索のため平文で持つが、差出人名・差出人アドレス・
件名・本文プレビュー・Message-ID・日付は `watch.encryptedSecret` と同じ
`RELAY_MASTER_KEY` ベースの AES-256-GCM (`CredentialCrypto`) で暗号化して
保存する — IMAP 資格情報と同じ鍵・同じ強度で、メール内容そのものも保護
される。

### プライバシー上の意味

`RELAY_CONTENT_PREVIEW=1` を設定すると、このリレーの「信頼境界」
(上記セキュリティ設計・項目6) が実質的に広がる — これまでは IMAP
資格情報 (=事実上メールへのフルアクセス) だけを預かる設計だったが、
この機能を有効にすると**新着メールの実内容 (差出人・件名・本文の一部)
がリレーのディスク上に (暗号化された状態で) 一時的に複製される**。
資格情報さえ預ければ運用者が原理的にいつでも内容を読めることは
変わらないが、内容プレビューは「読もうと思えば読める」から「実際に
処理・一時保存する」への変更であり、以下を運用者は理解した上で
opt-in すること:
- `RELAY_MASTER_KEY` が漏れた場合の実害が広がる (資格情報だけでなく、
  直近のメール内容の一部も復号可能になる)。
- push ペイロードにも差出人・件名の断片が乗るため、APNs 経由の配送
  経路 (Apple のサーバーを含む) を通過する情報が増える。
- セルフホストではなく第三者が運用するリレーを使っている場合、この
  設定はその運用者側の判断であり、利用者は自分のリレーでない限り
  on/off を選べない。

有効にする前に、この機能を必要とする理由 (通知に内容プレビューを
出したい) と上記のトレードオフを比較して判断すること。無効 (既定) の
ままでも、通知タップ後にアプリを開けば通常通りメール内容は読める —
この機能は「通知バナー/ロック画面に内容の一部を出す」ためだけのもの。

## モニタリング / ログ

push 送信のたびに構造化ログを出す (`docker compose logs -f
otegami-relay`)。実 APNs 配信を使う場合、成功時 ("APNs push
accepted")・失敗時 ("APNs push rejected"、APNs が返す JSON エラー
ボディ付き) の両方をログに残す。watch の接続確立・切断・再接続・認証
失敗停止もログに残る。件名・本文・IMAP パスワードはログに一切出力
しない (デバイストークンは先頭/末尾4文字以外を伏せる)。`accountId` は
ログ出力前に制御文字を `?` に置換する — 検証済みの値のはずだが、その
検証を経ないパスから来た値でもログレコード偽造ができないための二重の
防御線。

## 既知の制約

- IMAP 実装は最小限の自前クライアント (`internal/imapclient/`) — LOGIN/
  AUTHENTICATE XOAUTH2/SELECT/STATUS/IDLE/LOGOUT に加え、
  `RELAY_CONTENT_PREVIEW` 用の `UID FETCH` (IMAP literal 読み取り込み)
  のみ対応する。ENVELOPE/BODYSTRUCTURE の括弧文法パーサは持たない —
  `UID FETCH` 応答から UID アトムと2個の literal (ヘッダー/本文) の
  対応付けだけをパースする設計 (`internal/imapclient/preview_parse.go`)。
- IDLE 非対応サーバーへの polling 実装は、素朴な「スリープしてから
  コマンドを打つ」だけだと隠れた高頻度 LOGIN を生みアカウントロック
  という実害につながる — 現在の実装と教訓は
  [`docs/architecture.md`](architecture.md#c-idle-非対応の-imap-サーバーには-noop-キープアライブが必須)
  の Known pitfalls (c) を参照。
- 実 APNs 配信・実機での通知受信確認は `.p8` 発行後、上記手順で行う。
- **Task #208 (watch のデバイス間統合) をまたいでリレーをアップグレード
  する場合**: `watch` テーブルのスキーマを変更した (`deviceId`/
  `accountId` を watch 行から切り出し、複数 device が同一 IMAP 接続を
  共有できるようにした) ため、Task #208 より前のバイナリが作った
  `watch` 行は起動時に自動検出されテーブルごと破棄される (行ごとの移行
  は行わない — 判断の理由は
  [`docs/architecture.md`](architecture.md#i-imap-の-limit-応答は接続エラーではない--再接続すると別の障害を誘発する)
  の Task #208 追記を参照)。影響を受けるのは既存の watch 登録のみで、
  `device` 行 (deviceId/deviceSecret) は無傷 — アプリ側
  `WatchReconciler` が次の起動/フォアグラウンド時に `GET /v1/watches`
  を ground truth として全 watch を自動的に再登録するため、エンドユー
  ザーの手動操作は不要。ただし次にアプリが起動するまでの間、新着メール
  の push 通知が届かない空白期間が生じる。通信の形 (wire format) 自体は
  変えていないので、アプリ側のアップデートは不要 — リレーだけを更新
  すればよい。
