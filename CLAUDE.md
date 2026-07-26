# CLAUDE.md

このリポジトリ (otegami) で作業する Claude Code 向けの指針。開発一般の
手順は [CONTRIBUTING.md](CONTRIBUTING.md) を参照 (このファイルはそれと
重複させず、UI 設計とこのファイル特有の注意点だけを扱う)。

## UI デザイン方針

iOS UI の構造・情報設計は [`design_handoff_ios_mail/README.md`](design_handoff_ios_mail/README.md)
(Claude Design 作成のハンドオフ) を参照すること。**採用済みの選択**:

- **情報設計: 1a** (統合受信トレイ＋アカウント絞り込みチップ)。iOS のみ。
  **macOS は現状の `NavigationSplitView` 3ペインを維持する** — 1a は
  コンパクト幅向けの設計であり、Mac の広い画面には適用しない。
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

## このリポジトリでの注意

- Swift 6 strict concurrency。iOS 26 / macOS 26 が最低対応バージョン。
- Markdown ドキュメントは日本語で書く。
- public リポジトリなので、公開前提の品質でコード・コメント・コミット
  メッセージを書くこと (秘密情報や個人的な内部事情を書き込まない)。
