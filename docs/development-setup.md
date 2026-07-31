# 開発環境のセットアップ

このリポジトリを pull した第三者が、ビルド・テスト・実機/シミュレータ
での画面確認までたどり着くための手順をまとめる。日常のビルド/テストの
コマンド一覧は [README_ja.md#開発を始める](../README_ja.md#開発を始める) と
[CONTRIBUTING.md](../CONTRIBUTING.md) にもあるので、そちらと重複しない
セットアップの詳細だけをここに書く。

## 必要なツール

| ツール | 用途 | 備考 |
|---|---|---|
| Xcode 26 以降 (iOS 26 / macOS 26 SDK) | アプリのビルド | App Store の通常配布版で入手可能になった時点のもので問題ない |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | `project.yml` から `.xcodeproj` を生成 | `brew install xcodegen`。`make` の各ターゲットが `xcodegen generate` を自動実行するので、通常は自分で叩く必要はない |
| Docker Desktop など Docker Compose 互換ランタイム | 開発用メールスタック (Dovecot + Mailpit) | 実アカウント無しで同期/送信まわりを開発する場合のみ必要。無くても `make test`/`make mac`/`make ios` は動く |

`make` はリポジトリのルートで実行する。`make mac`/`make ios` は初回、
`xcodegen generate` → `xcodebuild` の順に実行するので、Xcode と
XcodeGen さえ入っていればそのままビルドできる。

## clone 後、最初にやること

```sh
git clone https://github.com/m-tkg/otegami.git
cd otegami
brew install xcodegen
make test   # OtegamiKit の単体テストが green になることを確認
make mac    # まずは未署名の macOS ビルドが通ることを確認
```

`apps/Otegami/Config/Signing.xcconfig` には `DEVELOPMENT_TEAM` が入って
いない（OSS リポジトリに作者個人の値をコミットできないため）。この状態
でも `make mac`（未署名ビルドにフォールバック）と `make ios`
（Simulator は provisioning を要求しない）はそのままビルドできる。

## `Local.xcconfig` の作成 (実機ビルド・OAuth・アプリ内蔵 entitlement を使う場合)

`Config/Local.xcconfig` は git 管理外で、各自の Team ID や OAuth Client
ID などの秘密情報をここに置く。

```sh
cp apps/Otegami/Config/Local.xcconfig.sample apps/Otegami/Config/Local.xcconfig
```

設定できるキーは以下の通り（すべて任意項目 — 使う機能に応じて必要な分
だけ設定する）:

| キー | 用途 | 未設定時の挙動 |
|---|---|---|
| `DEVELOPMENT_TEAM` | Apple Developer の Team ID。`make ios-device`（実機）や、App Group/Keychain 共有まで含めて完全に署名した `make mac` に必要 | `make ios`/`make mac` は未署名ビルドにフォールバックするので、Simulator だけで開発する分には不要 |
| `OTEGAMI_BUNDLE_ID` | Bundle ID の上書き | 既定の `com.mtkg.otegami` を使う（既に別チームが同じ App ID を登録済みの場合のみ変更が必要 — Apple は同一 explicit App ID を2チームに登録できない） |
| `GOOGLE_OAUTH_CLIENT_ID` | Gmail アカウント追加用の OAuth Client ID | 「アカウントを追加」→「Gmail」ボタンが無効化される（他の機能は問題なく動く） |
| `OTEGAMI_MICROSOFT_CLIENT_ID` | Outlook.com/Office365 アカウント追加用の Microsoft (Azure AD) OAuth Client ID | 「アカウントを追加」→「Outlook」/「Office365」ボタンが無効化される |
| `OTEGAMI_MAIL_CLIENT_ENTITLEMENT` | iOS で `com.apple.developer.mail-client` entitlement (デフォルトのメールアプリ化) を有効にするスイッチ (`YES`) | 既定 `NO`。Apple から entitlement の許可を受けた Team でのみ `YES` にすること — 許可前に `YES` にすると provisioning profile の生成に失敗する |

Gmail/Microsoft の Client ID を取得する具体的な手順（Google Cloud
Console / Azure AD でのアプリ登録）は
[docs/oauth-setup.md](oauth-setup.md) を参照。

## ビルド

```sh
make mac          # macOS アプリ、debug ビルド (xcodebuild)
make mac-app       # macOS アプリ、Release ビルドを dist/Otegami.app に生成
make ios           # iOS Simulator ビルド (IOS_SIMULATOR ?= "iPhone 17 Pro Max")
make ios-device    # 登録済みチームで署名した iOS 実機ビルド
make test          # OtegamiKit の単体テスト (packages/OtegamiKit)
```

`xcodegen generate` の後、`apps/Otegami/Otegami.xcodeproj` を Xcode で
直接開いて日常的な開発を進めることもできる。

## 開発用メールスタック (dev/mailstack)

実アカウント (Gmail/iCloud/Outlook 等) を使わずに同期・送信まわりを
開発するための、使い捨ての IMAP (Dovecot) + SMTP (Mailpit) スタック。

```sh
make mailstack-up     # Dovecot + Mailpit を起動
make mailstack-seed   # サンプルメール (日本語・英語フィクスチャ) を投入
make mailstack-down   # スタックを停止
```

テストアカウント: `test1@otegami.test` / `test1234` と
`test2@otegami.test` / `test1234`、`localhost:1143` (平文 IMAP) /
`localhost:1025` (平文 SMTP、[Mailpit](https://github.com/axllent/mailpit)
の Web UI は `http://localhost:8025`)。認証必須の SMTP 経路を検証する
ための2つ目の Mailpit インスタンス (`localhost:1026`) や、IMAPS
(`localhost:1993`) など詳細は [docs/dev-mailstack.md](dev-mailstack.md)
を参照。

アプリの「アカウントを追加」→「その他 (IMAP)」で上記のホスト/ポートを
指定すれば、実アカウント無しで一覧・送受信・同期の動作を確認できる。

## 画面を確認する: `scripts/verify-screen.sh`

このプロジェクトの開発機のシミュレータ環境には、IMAP 接続不能・
XCUITest のタップ不達・連絡先権限ダイアログ・Foundation Models のエラー
という4種類の既知の不調がある（詳細は
[docs/verify.md](verify.md)）。そのため画面の見た目を確認する標準手段
は、タップや実ネットワーク接続に依存しない tap-free 経路
`scripts/verify-screen.sh` を使うことになっている:

```sh
scripts/verify-screen.sh <scenario> [output-filename.png]
```

内部では `xcodebuild build` でアプリだけをビルドし、`simctl install` →
`simctl launch`（DB へのフィクスチャ直接注入フラグ + 画面への直接遷移
フラグを環境変数/起動引数として渡す）→ 数秒待って `simctl io
screenshot` という流れで、XCUITest ランナー自体を起動しない。scenario
名は本文の HTML ダークモード表示や `account-digest`（アカウント別
ダイジェスト画面）など多数用意されている — スクリプト冒頭のコメント、
または `.claude/skills/verify/SKILL.md` を参照。

IMAP 接続そのものを検証したい場合は、シミュレータを介さずホスト macOS
プロセスとして実行する統合テストを使う:

```sh
make mailstack-up
OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter MailCoreIMAPSessionIntegrationTests
```

(`packages/OtegamiKit` ディレクトリ内で実行する。)

## プッシュ通知リレー (otegami-relay) を触る場合

```sh
make server         # otegami-relay をビルド
make server-test     # otegami-relay の単体テスト
make relay-docker    # Docker イメージをビルド
```

セットアップ・デプロイの詳細は
[docs/relay-deployment.md](relay-deployment.md) を参照。

## コミット規約

[Conventional Commits](https://www.conventionalcommits.org/)
(`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`, ...)。詳細は
[CONTRIBUTING.md](../CONTRIBUTING.md) を参照。
