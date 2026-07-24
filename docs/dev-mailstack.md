# 開発用メールスタック (dev/mailstack)

実アカウント (Gmail/iCloud) を使わずに同期・送信まわりを開発するための、
使い捨ての IMAP + SMTP スタックです。M1 以降の日常開発は基本的にこのスタックを
対象に行います。

- **Dovecot**: IMAP 受信側。テストユーザーでログインし、同期エンジンの開発・検証に使う。
- **Mailpit**: SMTP 受信側 + Web UI。アプリからの送信メールをすべて捕捉する
  (実際のメールアドレスには配送されない)。

## 起動

```sh
make mailstack-up
```

`dev/mailstack/compose.yml` の Dovecot + Mailpit が起動します。データは
`dev/mailstack/data/` に永続化されます (git 管理外)。

## アカウント情報

Dovecot の IMAP テストユーザー (ドメイン `otegami.test`、パスワードは共通):

| ユーザー | パスワード |
|---|---|
| `test1@otegami.test` | `test1234` |
| `test2@otegami.test` | `test1234` |

| プロトコル | ホスト:ポート |
|---|---|
| IMAP | `localhost:1143` |
| IMAPS | `localhost:1993` (自己署名証明書) |

Mailpit の SMTP 送信先 (アプリの SMTP 設定をここに向ける):

| プロトコル | ホスト:ポート |
|---|---|
| SMTP | `localhost:1025` (認証不要) |
| Web UI | http://localhost:8025 |
| REST API | http://localhost:8025/api/v1/ (自動検証に使用) |

### 認証必須の第2 Mailpit (`mailpit-auth`)

`MailCoreSMTPSession.connect` の AUTH 非対応サーバー自動フォールバック
(空でない SMTP ユーザー名でも、サーバーが `AUTH` コマンド自体を拒否
[502/503/504系] した場合は認証なしで再接続する) を検証するには、AUTH を
要求しない上の `mailpit` だけでは不十分 — 「AUTH に対応しているサーバー
では今まで通り認証が効く」ことを実サーバーで確認するための、認証必須の
2つ目の Mailpit インスタンスも `compose.yml` に含まれています。

| プロトコル | ホスト:ポート |
|---|---|
| SMTP (AUTH 必須) | `localhost:1026` |
| Web UI | http://localhost:8026 |
| REST API | http://localhost:8026/api/v1/ |

認証情報は `dev/mailstack/mailpit-auth/users.txt` (htpasswd bcrypt 形式)
に平文コメントで記載: ユーザー名 `smtpauth` / パスワード `smtpauth1234`
(使い捨ての開発用ダミー資格情報、localhost 外には出ません — 上の Dovecot
テストユーザーと同じ位置づけ)。

## サンプルメールの投入

```sh
make mailstack-seed
```

`dev/mailstack/seed/fixtures/*.eml` を `test1`/`test2` の INBOX に投入します。
日本語件名のメールと、スレッド往復 (質問 → 返信)、HTML メール (外部画像入り・
HTML 専用の日本語本文) を含みます。内部的には `docker compose exec dovecot
doveadm save` でメッセージを直接 Dovecot に保存しています (dovecot/dovecot
イメージにはシェルが入っていないため、Maildir への直接配置ではなくこの方式を
採っています)。

**冪等**: 投入前に対象ユーザーの INBOX を `doveadm expunge ... all` で空にして
から投入するため、`make mailstack-seed` を何度実行しても同じ内容になります
(重複しません)。

投入されるメッセージ (`test1@otegami.test`):

| ファイル | 内容 |
|---|---|
| `01-welcome.eml` | ようこそメール (plain) |
| `02-thread-original.eml` | スレッド元メール (plain) |
| `03-thread-reply.eml` | `02` への返信 (plain, In-Reply-To/References あり) |
| `04-newsletter.eml` | ニュースレター (plain, 全角 "Ｆｗｄ：" 件名) |
| `06-html-external-image.eml` | `multipart/alternative` (plain + HTML)、HTML 側に `http://example.com/...` の外部画像を含む — M2 の「画像を表示」バナー検証用 |
| `07-html-only-japanese.eml` | `text/html` のみ (plain パート無し) の日本語本文 — M2 の HTML→テキスト抽出/表示検証用 |

`test2@otegami.test` には `05-test2-welcome.eml` (plain) のみ投入されます。

## 停止

```sh
make mailstack-down
```

## 動作確認の例

IMAP ログイン確認 (Python の `ssl`/`socket` や `openssl s_client -connect
localhost:1993` などで可能):

```
a1 LOGIN "test1@otegami.test" "test1234"
a2 SELECT INBOX
```

送信メールの自動検証 (E2E テストで使う想定):

```sh
curl -s http://localhost:8025/api/v1/messages | jq '.messages[].Subject'
```
