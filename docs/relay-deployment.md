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
(既定 `com.m-tkg.otegami`、`Config/Signing.xcconfig` で変更可) も控える。

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

## モニタリング / ログ

`ConsolePushSender`/`APNsSender` はどちらも push 送信のたびに構造化ログ
を出す (`docker compose logs -f otegami-relay`)。`WatcherPool` は各 watch
の接続確立・切断・再接続・認証失敗停止をログに残す。件名・本文・IMAP
パスワードはログに一切出力しない (`ConsolePushSender` はデバイストークン
も先頭/末尾 4 文字以外を伏せる)。

## 既知の制約 / 今後

- v1 の `auth.type` は `password` のみ (plan: "LOGIN/XOAUTH2 なし可: password
  のみ v1")。Gmail アカウントのプッシュ通知には refresh token 対応
  (`xoauth2`) が必要で、M10 以降の課題。
- IMAP 実装は最小限の自前クライアント (`MinimalIMAPClient`) — LOGIN/
  SELECT/STATUS/IDLE/LOGOUT のみ対応。採否の理由は
  `server/otegami-relay/Sources/OtegamiRelay/Watcher/MinimalIMAPClient.swift`
  のドキュメントコメント、および本 M9 の最終報告を参照。
- 実 APNs 配信・実機での通知受信確認は `PENDING.md` の手順に従い、`.p8`
  発行後に別途行うこと。
