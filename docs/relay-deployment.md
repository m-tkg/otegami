# otegami-relay デプロイ手順 (M9)

otegami のプッシュ通知は、セルフホストする「リレーサーバ」(`server/otegami-relay`)
が IMAP IDLE でアカウントを監視し、新着を検知すると APNs 経由でデバイスに
プッシュを送る、という構成で動く。本アプリのビルド元がこのサーバを自分で
運用する前提 (OSS で Apple Developer アカウント・APNs 認証情報を配布できない
ため)。本書はそのデプロイ手順・環境変数・脅威モデルをまとめる。

## 設定値の全体像 (どれを・どこに・いくつ)

プッシュ通知まわりの設定は **リレー側 (`.env`)** と **アプリ側 (ビルド時に
埋め込む)** に分かれ、アプリ側は配布経路ごとに 3 箇所へ同じ値を入れる必要が
ある。個々の説明は後述の各節にあるが、まず全体像:

### リレー側 — サーバの `.env`

| 変数 | 必須 | 何のため |
|---|---|---|
| `RELAY_MASTER_KEY` | ○ | 預かった IMAP 資格情報 / リフレッシュトークンの暗号化 |
| `APNS_KEY_PATH` / `APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_BUNDLE_ID` | - | 実 APNs 配信 (4 つ揃って初めて有効) |
| `RELAY_DEVICE_REGISTRATION_SECRET` | - | デバイス登録を保護 (アプリ側の `OTEGAMI_RELAY_REGISTRATION_SECRET` と同じ値) |
| `RELAY_GOOGLE_CLIENT_ID` | - | Gmail の watch (アプリ側の `GOOGLE_OAUTH_CLIENT_ID` と同じ値) |
| `RELAY_MICROSOFT_CLIENT_ID` | - | Outlook の watch (アプリ側の `OTEGAMI_MICROSOFT_CLIENT_ID` と同じ値) |

> **Docker Compose で運用する場合の落とし穴**: `.env` に書いただけでは
> コンテナに渡らない。`docker-compose.yml` の当該サービスの `environment:`
> が**必要なキーだけを明示列挙する**書き方 (`- RELAY_FOO=${RELAY_FOO:-}`)
> になっているなら、**新しい変数を足すたびにその行も追加する**こと。実際に
> 「`.env` に登録シークレットを書いたのに 401 にならない」で一度踏んでいる
> (原因は compose 側の受け渡し漏れと、イメージが古くて機能自体が入って
> いなかったことの二重)。

### アプリ側 — ビルド時に埋め込む (3 箇所すべてに同じ値)

ユーザーがアプリの画面で設定する項目は**無い**。すべてビルド時に埋め込む。

| 値 | ローカル (OTA 配信用) | macOS リリース | TestFlight |
|---|---|---|---|
| リレー URL | `Config/Local.xcconfig` の `OTEGAMI_PUSH_RELAY_URL` | GitHub secret `OTEGAMI_PUSH_RELAY_URL` | Xcode Cloud 環境変数 `OTEGAMI_PUSH_RELAY_URL` |
| 登録シークレット | 同 `OTEGAMI_RELAY_REGISTRATION_SECRET` | 同名の GitHub secret | 同名の Xcode Cloud 環境変数 |
| Google Client ID | 同 `GOOGLE_OAUTH_CLIENT_ID` | GitHub secret `OTEGAMI_GOOGLE_CLIENT_ID` | Xcode Cloud `OTEGAMI_GOOGLE_CLIENT_ID` |
| Microsoft Client ID | 同 `OTEGAMI_MICROSOFT_CLIENT_ID` | 同名の GitHub secret | 同名の Xcode Cloud 環境変数 |

- **`Config/Local.xcconfig` に URL を書くときだけ形式が違う**: xcconfig は
  `//` をコメント開始として扱うため、`https://…` をそのまま書くと値が
  `https:` に切り詰められる。`Config/Local.xcconfig.sample` に載っている
  `https:$(OTEGAMI_URL_SLASHES)…` の形で書くこと。GitHub secret と Xcode
  Cloud には**素の URL をそのまま**登録する (ワークフロー側が変換する)。
- 3 箇所のうち抜けがあると、その配布経路のビルドだけプッシュが使えない
  (画面に「このビルドにはプッシュ中継サーバーが設定されていません」と出る)。
- どれも未設定でもビルドは通り、プッシュ機能だけが無効になる — フォークや
  他のビルダーが困らないようにするための設計。

### 反映の順序

アプリ側とリレー側で値が揃うまでの間、**新規のデバイス登録だけ**が失敗する
(既に登録済みの watch は動き続ける)。安全な順序は:

1. アプリ側の 3 箇所に値を入れる
2. アプリを配布し直す (OTA / タグ)
3. リレー側の `.env` に値を入れて再デプロイ

逆順でも壊れはしないが、その間に初回有効化や再インストールをすると 401 に
なる。

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
| `RELAY_GOOGLE_CLIENT_ID` | - | Task #175 (Gmail の push watch): Gmail の `.oauth` watch がリフレッシュトークンをアクセストークンへ交換する際に使う Google OAuth Client ID。アプリ側の `GOOGLE_OAUTH_CLIENT_ID`/`OTEGAMI_GOOGLE_CLIENT_ID` と**同じ値**を設定する (同じ Client ID が発行したリフレッシュトークンでないと交換できない)。未設定のままだと Gmail の watch は作成できても認証できず、`connectionError` で再試行を繰り返した末に停止する。 |
| `RELAY_MICROSOFT_CLIENT_ID` | - | 同上、Outlook/Office365 用。アプリ側の `OTEGAMI_MICROSOFT_CLIENT_ID` と同じ値。 |

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

**Task #173 follow-up (実機フィードバック 2026-07-30「リレー URL は今の
固定 URL という話をしたよ」) でリレー URL 自体もビルド時埋め込みに変更
した** — Task #171 で登録シークレットをビルド時埋め込みにしたのに URL
の入力欄だけ残っていたのは中途半端、という指摘を受けての変更。今は
Google/Microsoft の OAuth Client ID・`RELAY_DEVICE_REGISTRATION_SECRET`
と同じ仕組みで、`Config/Local.xcconfig` の `OTEGAMI_PUSH_RELAY_URL` (自分の
ビルドをローカルでビルドする場合)・GitHub Actions の
`OTEGAMI_PUSH_RELAY_URL` secret (macOS リリース)・Xcode Cloud の同名の
環境変数 (TestFlight/iOS リリース) のいずれかに運用者自身が設定し、
ビルドのたびに `Info.plist` 経由で `RelayURLConfig` が読み取る。ユーザー
自身がリレー URL を入力する項目は無くなった —
`PushNotificationSettingsView` には「有効にする」/「無効にする」ボタン
と (Task #173) アカウント別の watch 状態一覧しか残らない。この値が
未設定のビルドは「有効にする」ボタンが無効になり、その旨を画面に表示
する。

**xcconfig の `//` コメント問題に注意**: xcconfig 構文は `//` を
コメント開始として扱うため、`OTEGAMI_PUSH_RELAY_URL = https://relay.
example.test` とそのまま書くと値が `https:` で切れてしまう。
`Config/Shared.xcconfig` が定義済みの `OTEGAMI_URL_SLASHES`
(`$(OTEGAMI_URL_SLASH)$(OTEGAMI_URL_SLASH)` — 単一の `/` はコメント扱い
されず、マクロ展開はコメント除去の後に走るため、ソース上に `//` という
並びが一度も現れない) を使って
`OTEGAMI_PUSH_RELAY_URL = https:$(OTEGAMI_URL_SLASHES)relay.example.test`
の形式で書くこと — `Config/Local.xcconfig.sample` に実例がある。CI 側
(`ci_scripts/ci_post_clone.sh`/`.github/workflows/release-macos.yml`) は
secret に入れた素の URL からこの形式を自動生成するので、secret 自体は
普通の URL のままでよい。

有効化前に一度、実際に `Info.plist` へ正しく値が入ることを
`xcodebuild -showBuildSettings`/ビルド後の `Info.plist` を `plutil -p`
で確認しておくと安全 (`https:` で切れていないこと)。

アプリの「設定」→「プッシュ通知」→「有効にする」を押すと、ビルドに
埋め込まれたリレー URL に対して登録が始まる。同意文言
(下記の脅威モデル参照) を確認した上で:

1. 通知の認可 (`UNUserNotificationCenter`) をリクエスト
2. APNs デバイストークンを取得 (実機のみ。シミュレータでは取得できない
   — `PENDING.md` 参照)
3. `POST /v1/devices` でデバイス登録、`deviceSecret` を Keychain に保存
4. 設定済みの各アカウントについて `POST /v1/watches` で資格情報を送信し
   watch を作成 — `.password` アカウントは IMAP パスワード、Gmail/
   Outlook (`.oauth2`) アカウントは Task #175 で OAuth refresh token
   (`AppEnvironment.watchAuth(for:)`)。いずれのアカウント種別も
   `AppEnvironment.isPushWatchCandidate(_:)` が対象を判定する。

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

**アカウント別の watch 状態表示 (Task #173)**: 実機で「3 件の watch の
うち 1 件が IMAP 認証失敗を繰り返して停止した」というリレー側ログが
あっても、アプリの設定画面には*どのアカウント*が止まったのか分かる
手段が無かった。`GET /v1/watches` のレスポンス (`WatchSummary`) に
`status` (`active`/`stopped`)・`lastConnectedAt`・`lastErrorKind`
(`authFailure`/`connectionError`)・`lastErrorAt` を追加し、
`PushNotificationSettingsView` がアカウントごとに「登録済み/未登録/
停止(認証失敗)/対象外」を一覧表示するようにした。`WatcherPool` が
IMAP ログイン成功時に `status=active`+`lastConnectedAt` を、
`maxConsecutiveAuthFailures` (既定 3 回) 到達で `status=stopped`+
`lastErrorKind=authFailure` を、それ以外の接続エラー時は (停止せず)
`lastErrorKind=connectionError` のみを都度 `RelayStore` に永続化する。
停止したアカウントの行から「再登録」を押すと、そのアカウントの watch
だけ削除→作り直し (資格情報を再送信) する — IMAP パスワードや
メール本文がこの API 経由で返ることは一切無い (項目 11 参照)。
2026-07-30 以前の (この機能を持たない) 古いリレーと通信した場合、
`WatchSummary.status` はデコード時に `active` へフォールバックする
(`OtegamiRelayAPI`のドキュメントコメント参照) — 実際には状態を
追跡していない旧リレーの挙動をそのまま反映しているだけで、アプリが
誤情報を作り出すわけではない。

**再登録・無効化の孤児 watch 対策 (Task #174)**: Task #173 の「再登録」
ボタンを実機で使ったところ、新しい watch は正常に接続できたものの、
古い停止済み watch がリレー側に残った (リレーには watch が3件あるのに
アプリの一覧には2件しか出ない)。原因は `reregisterWatch`/
`disablePushNotifications` が削除対象を**ローカルの** `accountWatchMap`
だけから決めていたこと — このマップは直近成功した `createWatch` の
watchId しか覚えておらず、それより前に作られた watch (クラッシュ・
kill・削除失敗などでローカルに反映されなかったもの) がリレーに残って
いても気づけない。修正として、両メソッドとも削除対象をまず
`GET /v1/watches` (リレー側の実態、そのデバイス分にサーバ側でスコープ
済み) から求め、ローカルマップの値も念のため union する
(`WatchReconciler.watchIdsToDelete(forReregisteringAccountId:...)` /
`watchIdsToDeleteForDisable(...)`、`WatchReconcilerTests` でカバー)。
これにより「無効にする」は実質的に「この端末が持つ全 watch を削除する」
という素直な意味になった。

既存の孤児 (例えば異なるビルド/再インストールでデバイス登録自体が
入れ替わり、旧 `deviceId` 配下に残った watch) は、その `deviceSecret`
を端末側がもう持っていないため上記の修正では原理的に触れない —
`GET`/`DELETE /v1/watches/:id` は認証した `deviceSecret` の持ち主の
watch にしかスコープされない設計(項目11参照)であり、それを緩めて
「アカウントIDが一致すれば別デバイスの watch も消せる」ようにするのは
別の端末（別ユーザーの可能性もある）が誤って/悪意を持って他人の watch
を消せてしまう経路を開くことになるため避けた。このような孤児は
オペレーターが `sqlite3`/管理用スクリプトで直接消す運用とする。

**リレー側の自動掃除 (「停止 N 日で自動削除」) は実装しない判断**:
検討はしたが、以下の理由で見送った。
- 「停止」はユーザーが直せる場合が多い (パスワード変更・一時的な
  IMAP 障害) — 自動削除すると、ユーザーが後で認証情報を直して
  「再登録」しようとしたときに watch がまるごと消えており、
  「再登録」ボタンの意味が変わってしまう (単なる再作成ではなく
  history/状態を失った上での新規作成になる)。
- Task #174 の修正で「再登録」「無効化」という*ユーザーが意図した
  操作*のタイミングでの孤児掃除は既にカバーされており、残るのは
  「ユーザーがアプリを一切触らないまま放置された孤児」だけ — これは
  実害 (バッテリー消費・リレー負荷) が小さく、緊急に自動化する理由が
  薄い。
- 自動削除は「ユーザーの与り知らないところで watch が消える」という
  新しい失敗モードを追加する。既存の `reconcilePushWatchesIfNeeded()`
  (M9 follow-up) はローカルのアカウント一覧という*アプリ側の意図*を
  正としてリレー側を合わせ込む設計だが、「N日経過」はアプリ側に対応
  する意図が無い、リレー単独の判断になる点が質的に異なる。
- もし将来的に実装するなら、既定は無効 (環境変数で明示的に有効化する
  形、例えば `RELAY_STALE_WATCH_CLEANUP_DAYS` 未設定なら掃除しない)
  にすべき、というのがここでの結論。`RelayStore` には `lastErrorAt`
  (`status=stopped` 遷移時に記録) がそのまま閾値判定に使えるため、
  実装自体のコストは低い — 現時点で見送っているのは判断の問題であって
  技術的な難しさではない。

## 脅威モデル

このサーバは、自分（またはプッシュ通知を有効にした人）の IMAP 資格情報
(パスワードまたは Gmail refresh token) を**平文で受け取り**、サーバ側で
暗号化して保持する。以下はその設計上の前提と緩和策。

1. **何を預かるか**: `POST /v1/watches` の `auth.secret` — `.password`
   watch なら IMAP パスワード、`.oauth` watch (Task #175、Gmail/Outlook)
   なら **OAuth refresh token**。件名・本文などのメール内容は一切
   扱わない — push ペイロードは `accountId`/`uidNext` のみで、
   `NotificationService` Extension が改めて IMAP に接続して差出人・件名
   を取得する (プラン §7 のプライバシー設計)。項目 12 に `.oauth` watch
   特有のリスクをまとめる。
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
7. **認証失敗時の自動停止**: IMAP ログインが連続 (既定 3 回) して失敗した
   watch は自動的に監視を停止する (`WatcherPool`) — パスワード変更後に
   古い資格情報で IMAP サーバへの再試行を無限に繰り返し、アカウント
   ロックアウトを誘発することを避けるため。Task #175 の `.oauth` watch
   は、refresh token 自体が失効/取り消し済み (`invalid_grant`) と分かった
   時点で**即座に** (3 回を待たずに) 停止する — 死んだ refresh token は
   再試行しても絶対に復活しないため。`WatchSummary.ErrorKind
   .oauthTokenExpired` として区別され、アプリの表示は「停止（再認証が
   必要）」— 直すにはパスワードの再入力ではなく、アカウント編集の
   「再認証」でその Gmail/Outlook アカウントを再接続し、新しい refresh
   token で watch を再登録し直す必要がある。
8. **デバイス登録の保護 (Task #169, CLAUDE-SECURITY F2 / アプリ側は
   Task #171、2026-07-30 follow-up でビルド時埋め込み方式に変更)**:
   `POST /v1/devices` は設計上 (デバイスが最初の資格情報を得るための
   入口なので) 認証を要求できない。これを悪用すると、リレーの HTTP
   ポートに到達できる誰でも `deviceSecret` を自己発行し、以降の
   `POST /v1/watches` に到達できてしまう。`RELAY_DEVICE_REGISTRATION_SECRET`
   を設定すると、この入口を運用者共有シークレットの Bearer 認証で
   塞げる。未設定の間は従来どおり無認証のままだが (既存デプロイを
   即座に壊さないため)、無認証の登録が起きるたびにリレーが warning
   ログを出す。

   **アプリ側の値はビルド時に埋め込む** (Task #171 follow-up): 当初は
   設定 → プッシュ通知の「登録シークレット」欄にユーザー自身が値を
   入力する UI だったが、実機フィードバック「通常のメールアプリは
   そんな設定をユーザーに要求しない」を受けて廃止した。今は
   Google/Microsoft の OAuth Client ID と同じ仕組みで、`Config
   /Local.xcconfig` の `OTEGAMI_RELAY_REGISTRATION_SECRET` (自分の
   ビルドをローカルでビルドする場合)・GitHub Actions の
   `OTEGAMI_RELAY_REGISTRATION_SECRET` secret (macOS リリース)・Xcode
   Cloud の同名の環境変数 (TestFlight/iOS リリース) のいずれかに
   運用者自身が設定し、ビルドのたびに `Info.plist` 経由で
   `RelayRegistrationSecretConfig` が読み取って新規デバイス登録
   (`POST /v1/devices`) のたびに `Authorization: Bearer <この値>` を
   送る。ユーザー自身が設定する項目は無い。**限界**: バイナリに
   埋め込んだ値はリバースエンジニアリングで抽出可能なので、これは
   「正当なユーザーだけを通す」決定的な認証ではなく、無認証で自動化
   された大量デバイス登録を弾くための実務的な措置にとどまる —
   IMAP 資格情報そのものを暗号化して守る 1〜4 番とは守っているものの
   強度が異なる。

   運用者がこの環境変数を設定する場合、**リレー側を先に設定・再
   デプロイしてから、アプリのビルド設定 (Local.xcconfig/GitHub
   secret/Xcode Cloud 環境変数) に同じ値を設定して次のビルドを配布
   すること** (逆順だと、値が入っていない既存ビルドを使っている間は
   新規デバイス登録 — 新規のプッシュ通知有効化や端末再インストール後
   の再登録 — が 401 で失敗し、アプリは「このリレーは登録シークレット
   を要求していますが、このビルドには設定されていません」と表示する。
   既存の登録済みデバイスのトークン更新・watch 操作には影響しない)。
   運用者向け手順は `HUMAN_TASKS.md`「インフラ・運用まわり」、
   ビルド設定の一般的な仕組みは `docs/oauth-setup.md` の Client ID の
   節 (同じ xcconfig パターン) 参照。
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
11. **`GET /v1/watches` の状態フィールド追加公開範囲 (Task #173)**:
    `status`/`lastConnectedAt`/`lastErrorKind`/`lastErrorAt` はいずれも
    「watch がいつ・どう繋がらなかったか」という粗い分類情報のみで、
    IMAP 資格情報・メール本文・件名を一切含まない (`WatchSummary` の
    フィールド一覧そのものが上限 — 項目 3 の「デバイス認証」と同じ
    Bearer deviceSecret 認証・自デバイスの watch のみ返す制約もそのまま
    引き継ぐ)。`WatchRoutesTests`/`RelayStoreTests` で「自分の watch
    だけ返る」「他 device の watch は返らない」「未認証は 401」を検証
    済み。
12. **`.oauth` watch (Task #175: Gmail/Outlook のプッシュ対応) のリスク
    増分**: v1 は IMAP パスワードのみを預かる設計だったが、Task #175 で
    OAuth refresh token も同じ仕組み (`CredentialCrypto` による AES-256-
    GCM 暗号化保存) で預かれるようになった。**このリレーが侵害された
    場合の影響は、パスワード watch より大きい** — refresh token は
    ユーザーがパスワードを変更しても失効しない (Google/Microsoft 側で
    明示的にアクセスを取り消さない限り有効であり続ける) ため、侵害に
    気づいてパスワードを変えるという通常の対処が効かない。侵害された
    リレーは、取り消されるまで対象 Gmail/Outlook アカウントへの継続的な
    読み取りアクセス (IMAP 経由) を持ち続けることになる。緩和策:
    - 項目 8 の `RELAY_DEVICE_REGISTRATION_SECRET` (無許可のデバイス
      自己登録を防ぐ) と項目 9 の SSRF 対策は `.oauth` watch にも同様に
      適用される。
    - 項目 4 の「即時ワイプ」(`DELETE /v1/watches/:id` で暗号化済み
      refresh token ごと物理削除) はここでも同じセーフティネットになる
      — 「無効にする」/アカウント削除は refresh token をリレーから即座に
      消す。
    - アクセストークンへの交換はメモリ上でのみ行い、リレーは refresh
      token 以外の何も追加で永続化しない (`OAuthTokenExchanger`)。
    - refresh token が失効した (`invalid_grant`) watch は項目 7 の通り
      即座に停止する — 死んだトークンをリレーが持ち続けて交換を試み
      続けることはない。
    - 万一の侵害が疑われる場合、ユーザーは Google
      ([myaccount.google.com/permissions](https://myaccount.google.com/permissions))/
      Microsoft ([account.live.com/consent/Manage](https://account.live.com/consent/Manage))
      の「サードパーティアプリのアクセス」からこのアプリのアクセスを
      直接取り消せる — これは refresh token を持つ側 (リレー) に
      連絡が取れない場合でも、ユーザー自身が確実に無効化できる手段。
    - **根本的な緩和策は項目 6 の「信頼境界」と同じ**: `.oauth` watch は
      「自分専用リレー」を前提にするほど安全性が増す。第三者が運用する
      リレーに Gmail/Outlook アカウントの watch を登録することは、その
      運用者に「取り消されるまで有効な、メールへの読み取りアクセス」を
      渡すことに等しい — アプリの同意文言 (`PushNotificationSettingsView`)
      でもこの点を明示している。

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

- v1 の `auth.type` は `password` のみだったが (plan: "LOGIN/XOAUTH2 なし可:
  password のみ v1")、Task #175 で `.oauth` (refresh token + XOAUTH2) を
  追加し、Gmail/Outlook アカウントもプッシュ通知の対象になった —
  脅威モデル項目12参照。iOS の `NotificationService` Extension
  (差出人/件名の書き換え) 側はこのバッチでは対応しておらず、
  `.oauth2` アカウントの push は汎用フォールバック表示のまま — これは
  今後の課題として残っている (`NotificationService.swift`のdoc comment
  参照)。
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
