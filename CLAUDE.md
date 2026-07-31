# CLAUDE.md

このリポジトリ (otegami) で作業する Claude Code 向けの指針。開発一般の
手順は [CONTRIBUTING.md](CONTRIBUTING.md) を参照 (このファイルはそれと
重複させず、UI 設計とこのファイル特有の注意点だけを扱う)。

## UI デザイン方針

iOS UI の構造・情報設計は [`docs/design-system.md`](docs/design-system.md)
を参照すること (採用済みの情報設計・デザイントークンの使い方をまとめた
現状のリファレンス)。**採用済みの選択**:

- **情報設計: 1a** (統合受信トレイ＋アカウント絞り込みチップ)。iOS の
  compact 幅向け。**iOS の regular 幅 (iPad 等) は 2 ペイン
  (左一覧・右本文、`MailScreenView` のサイズクラス分岐)**、
  **macOS は現状の `NavigationSplitView` 3ペインを維持する**。
  **下部タブバー3つ (メール/検索/設定) は新画面構成で廃止済み** — 左上の
  ハンバーガーメニュー (`OtegamiRootView`/`MailScreenView`/
  `HamburgerMenuContainer`) がフォルダ切替＋設定を、ヘッダの検索ボタン
  (`SearchScreenView`) が検索を担う。詳細は `docs/design-system.md` 参照。
- **一覧レイアウト: 1d** (標準3行＋アカウント色の左罫線3px)
- **操作モデル: 1g + 1h + 1i** (スワイプ割り当て／長押し一括選択／詳細
  画面の翻訳インタラクション)
- **翻訳機能: 実装済み** (Apple Foundation Models によるオンデバイス翻訳。
  詳細は `docs/translation.md`)

実装時に UI コードで参照してよいのはレイアウトと動線であり、**スタイル
(色・タイポ・余白・罫線) は `apps/Otegami/Sources/DesignSystem/` の
トークンを使うこと。新しい色をその場で追加しない** — 必要な色が無い
場合は先に `docs/design-system.md` を見て、無ければトークンを追加する
議論をしてから使う。

## ビルド・テスト

[CONTRIBUTING.md](CONTRIBUTING.md)/[README_ja.md](README_ja.md#開発を始める) が
正。要点だけ:

```sh
make test    # OtegamiKit unit tests (速い、シミュレータ不要)
make mac     # macOS ビルド
make ios     # iOS Simulator ビルド
```

アプリの実挙動確認 (画面遷移・同期など) は `scripts/verify-*.sh` /
`.claude/skills/verify/SKILL.md` の手順で実機シミュレータを動かして行う。
「見た目を確認した」と報告する前に、実際にレンダリングされた画面を
自分の目で見ること (プレビュー/スクリーンショット/シミュレータのいずれ
か) — 見ずに完了と報告しない。

### SwiftUI ビューは小さく保つこと (CI 型チェックタイムアウト)

`ci-app` は過去に「compiler is unable to type-check this expression in
reasonable time」で落ちた前例がある。ローカルの Xcode より CI ランナー
の方が型チェックが遅く／挙動が異なることがあり、**ローカルで
`-warn-long-expression-type-checking` の警告がゼロでも CI で落ちうる**。
詳細と教訓は [`docs/ci.md`](docs/ci.md#既知の落とし穴-swiftui-ビューの型チェックタイムアウト)
と [CONTRIBUTING.md](CONTRIBUTING.md#a-note-on-swiftui-views-and-ci) 参照。

実践的なルール:
- 1つの `View` の `body` を長く書かない。`ForEach`/`Button`/条件分岐/
  モディファイアチェーンが1つの式に折り畳まれるのが典型的な引き金。
- 行を描画する `ForEach`/`List` の中身は独立した `View` 型に切り出し、
  その `View` を呼ぶだけの単純な呼び出しにする。
- タップハンドラはインラインクロージャでなく名前付きメソッド参照にする。

## コミット規約

[Conventional Commits](https://www.conventionalcommits.org/)
(`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`, ...)。
意味のある単位で細かくコミットする。`git log` に実例多数。

## 開発体制 (マルチエージェント運用)

- 実装は Sonnet のサブエージェントに委譲し、メインセッションは
  オーケストレーション・レビュー・切り分け判断を担う。
- **並行エージェントは最大 2 本** (過去に 5 本並行でディスク枯渇事故)。
  作業前・長いビルド前に `df -h /` を確認し、空き 5GB 未満なら中断。
- 全エージェントが**同一の作業ツリーを共有**する。過去に「ファイル全体
  `git add` で他人の未完成コードを巻き込み main が壊れる」「stash/reset
  で他人の作業を消しかける」事故が複数回起きた。厳守:
  - 他人の modified ファイルに触らない・コミットしない。
  - 共有ファイルは `git add -p` (または個別パス指定) で自分のハンクのみ。
  - `git stash` / `git reset --hard` は使わない (配信用 worktree の定例
    reset は例外)。
  - push は plain push。拒否されたら fetch して自分のコミットを載せ替え。
- `run_in_background` 付きの Bash は `.claude/settings.json` の hook で
  全面ブロックされる — すべてフォアグラウンドで実行し、完了を待つ。

### ステージ領域は共有されている — 自分専用のインデックスを使うこと

`git add <ファイル>` で自分のファイルだけを指定しても、**`git commit` は
インデックス全体をコミットする**。他のエージェントが `git add` 済みで
まだコミットしていないファイルがあれば、それも一緒に入る。ステージ領域は
作業ツリーに 1 つしか無く、全員で共有しているため。

2026-07-31 のセッションでこの事故が 4 回起きた (うち 1 回は他タスクの
未コミットのマイグレーションを巻き込んで main が一時的にビルド不能に
なった)。「ファイル単位で `git add` すれば安全」は**誤り**。

**対策: 自分専用のインデックスファイルを使う。**

**重要 — `export` は効かない。** エージェントのシェル呼び出しは 1 回ごとに
新しいシェルなので、前の呼び出しで `export` した環境変数は次の呼び出しに
引き継がれない。**固定パスを決めて、git コマンドを打つたびに毎回前置き
する**こと。

```sh
# 1. 最初に一度だけ (自分専用インデックスを HEAD で初期化)
GIT_INDEX_FILE=/tmp/otegami-index-<自分の識別子> git read-tree HEAD

# 2. 以降、git を打つたびに毎回前置きする
GIT_INDEX_FILE=/tmp/otegami-index-<自分の識別子> git add -p path/to/file.swift
GIT_INDEX_FILE=/tmp/otegami-index-<自分の識別子> git diff --cached
GIT_INDEX_FILE=/tmp/otegami-index-<自分の識別子> git commit -m "..."
```

同じ呼び出しの中で複数の git コマンドを打つなら、その中で
`export GIT_INDEX_FILE=...` してからまとめて実行してもよい。**前置きを
忘れた 1 回が共有インデックスを触ってしまう**ので、`git add` と
`git commit` は同じ呼び出しにまとめるのが安全。

これで他人のステージ内容が視界に入らなくなり、事故が構造的に起きなく
なる。`git add -p` によるハンク単位の選択もそのまま使える。

インデックスを分けていない場合の次善策は、コミット時にもパスを指定する
こと:

```sh
git commit --only -- path/to/file.swift
```

ただし `--only` は指定パスについて**作業ツリーの内容**を使うため、
`git add -p` で選んだハンクの取捨は無視され全部入る。部分ステージを
使うなら上の専用インデックス方式にすること。

**どちらの方式でも、コミット直前に `git diff --cached` を読んで自分の
変更だけが入っていることを目で確認する。**

## 検証の実際 (シミュレータの既知不調)

`docs/verify.md` と `.claude/skills/verify/SKILL.md` が正。要点:

- シミュレータには既知の環境不調が 4 種ある (IMAP 接続不能 / XCUITest の
  タップ不達 / 連絡先権限ダイアログ / Foundation Models error -1)。
- 画面確認は **tap-free 経路** (`scripts/verify-screen.sh`) を標準に:
  DB 直接注入フラグ + 直接遷移フラグ + `simctl launch` + スクリーン
  ショット。XCUITest・実接続・タップに依存しない。
- IMAP 接続系の検証は素プロセスの実 Dovecot 統合テスト
  (`OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter ...`) で行う。
- **シミュレータでエラーが出たら粘らない** (ユーザー明示指示)。リトライは
  1-2 回まで。以降は `make test`/ビルド緑で出荷し「未検証」と明記、
  実機での確認ポイントをユーザー向けに箇条書きで渡す。

## 配信・リリース

- **機能・修正の完了ごとに OTA 配信する** (小出しリリース)。手順:
  scratchpad の配信用 worktree で `git fetch && git reset --hard
  origin/main && git clean -fd` → `Local.xcconfig` をメイン作業ツリー
  からコピー → `./scripts/deploy-ota.sh` → 配信された manifest の
  `bundle-version` が push 済み SHA と一致することを確認。
  (`git clean` は Local.xcconfig を消すのでコピーを忘れない。)
- deploy-ota.sh は Distribution 署名が使えない環境では development 署名
  へ自動フォールバックする (配布先実機は開発デバイス登録済み)。
- **TestFlight リリースは git tag → Xcode Cloud** (`docs/xcode-cloud.md`)。
  tag の作成・push はリリース行為なので**ユーザーの明示指示がある時のみ**。
  Xcode Cloud はイベント処理が 10-20 分遅延する癖がある。
- 配信のたびに「何が入ったか + 実機で見るポイント」をユーザーに報告する。

## ユーザー確認・保留事項の運用

- `PENDING.md`/`HUMAN_TASKS.md` のような独立した「未確認事項」台帳は
  運用しない — 放置すると数百〜千行超の完了済み経緯ログに肥大化しやすく、
  実際そうなったため廃止した。本当に残すべき既知の制限・未検証事項は、
  該当する `docs/*.md` に「既知の制限」として直接書く (履歴・調査経緯は
  git log で追える)。
- 実機での動作確認はユーザーの分業 — エージェントは確認ポイントを
  該当ドキュメントまたはコミットメッセージ/PR で具体的に渡す。

## このリポジトリでの注意

- Swift 6 strict concurrency。iOS 26 / macOS 26 が最低対応バージョン。
- Markdown ドキュメントは日本語で書く。
- public リポジトリなので、公開前提の品質でコード・コメント・コミット
  メッセージを書くこと (秘密情報や個人的な内部事情を書き込まない)。
  **実名・実メールアドレス・Team ID・プライベートホスト名は、コード・
  フィクスチャ・テスト・ドキュメント・コミットメッセージのどこにも
  書かない** — 過去に 2 回混入し、履歴書き換え (force push) までして
  除去した。フィクスチャの人名・アドレスは架空名 / example.com /
  otegami.test を使う。
- 動的な文字列 (アカウント表示名・検索クエリ等) を `Text`/`Label` に
  渡すときは `Text(verbatim:)` — `LocalizedStringKey` 経由だと Markdown
  解釈でメールアドレスが `mailto:` リンク化する実バグ前例あり
  (`AccountFilterChip.swift` の教訓コメント参照)。

## 主要ドキュメントの地図

- `docs/architecture.md` — モノレポ構成・同期エンジンの設計・既知の落とし穴
- `docs/design-system.md` — UI の情報設計・デザイントークンの使い方
- `docs/verify.md` — 検証手順とシミュレータ既知不調
- `docs/translation.md` — 翻訳・要約エンジンの設計 (ガードレール寛容化、引用分離)
- `docs/icloud-sync.md` — アカウント iCloud 同期と実機汚染事故の教訓
- `docs/oauth-setup.md` — Google/Microsoft OAuth (スコープ、再認証、診断画面)
- `docs/relay-deployment.md` — プッシュ通知リレーのデプロイと設定値
- `docs/xcode-cloud.md` — TestFlight 配布 (tag トリガー運用)
- `docs/ota-deploy.md` — OTA 配信の仕組み
- `docs/default-mail-app.md` — mailto / mail-client entitlement
- `docs/calendar-invites.md` — カレンダー招待 (ICS/iTIP)
