# otegami

[![ci-app](https://github.com/m-tkg/otegami/actions/workflows/ci-app.yml/badge.svg)](https://github.com/m-tkg/otegami/actions/workflows/ci-app.yml)
[![ci-server](https://github.com/m-tkg/otegami/actions/workflows/ci-server.yml/badge.svg)](https://github.com/m-tkg/otegami/actions/workflows/ci-server.yml)

オフラインファーストな iOS/macOS 向けメールクライアント（オープンソース）。
Gmail・iCloud・Yahoo!メール・Yahoo!メール(JAPAN)・Outlook.com/Office365・
任意の IMAP/SMTP アカウントに1つの同期エンジンで接続し、すべてのデータを
ローカルの SQLite (GRDB) に保存して全文検索でき、英文メールは端末内で翻訳・
要約でき、プッシュ通知用のリレーサーバーもセルフホストできます。

iOS 26+ / macOS 26+ 対応、単一の SwiftUI コードベース。English README:
[README.md](README.md)。

> **ステータス: 開発中・実験的段階。** 実際のメールで使う前に下記の
> [ステータス](#ステータス) を確認してください。

<p align="center">
  <img src="docs/assets/screenshot-ios-inbox-light.png" width="32%" alt="統合受信トレイ（ライト、iOS）">
  <img src="docs/assets/screenshot-ios-inbox-dark.png" width="32%" alt="統合受信トレイ（ダーク、iOS）">
  <img src="docs/assets/screenshot-ios-compose.png" width="32%" alt="差出人選択つき作成画面（iOS）">
</p>
<p align="center">
  <img src="docs/assets/screenshot-mac-inbox.png" width="49%" alt="未読バッジつき統合受信トレイ（macOS）">
  <img src="docs/assets/screenshot-mac-thread.png" width="49%" alt="スレッド表示と返信（macOS）">
</p>

## otegami の特徴

個別の機能一覧より先に、このアプリが軸にしている2点を挙げます。

1. **複数アカウントを1つの受信トレイで。** 対応する各種アカウントが同じ
   同期エンジンの上で動き、1つの統合受信トレイに日付順で混ざって並びます。
   タップ1つで特定アカウントだけに絞り込め、アカウント単位のダイジェスト
   画面で横断的に見渡すこともできます。
2. **端末内での翻訳・要約。** 英文メールは Apple の Foundation Models
   framework によって端末内で日本語に翻訳・要約されます（返信も同様に
   英訳可能）。詳細は下記の[AI要約・翻訳](#ai要約翻訳)を参照してください。

## 対応アカウント

- **Gmail** — OAuth2 (Authorization Code + PKCE)
- **iCloud** — アプリ用パスワード
- **Yahoo!メール / Yahoo!メール(JAPAN)** — ホスト/ポート/セキュリティを
  事前入力した専用の追加フォーム
- **Outlook.com / Office365** — Microsoft OAuth2 (Authorization Code +
  PKCE)
- **Exchange** — 汎用 IMAP フォームへのプリセット
- **上記以外の任意の IMAP/SMTP プロバイダ**

Gmail・Outlook/Office365 は OAuth の Client ID を各自で発行する必要が
あります（未設定でもボタンが無効化されるだけで他の機能は動作します）。
手順は [docs/oauth-setup.md](docs/oauth-setup.md) を参照してください。

## 主な機能

- **統合受信トレイ**: 全アカウントのメールを日付順に混ぜて表示する
  「すべて」チップと、アカウントごとの絞り込みチップ。アカウント色の
  アクセントと、メールボックス単位/統合の未読数バッジ。「未読のみ表示」
  トグルあり。「アカウントでグループ化」ボタンからはダイジェスト画面
  （アカウントごとに1行、色罫線+表示名+未読/件数バッジ+直近プレビュー
  2〜3件、タップでそのアカウントに絞り込み、スワイプで一括処理）に
  遷移できます。各アカウントの色は自動割り当てのほか固定8色パレットから
  上書き可能で、iCloud 経由で他端末にも同期されます。
- **オフラインファースト**: メッセージ・スレッド・フラグの変更はすべて
  まずローカルの SQLite に反映されます。ネットワークが無くても使え、
  再接続時には未送信の操作（既読/未読、削除、アーカイブ、送信）を自動的
  にリプレイします。アーカイブの挙動はプロバイダごとに調整済み
  （Gmail はラベルを外すだけ、それ以外は Archive メールボックスへ移動）。
- **アバター**: 差出人ごとにアバターを表示します（端末の連絡先の写真・
  外部ソースからの画像取得・送信元ドメインのロゴ・イニシャルの優先順で
  解決、外部通信を伴うソースは設定 →「メール一覧」で個別にオフに
  できます）。
- **全文検索**: SQLite FTS5 による3文字以上のクエリ検索（短いクエリは
  `LIKE` にフォールバック）。`from:`/`to:`/`cc:`/`subject:` の検索演算子、
  アカウント絞り込みチップ、直近の検索履歴、そして**保存済み検索**
  （履歴タブ・保存済みタブを切り替えられる検索画面）に対応しています。
- **スレッド表示**: Gmail は `X-GM-THRID`、それ以外は `References`/
  `In-Reply-To` の JWZ 方式 union-find + 件名フォールバックでスレッド化。
  本文画面はアコーディオン形式（スレッド内の全メッセージを時系列に縦
  列挙し、最新のみ展開・他は折りたたみ、ヘッダタップで展開先を切替）で
  iOS・macOS 共通です。一覧側は複数メッセージのスレッドに件数バッジを
  表示します。
- **引用履歴の折りたたみ**: プレーンテキストの返信メールで、引用された
  過去のやり取りを1通ずつのカードに分解して表示します。「履歴を表示/
  非表示」で開閉可能（既定は表示、HTML メールは対象外）。
- **AI要約・翻訳**: 詳細は[後述](#ai要約翻訳)。
- **HTML メール**: サンドボックス化された `WKWebView` で描画
  （JavaScript は無効）。固定幅テーブルのマーケティング/通知メールも
  画面幅に収めて表示し、「HTML」バッジからワンタップでテキスト表示に
  切り替え可能。埋め込み画像は既定オフ、リモート画像は既定オンで、
  メールごとに「画像を表示」で一時的に上書きできます。本文内リンクは
  アプリ内ブラウザ（既定、iOS のみ）かデフォルトブラウザかを選べます。
- **ソース表示**: メッセージの生 RFC822 ソースをオンデマンドで取得
  （ローカルにキャッシュ）し、表示・共有できます。表示崩れするメールの
  調査などに使う機能です。
- **添付ファイル**: 送受信・QuickLook プレビュー・インライン `cid:`
  画像、RFC 2047/2231 のファイル名デコード（日本語ファイル名を含む）。
- **カレンダー招待メール**: `text/calendar; method=REQUEST` を検出すると
  招待カード（タイトル・日時・場所・主催者）を表示し、「承諾」「辞退」
  「未定」で標準の iTIP `METHOD:REPLY` を主催者へ返信します。詳細は
  [docs/calendar-invites.md](docs/calendar-invites.md)。
- **作成/返信/転送**: 差出人選択必須、プレーンテキスト引用、オフライン
  送信用の Outbox、下書きの保存/破棄確認と IMAP 経由の双方向同期。iOS の
  送信は Outbox への即時保存＋5秒/10秒/なしの猶予＋取り消しボタン付き。
  テンプレート（本文の定型文）と署名テンプレート（アカウントごとの
  デフォルト署名）はどちらも設定画面で管理します。
- **スワイプ操作・一括選択・ピン留め**: 左右それぞれの短い/長いスワイプ
  に既読/未読・アーカイブ・迷惑メール・ピン留め・削除を個別設定可能。
  長押しで一括選択モードと下部アクションバー、削除/アーカイブ/迷惑
  メールには Undo トースト。ピン留めは既定ローカル限定、IMAP
  `\Flagged` と連動させる設定もあります。macOS はスワイプの代わりに行の
  コンテキストメニューを使います。
- **メール本文フッターツールバー**: 返信/転送/検索/情報/その他（ミュート・
  ピン留め・アーカイブ・迷惑メール・削除・要約・翻訳・ソース表示など
  14アクション）を、設定から表示/非表示・並び替えできます。
- **表示言語**: 日本語/English をローカライズ済み（String Catalog）。
  表示言語の切替は iOS 標準の「設定 → このアプリ → 言語」に委ねています
  （アプリ内蔵の言語ピッカーは廃止済み）。詳細は
  [docs/localization.md](docs/localization.md)。
- **設定**: 「アカウントの設定」「メールビューア」「メール一覧」
  「メール作成」の4カテゴリ＋「このアプリについて」に整理されています。
  全項目は [docs/settings.md](docs/settings.md) を参照してください。
- **プッシュ通知**: 任意でセルフホストできるリレーサーバー
  (`server/otegami-relay-go`) が IMAP `INBOX` を IDLE で監視し、件名/
  本文を含まないプライバシー配慮の APNs プッシュを送信します（実際の
  内容は Notification Service Extension が自分の IMAP 接続で取得）。
  完全にオプトインで、未設定でもアプリは同様に動作します。詳細は
  [docs/relay-deployment.md](docs/relay-deployment.md)。アプリアイコン
  への未読数バッジ表示も設定でオン/オフできます。
- **iCloud によるアカウント設定の同期**: 同じ Apple ID の別デバイスで
  追加したアカウントが自動的に出現し、そのまま同期を始められます
  （メール本文自体は各デバイスが自分の IMAP 接続で同期する設計で、
  iCloud が同期するのは資格情報とアカウントのメタデータです）。詳細は
  [docs/icloud-sync.md](docs/icloud-sync.md)。設定でオプトアウト可能。
- **macOS**: 右クリックのコンテキストメニュー（メール一覧行・スレッド内
  メッセージ・下書き）、ネイティブなメニューバーコマンド（⌘N 新規、⌘R
  返信、⇧⌘R 全員に返信、⇧⌘F 転送、⌘E アーカイブ、⇧⌘U 既読/未読切替、
  ⌘⌫ 削除、⌘F 検索フォーカス、⌘]/⌘[ メールボックス切替）、ネイティブな
  Settings シーン、独立した作成ウィンドウ、そして3ペイン
  `NavigationSplitView` レイアウト。
- **パフォーマンス**: 10万通の合成メールボックスで検証済み — 詳細は
  [docs/performance.md](docs/performance.md)。

## デザイン

UI は一から見直した独自のデザインです: フラット・角丸0・2pt の罫線、
英字は Archivo・日本語はシステムフォント、薄い水色基調のライトテーマと
それに対応するダークテーマ。採用している情報設計・デザイントークンの
使い方は [`docs/design-system.md`](docs/design-system.md) を参照してく
ださい。

- **iOS (compact 幅、iPhone)**: 統合受信トレイ＋アカウント絞り込み
  チップ＋未読のみ表示トグルの常設1画面。左上のハンバーガーメニュー
  （ドロワー）がフォルダ切替と設定を、左下フローティングの検索ボタンが
  検索画面を、本文画面下部の固定フッターツールバーが返信/転送などを
  担います。下部タブバーは廃止済みです。
- **iOS (regular 幅、iPad 等)**: 左に一覧・右に本文の2ペイン
  (`MailScreenView` のサイズクラス分岐)。
- **macOS**: 従来通りの3ペイン `NavigationSplitView`。

<p align="center">
  <img src="docs/assets/screenshot-ios-search.png" width="32%" alt="アカウント横断検索・フィルタチップ・検索演算子（iOS）">
  <img src="docs/assets/screenshot-ios-thread-toolbar.png" width="32%" alt="メール本文画面のフッターツールバー: 返信・転送・検索・情報・その他（iOS）">
  <img src="docs/assets/screenshot-ios-settings.png" width="32%" alt="設定: アカウント・スワイプ操作・翻訳（iOS）">
</p>

## AI要約・翻訳

Apple の Foundation Models framework (`LanguageModelSession`) を使い、
端末内で要約・翻訳を行います（iOS/macOS 26+、Apple Intelligence 有効な
端末が必要。非対応環境では該当 UI が自動的に折りたたまれます）。

- **AI要約**: メッセージごとにワンタップで生成する
  ■要約/■伝えたいこと/■アクションの3パート構造の要約。返信メールでは
  引用された過去のやり取りを要約対象から除外し、新しい本文だけを要約
  します。「詳しく要約」で、より詳細なバージョンに再生成できます。
- **翻訳**: 英文メールの翻訳ボタン（本文読み込み後は常に押せます）。
  自動翻訳は既定オフで、オンにしても確信度の高い英文メールにのみ発火
  します。訳文表示中はワンタップで原文に戻せます。プレーンテキストは
  段落単位で原文を確認でき、HTML メールは表・画像・レイアウトを保った
  まま本文だけ翻訳されます。段落単位のキャッシュがあるため再翻訳は
  走りません。

エンジンの設計、対応言語、既知の制限（iOS Simulator の `.app`
プロセスから呼ぶと `FoundationModels.LanguageModelError -1` で失敗する
一方、同一マシン上の `swift test` プロセスからは成功するという
Simulator/toolchain 固有の制限）は
[`docs/translation.md`](docs/translation.md) にまとめています。

## 使い方

アカウントの追加からビューアの操作、検索、設定まで、機能ごとの使い方は
[docs/usage.md](docs/usage.md) にまとめています。

## ステータス

自動テスト/検証スイート (`make test`、`scripts/verify-*.sh` の各チェック
ポイント) が green な状態を保ちながら継続的に機能追加をしている、個人の
AI 支援サイドプロジェクトです。App Store への公開や、誰かの日常のメイン
クライアントとして長期間使われたことはまだありません。一部の機能（実
アカウントでのサインイン、実機2台間での iCloud アカウント同期の往復など）
は、シミュレータ上の自動テストでは確認しきれず、実アカウント/実機での
確認が必要です — 各機能の既知の制限は該当する `docs/*.md` に記載して
います。今後の計画は [docs/roadmap.md](docs/roadmap.md) を参照して
ください。

## 開発を始める

```sh
brew install xcodegen   # Xcode プロジェクト生成に必要
make mac                 # macOS アプリ (debug ビルド)
make ios                 # iOS Simulator ビルド
make test                # OtegamiKit の単体テスト
```

Xcode（iOS 26 / macOS 26 SDK、Xcode 26 以降）が必要です。実機ビルドや
Gmail/Outlook OAuth を試す場合の `Local.xcconfig` 設定、開発用メール
スタック (Dovecot + Mailpit) の起動、`scripts/verify-screen.sh` を使った
実機シミュレータでの画面確認まで含めた詳しい手順は
[docs/development-setup.md](docs/development-setup.md) を参照してください。

## テスト/動作検証

```sh
make test               # OtegamiKit の単体テスト (速い、simulator 不要)
scripts/verify-screen.sh <scenario> [output.png]  # tap-free スクリーンショット
scripts/verify-relay.sh                            # otegami-relay の E2E 検証
```

各チェックポイントの内容とシミュレータの既知不調は
[docs/verify.md](docs/verify.md)、自動検証の方針は
`.claude/skills/verify/SKILL.md` を参照してください。

## アーキテクチャ

- `apps/Otegami/` — SwiftUI アプリ本体 (iOS + macOS)、XcodeGen
  `project.yml`。
- `packages/OtegamiKit/` — プラットフォーム非依存のコア: `OtegamiCore`
  (モデル・スレッド化)、`MailTransport`/`MailTransportMailCore`
  (IMAP/SMTP、MailCore2 アダプタ)、`OtegamiStore` (GRDB スキーマ/
  クエリ/FTS)、`SyncEngine` (同期・オフライン操作キュー)、
  `GoogleOAuth`/`MicrosoftOAuth`、`PushRelayClient`、`OtegamiRelayAPI`
  (サーバーと共有する DTO)、`OtegamiTranslation`/
  `OtegamiTranslationFoundationModels`/`TranslationEngine` (端末内翻訳・
  要約のスタック)。
- `server/otegami-relay-go/` — プッシュリレー (Go)。
- `dev/mailstack/` — Dovecot + Mailpit の開発用スタック。

モジュール間の依存方向・同期エンジンの設計・既知の落とし穴は
[docs/architecture.md](docs/architecture.md)、MailCore2 依存の同梱方法は
[docs/build-mailcore2.md](docs/build-mailcore2.md)、性能検証は
[docs/performance.md](docs/performance.md) を参照してください。

## ドキュメント一覧

**使い方・機能**
- [docs/usage.md](docs/usage.md) — 機能ごとの使い方ガイド
- [docs/architecture.md](docs/architecture.md) — モノレポ構成・同期エンジンの設計・既知の落とし穴
- [docs/design-system.md](docs/design-system.md) — UI デザインシステム
- [docs/settings.md](docs/settings.md) — 設定項目の全一覧
- [docs/translation.md](docs/translation.md) — オンデバイス翻訳・要約エンジンの設計
- [docs/calendar-invites.md](docs/calendar-invites.md) — カレンダー招待メール対応
- [docs/icloud-sync.md](docs/icloud-sync.md) — iCloud によるアカウント設定同期
- [docs/default-mail-app.md](docs/default-mail-app.md) — デフォルトのメールアプリ対応
- [docs/roadmap.md](docs/roadmap.md) — 今後の計画

**開発**
- [docs/development-setup.md](docs/development-setup.md) — 開発環境のセットアップ
- [docs/dev-mailstack.md](docs/dev-mailstack.md) — 開発用メールスタック (Dovecot + Mailpit)
- [docs/build-mailcore2.md](docs/build-mailcore2.md) — MailCore2 依存の調達方法
- [docs/localization.md](docs/localization.md) — アプリ UI のローカライズ
- [docs/performance.md](docs/performance.md) — 性能検証
- [docs/verify.md](docs/verify.md) — 動作検証の手順とシミュレータの既知不調
- [docs/ci.md](docs/ci.md) — CI (GitHub Actions) の設定と既知の落とし穴

**認証・配布**
- [docs/oauth-setup.md](docs/oauth-setup.md) — Gmail/Microsoft OAuth の設定
- [docs/relay-deployment.md](docs/relay-deployment.md) — プッシュ通知リレーのデプロイ
- [docs/release.md](docs/release.md) — git tag push によるリリース (TestFlight/GitHub Release)
- [docs/xcode-cloud.md](docs/xcode-cloud.md) — Xcode Cloud / TestFlight 配布
- [docs/ota-deploy.md](docs/ota-deploy.md) — OTA (Ad Hoc) 配布

## 貢献

Issue・Pull Request を歓迎します — バグ報告・質問・小さな修正は特に
歓迎です。開発環境のセットアップ・テストの実行方法・コミット/PR の規約
は [CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。セキュリティ
上の脆弱性は公開の Issue ではなく [SECURITY.md](SECURITY.md) の手順で
報告してください。

## ライセンス

MIT — [LICENSE](LICENSE) を参照。

### サードパーティライセンス

Otegami は Swift Package Manager 経由のサードパーティ製パッケージ
(GRDB.swift、MailCore2 のフォークとその C 依存関係)、プッシュリレーの
Go module に依存しており、Archivo フォント (SIL Open Font License) も
同梱しています。ライセンス・著作権表示は [NOTICE](NOTICE)、リレーの
module 一覧とバージョンは
[`server/otegami-relay-go/go.mod`](server/otegami-relay-go/go.mod) を参照してください。
