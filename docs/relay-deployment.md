# otegami-relay デプロイ手順 (M9)

otegami のプッシュ通知は、セルフホストする「リレーサーバ」(`server/otegami-relay`)
が IMAP IDLE でアカウントを監視し、新着を検知すると APNs 経由でデバイスに
プッシュを送る、という構成で動く。本アプリのビルド元がこのサーバを自分で
運用する前提 (OSS で Apple Developer アカウント・APNs 認証情報を配布できない
ため)。本書はそのデプロイ手順・環境変数・脅威モデルをまとめる。

## 前提: APNs の `.p8` キーは未発行

`PENDING.md` の「M9: APNs .p8 キー発行」参照。`.p8` キーがない状態でも、
`APNS_*` 環境変数を未設定のまま起動すれば `ConsolePushSender` にフォール
バックし、「IDLE 監視 → 新着検知 → push 発火」までの全パイプラインをログ
出力で確認できる (実際に端末へ通知が届く手前まで)。実 APNs 配信を有効に
するには `.p8` を発行し、下記の環境変数を設定すること。

## デプロイ手順

### 1. `.p8` キーの発行 (実 APNs 配信を使う場合のみ)

`PENDING.md` の手順を参照。[Apple Developer](https://developer.apple.com/account/)
の「証明書、識別子とプロファイル」→「キー」で APNs 用キーを新規作成し、
`.p8` ファイル・Key ID・Team ID を控える。アプリの Bundle ID
(既定 `com.mtkg.otegami`、`Config/Signing.xcconfig` で変更可) も控える。

### 2. `RELAY_MASTER_KEY` の生成

IMAP 資格情報を暗号化して保存するための AES-256 鍵。32 byte を base64 で:

```sh
openssl rand -base64 32
```

この値は**絶対にリポジトリにコミットしない**。紛失するとリレーに登録
済みの全 watch の IMAP 資格情報が復号不能になる (=実質的に全 watch が
壊れる。ユーザー側は各自 watch を作り直せばよいので、鍵のバックアップは
必須ではないが、紛失時は「全アカウントで再度プッシュ通知を有効化し直す」
運用になる)。

### 3. 環境変数の設定

`server/otegami-relay/.env.sample` を `.env` にコピーして編集する:

```sh
cp server/otegami-relay/.env.sample server/otegami-relay/.env
# .env を編集: RELAY_MASTER_KEY を必須で設定。APNS_* は任意 (後述)。
```

| 変数 | 必須 | 説明 |
|---|---|---|
| `RELAY_MASTER_KEY` | ○ | IMAP 資格情報の暗号化鍵 (base64, 32 byte)。手順 2 参照。 |
| `RELAY_DATABASE_PATH` | - | SQLite ファイルパス。既定 `otegami-relay.sqlite` (Docker では `/app/data/otegami-relay.sqlite`、`docker-compose.yml` の named volume に永続化)。 |
| `RELAY_PORT` | - | HTTP リッスンポート。既定 `8080`。 |
| `APNS_KEY_PATH` | - | `.p8` ファイルのコンテナ内パス。4 つ全て設定して初めて実 APNs 配信 (`APNsSender`) が有効になる。1 つでも欠けると `ConsolePushSender` にフォールバックする。 |
| `APNS_KEY_ID` | - | `.p8` の Key ID。 |
| `APNS_TEAM_ID` | - | Apple Developer の Team ID。 |
| `APNS_BUNDLE_ID` | - | アプリの Bundle ID (`apns-topic` として使う)。 |
| `RELAY_DEVICE_REGISTRATION_SECRET` | - | `POST /v1/devices` を保護する運用者共有シークレット。設定すると `Authorization: Bearer <この値>` が無い/不一致の登録要求を 401 にする。未設定 (既定) の場合は従来どおり無認証で登録できる — 詳細は下記脅威モデルの 8 番参照。 |
| `RELAY_EXTRA_IMAP_PORTS` | - | `POST /v1/watches` が受理する IMAP ポートを既定の 143/993 に加えて広げる (カンマ区切り、例 `1143,2143`)。ポート転送した自宅サーバーなど非標準ポート運用のときのみ設定する。 |
| `RELAY_ALLOW_PRIVATE_IMAP_HOSTS` | - | `1` にすると `POST /v1/watches` がループバック/リンクローカル/プライベート (RFC1918/ULA) の IMAP ホストを受理するようになる。IMAP サーバーがリレーと同じプライベートネットワーク上にある場合のみ設定する — 既定 (未設定) はこれらを拒否する。詳細は下記脅威モデルの 9 番参照。 |

### 4. 起動 (Docker)

```sh
make relay-docker   # イメージのビルド (リポジトリルートが build context)
cd server/otegami-relay
docker compose up -d
curl http://localhost:8080/health   # "ok" が返れば起動成功
```

`.p8` を使う場合は `server/otegami-relay/secrets/` (既定、`.env` の
`APNS_KEY_DIR` で変更可) に配置し、`APNS_KEY_PATH` をコンテナ内パス
(`/app/secrets/AuthKey_XXXXXXXXXX.p8` など) に設定する。この
ディレクトリはリポジトリにコミットしない (`.gitignore` 参照)。

### 5. 起動 (Docker を使わない場合)

```sh
cd server/otegami-relay
export RELAY_MASTER_KEY=$(openssl rand -base64 32)
swift run OtegamiRelay
```

### 6. HTTPS の終端

このサーバ自体は平文 HTTP しか話さない。アプリ側は「リレー URL は https
必須 (ローカル開発時のみ http://localhost 許可)」という制約を UI で強制
するため、公開運用では手前に reverse proxy (Caddy/nginx/Cloudflare
Tunnel 等) を置いて TLS を終端すること。IMAP 資格情報を平文で送信する
エンドポイント (`POST /v1/watches`) がある以上、これは必須の手順。

### 運用例: 宅内サーバー (自前 CA + reverse proxy) での運用

パブリックな証明書 (Let's Encrypt 等) を取得しない、家庭内 LAN / VPN
(Tailscale 等) だけに閉じた運用の一例。前提として、上記「6. HTTPS の
終端」の reverse proxy を、パブリック CA ではなく**自前のプライベート CA**
で発行した証明書で構成する。

- reverse proxy (nginx/Caddy 等) に、家庭内向けドメイン (例
  `*.home.example` のようなワイルドカード) 用の証明書をプライベート CA で
  発行して設定する。パブリックな DNS 登録は不要 — 宅内 DNS (Pi-hole 等) や
  `/etc/hosts` 相当で名前解決できれば十分。
- リレー自体は「6. HTTPS の終端」の手順どおり平文 HTTP のまま起動し、
  reverse proxy が TLS を終端してリレーの `RELAY_PORT` にプロキシする。
- **iOS 側の追加作業が必須**: iOS はプライベート CA をデフォルトでは
  信頼しないため、実機ごとに以下を行わないとアプリからの HTTPS 接続が
  証明書エラーで失敗する。
  1. CA のルート証明書ファイル (`.cer`/`.pem`) を実機に転送する
     (AirDrop、メール添付、Files.app 経由など)。
  2. 開いて構成プロファイルとしてインストールする
     (設定 →「プロファイルがダウンロード済み」または
     設定 → 一般 → VPN とデバイス管理)。
  3. **設定 → 一般 → 情報 → 証明書信頼設定** で、インストールした
     ルート証明書を明示的に有効化する。プロファイルのインストールだけ
     では信頼されず、この手順を忘れると TLS ハンドシェイクが失敗し
     続ける (見落としやすい典型的なハマりどころ)。
- 運用者が変わるたびにこの手順を各デバイスで繰り返す必要がある点が、
  パブリック CA 運用との一番の違い。個人利用や家族内での小規模運用では
  現実的なトレードオフだが、不特定多数に配る前提のリレーには向かない。

### アプリ側の設定

アプリの「設定」→「プッシュ通知」で、上記でデプロイしたリレーの URL
(例 `https://relay.example.com`) を入力し、「有効化」を押す。同意文言
(下記の脅威モデル参照) を確認した上で:

1. 通知の認可 (`UNUserNotificationCenter`) をリクエスト
2. APNs デバイストークンを取得 (実機のみ。シミュレータでは取得できない
   — `PENDING.md` 参照)
3. `POST /v1/devices` でデバイス登録、`deviceSecret` を Keychain に保存
4. 設定済みの各アカウントについて `POST /v1/watches` で IMAP 資格情報を
   送信し watch を作成

無効化すると、登録した全 watch を `DELETE /v1/watches/:id` で削除し、
サーバ側の資格情報を即座に消去する。アカウント削除時も同様に連動して
その watch を削除する。

**watch の照合掃除 (M9 follow-up)**: アカウント削除時の `DELETE
/v1/watches/:id` はベストエフォート (`try?`) でリトライが無いため、
その瞬間リレーに到達できなければ削除済みアカウントの watch がリレー
上に残り続けるバグがあった。これを自己修復するため、アプリは起動/
フォアグラウンド復帰のたびに (1日1回程度に間引き) `GET /v1/watches`
(Bearer deviceSecret、そのデバイスの watch のみ、資格情報は返さない)
でリレー側の実際の watch 一覧を取得し、ローカルのアカウント一覧と
突き合わせて孤児 watch の削除・欠落 watch の再登録・ローカル
accountId→watchId マップの修復を行う (`AppEnvironment
.reconcilePushWatchesIfNeeded()`、詳細は `docs/verify.md`「プッシュ
通知まわりの恒久修正2件」参照)。

## 脅威モデル

このサーバは、自分（またはプッシュ通知を有効にした人）の IMAP 資格情報
(パスワードまたは Gmail refresh token) を**平文で受け取り**、サーバ側で
暗号化して保持する。以下はその設計上の前提と緩和策。

1. **何を預かるか**: `POST /v1/watches` の `auth.secret` (IMAP パスワード、
   将来的には OAuth refresh token)。件名・本文などのメール内容は一切
   扱わない — push ペイロードは `accountId`/`uidNext` のみで、
   `NotificationService` Extension が改めて IMAP に接続して差出人・件名
   を取得する (プラン §7 のプライバシー設計)。
2. **保存時の扱い**: `RELAY_MASTER_KEY` による AES-256-GCM で暗号化して
   SQLite に保存する (`CredentialCrypto`)。鍵はプロセスの環境変数にしか
   存在せず、ディスクに書かれるのは暗号文のみ。DB ファイルが単独で
   流出しても、環境変数 (=鍵) が別途漏れない限り資格情報は読めない。
3. **デバイス認証**: `deviceSecret` はハッシュ (SHA-256) のみを保存し、
   平文はレスポンスで一度返した後サーバ側からは復元できない。以降の
   全リクエストは `Authorization: Bearer <deviceSecret>` で認証する。
   watch は作成した device にのみ紐付き、他 device からの
   削除・参照はできない (`WatchRoutesTests` で検証済み)。
4. **即時ワイプ**: `DELETE /v1/watches/:id` は該当行を DB から物理削除
   する (論理削除フラグではない) — 呼び出し直後、暗号化された資格情報
   ごとサーバから消える。アプリはアカウント削除時にもこれを呼ぶ。
5. **通信経路**: `POST /v1/watches` は資格情報を運ぶため、アプリ側は
   リレー URL に https を強制する (ローカル開発の `http://localhost` の
   み例外)。手前の TLS 終端はデプロイ手順の 6 を参照。
6. **信頼境界**: このリレーを運用する人は、登録された全アカウントの
   IMAP 資格情報 (=事実上メールへのフルアクセス) を(暗号化された形で
   はあるが)自分のサーバ上で預かることになる。第三者が運用するリレー
   を信頼して使うのはこの意味でリスクがある — otegami が「セルフホスト
   可能」を前提にしているのはこのため。第三者が運用するリレーに登録
   する場合、その運用者を信頼できるかどうかを利用者自身が判断する
   必要がある(アプリの同意文言でもこの旨を明示する)。
7. **認証失敗時の自動停止**: IMAP ログインが連続して失敗した watch は
   自動的に監視を停止する (`WatcherPool`) — パスワード変更後に古い
   資格情報で IMAP サーバへの再試行を無限に繰り返し、アカウント
   ロックアウトを誘発することを避けるため。
8. **デバイス登録の保護 (Task #169, CLAUDE-SECURITY F2)**: `POST
   /v1/devices` は設計上 (デバイスが最初の資格情報を得るための入口な
   ので) 認証を要求できない。これを悪用すると、リレーの HTTP ポートに
   到達できる誰でも `deviceSecret` を自己発行し、以降の `POST
   /v1/watches` に到達できてしまう。`RELAY_DEVICE_REGISTRATION_SECRET`
   を設定すると、この入口を運用者共有シークレットの Bearer 認証で
   塞げる。未設定の間は従来どおり無認証のままだが (既存デプロイを
   即座に壊さないため、かつアプリ側がまだこのヘッダを送る実装を
   持たないため — `HUMAN_TASKS.md`/`PENDING.md` 参照)、無認証の
   登録が起きるたびにリレーが warning ログを出す。
9. **watch 作成時/接続時の SSRF 防御 (Task #169, CLAUDE-SECURITY F2)**:
   修正前は `POST /v1/watches` の `imapHost`/`imapPort` が検証なしで
   `ClientBootstrap.connect` に渡っており、リレーの HTTP ポートに到達
   できる者がリレー自身のネットワーク (ループバック・Docker ブリッジ・
   LAN・クラウドのメタデータ endpoint) へ任意の TCP 接続を張らせられた
   (`MinimalIMAPClient` の CRLF インジェクション (項目 10 参照) と組み
   合わせると、そこに任意の行プロトコルを送り込むブラインドな踏み台に
   もなり得た)。`RelayNetworkPolicy` がこれを閉じる:
   - `POST /v1/watches` 時点でホストを解決し、ループバック・リンク
     ローカル (169.254.0.0/16, fe80::/10)・プライベート (RFC1918,
     ULA fc00::/7)・マルチキャスト・未指定 (0.0.0.0/::) を拒否する
     (既定。IPv4-mapped IPv6 表記での迂回も防ぐ)。
   - ポートを 143/993 (+ `RELAY_EXTRA_IMAP_PORTS` で運用者が追加した
     集合) に制限する。
   - 接続のたびに (watch 作成時だけでなく再接続のたびに) 同じ検証を
     再実行し、かつ検証した解決先アドレスへそのまま接続する (2 回目の
     名前解決をしない) — DNS リバインディング対策。
   - IMAP サーバーがリレーと同じプライベートネットワーク上にある構成
     (本書「宅内サーバー」の例など) を使う場合は
     `RELAY_ALLOW_PRIVATE_IMAP_HOSTS=1` で明示的にオプトインする。
     既存の watch (この修正より前に作成されたもの) はこの検証の対象
     外 — 起動時の再接続では引き続き動くが、次回以降の**新規**
     watch 作成や、DNS 変更を伴う再接続では新しい制限を受ける。
10. **IMAP コマンド行への CRLF インジェクション防御 (Task #169,
    CLAUDE-SECURITY F3)**: `imapUsername`/`auth.secret`/`mailbox` に
    埋め込まれた CR/LF/NUL などの制御文字は、`POST /v1/watches` の時点
    (`WatchRoutes`) と `MinimalIMAPClient.quoted` (実際に IMAP コマンド
    行へ書き込む直前) の 2 箇所で拒否 (エスケープではなく 400/接続
    エラー) する。IMAP の `quoted-string` 文法はそもそも CR/LF を運べ
    ないため、エスケープではなく拒否が正しい対処。

## モニタリング / ログ

`ConsolePushSender`/`APNsSender` はどちらも push 送信のたびに構造化ログ
を出す (`docker compose logs -f otegami-relay`)。`APNsSender` は成功時
("APNs push accepted")・失敗時 ("APNs push rejected"、APNs が返す JSON
エラーボディ付き) の両方をログに残す — 以前は失敗時のみで、実 APNs 配
信が実際に成功したかどうかをログだけでは確認できなかった。`WatcherPool`
は各 watch の接続確立・切断・再接続・認証失敗停止をログに残す。件名・
本文・IMAP パスワードはログに一切出力しない (`ConsolePushSender`/
`APNsSender` はどちらもデバイストークンを先頭/末尾 4 文字以外は伏せる)。
`accountId` はログ出力前に制御文字を `?` に置換する
(Task #169, CLAUDE-SECURITY F16) — `POST /v1/watches` 時点の検証済み
値のはずだが、その検証を経ないパス (直接 `RelayStore.createWatch` を
呼ぶテスト等) から来た値でもログレコード偽造ができないための二重の
防御線。

## メモリ枯渇対策 (Task #169, CLAUDE-SECURITY F4/F8)

`imapHost`/`imapPort` で指定された IMAP サーバー (悪意ある、または単に
壊れたピア) が応答を返さない/異常な応答を送り続けた場合にリレー全体を
OOM で落とせないよう、`MinimalIMAPClient` は以下を有界化している:

- コマンドごとに集める untagged (`*`) 行数と合計バイト数に上限
  (既定 500 行 / 256KB)、コマンド全体の壁時計デッドライン (既定 90 秒)。
- 行フレーミングの最大長 (既定 8KB) — 超過した接続は切断する。
- 受信済みだが未消費の行を貯める内部バッファも上限あり (既定 2000 行 /
  1MB) — `IDLE` の代わりに 5 分間隔で `STATUS` をポーリングする間の
  「誰も読み出していない」窓を悪用されないため。

いずれも超過時は接続をエラーで切断し、`WatcherPool` の通常の再接続
バックオフに委ねる (watch 自体は自動停止しない — 一時的な相手側の
不調と区別しないため)。

## 既知の制約 / 今後

- v1 の `auth.type` は `password` のみ (plan: "LOGIN/XOAUTH2 なし可: password
  のみ v1")。Gmail アカウントのプッシュ通知には refresh token 対応
  (`xoauth2`) が必要で、M10 以降の課題。
- IMAP 実装は最小限の自前クライアント (`MinimalIMAPClient`) — LOGIN/
  SELECT/STATUS/IDLE/LOGOUT のみ対応。採否の理由は
  `server/otegami-relay/Sources/OtegamiRelay/Watcher/MinimalIMAPClient.swift`
  のドキュメントコメント、および本 M9 の最終報告を参照。M9 リリース後、
  IDLE が正常にタイムアウトするたびに接続が壊れて新着を検知できなく
  なる実バグが本番で発生し修正済み — 原因・修正・追加した実 Dovecot
  向け統合テストの詳細は `docs/verify.md`「otegami-relay: IDLE がタイ
  ムアウトで接続を壊す実バグ」参照。
- 実 APNs 配信・実機での通知受信確認は `PENDING.md` の手順に従い、`.p8`
  発行後に別途行うこと。
