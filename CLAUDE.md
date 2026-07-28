# CLAUDE.md

このリポジトリ (otegami) で作業する Claude Code 向けの指針。開発一般の
手順は [CONTRIBUTING.md](CONTRIBUTING.md) を参照 (このファイルはそれと
重複させず、UI 設計とこのファイル特有の注意点だけを扱う)。

## UI デザイン方針

iOS UI の構造・情報設計は [`design_handoff_ios_mail/README.md`](design_handoff_ios_mail/README.md)
(Claude Design 作成のハンドオフ) を参照すること。**採用済みの選択**:

- **情報設計: 1a** (統合受信トレイ＋アカウント絞り込みチップ)。iOS の
  compact 幅向け。**iOS の regular 幅 (iPad 等) は 2 ペイン
  (左一覧・右本文、`MailScreenView` のサイズクラス分岐)**、
  **macOS は現状の `NavigationSplitView` 3ペインを維持する**。
  **下部タブバー3つ (メール/検索/設定) は新画面構成で廃止済み** — 左上の
  ハンバーガーメニュー (`OtegamiRootView`/`MailScreenView`/
  `HamburgerMenuContainer`) がフォルダ切替＋設定を、ヘッダの検索ボタン
  (`SearchScreenView`) が検索を担う。詳細・経緯は `docs/design-system.md`
  の「新画面構成」節参照。
- **一覧レイアウト: 1d** (標準3行＋アカウント色の左罫線3px)
- **操作モデル: 1g + 1h + 1i** (スワイプ割り当て／長押し一括選択／詳細
  画面の翻訳インタラクション)
- **翻訳機能: 実装する** (Apple Foundation Models によるオンデバイス翻訳。
  別フェーズで実装)

ワイヤーフレームは **lofi** (灰色バー＝テキスト、水色＝強調のプレース
ホルダ)。実装時に参照してよいのはレイアウトと動線のみで、**スタイル
(色・タイポ・余白・罫線) は `apps/Otegami/Sources/DesignSystem/` の
トークンを使うこと。新しい色をその場で追加しない** — 必要な色が無い
場合は先に `docs/design-system.md` を見て、無ければトークンを追加する
議論をしてから使う。詳細は `docs/design-system.md` を参照。

`design_handoff_ios_mail/` には元ハンドオフの `wireframes-standalone.html`
(2.9MB) を意図的に含めていない — 理由は `design_handoff_ios_mail/NOTE.md`
参照。

## ビルド・テスト

[CONTRIBUTING.md](CONTRIBUTING.md)/[README.md](README.md#building) が
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
詳細と教訓は [`docs/ci.md`](docs/ci.md#既知の落とし穴-swiftui-ビューの型チェックタイムアウト-2026-07-25)
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

- ユーザー本人にしかできない作業は `HUMAN_TASKS.md` に追記する
  (完了したらチェック)。技術的な未検証事項は `PENDING.md`。
  開発はそれらで止めない。
- 実機での動作確認はユーザーの分業 — エージェントは確認ポイントを
  具体的に渡す。

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

- `docs/design-system.md` — UI の決定事項・各改修 (Task #NN) の経緯
- `docs/verify.md` — 検証手順とシミュレータ既知不調
- `docs/qa-findings.md` — 同期まわりのバグ調査記録 (expunge 検出等)
- `docs/translation.md` — 翻訳・要約 (ガードレール寛容化、引用分離)
- `docs/icloud-sync.md` — アカウント iCloud 同期と実機汚染事故の教訓
- `docs/oauth-setup.md` — Google OAuth (スコープ、再認証、診断画面)
- `docs/xcode-cloud.md` — TestFlight 配布 (tag トリガー運用)
- `docs/ota-deploy.md` — OTA 配信の仕組み
- `docs/default-mail-app.md` — mailto / mail-client entitlement
- `docs/calendar-invites.md` — カレンダー招待 (ICS/iTIP)
