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

## サンプルメールの投入

```sh
make mailstack-seed
```

`dev/mailstack/seed/fixtures/*.eml` を `test1`/`test2` の INBOX に投入します。
日本語件名のメールと、スレッド往復 (質問 → 返信) の 2 通を含みます。
内部的には `docker compose exec dovecot doveadm save` でメッセージを直接
Dovecot に保存しています (dovecot/dovecot イメージにはシェルが入っていないため、
Maildir への直接配置ではなくこの方式を採っています)。

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
