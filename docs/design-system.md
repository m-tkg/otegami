# デザインシステム (`DesignSystem`)

iOS/macOS 共通の UI トークン・基本コンポーネント集。実体は
`apps/Otegami/Sources/DesignSystem/` (アプリ本体のターゲットに直接コンパ
イルされる、通常の Swift ファイル群)。

**新しい色を足したくなったら、まずこのファイルと `OtegamiColor.swift` を
見ること。** UI コード側で生の `Color(hex:)`/`Color(red:green:blue:)` を
書かない・新しい色をその場で追加しない — 必要な用途がまだ無ければ、
このドキュメントの「トークン一覧」に追記する形で `OtegamiColor` にトー
クンを足してから使う。

## 由来

UI の構造 (情報設計・一覧レイアウト・操作モデル) は
[`design_handoff_ios_mail/README.md`](../design_handoff_ios_mail/README.md)
のワイヤーフレーム議論から確定した (採用: 1a / 1d / 1g+1h+1i — 詳細は
リポジトリ直下の `CLAUDE.md` 参照)。このデザインシステムはその**スタイ
リング**を担当する部分で、ワイヤーフレームのプレースホルダ値 (ハンドオ
フの「Design Tokens」表) を元に、ライト/ダーク両対応でトークン化した
もの。ハンドオフはダークモードを「未設計。トークン化して両対応にする
こと」と明記しており、ダーク側の値はこの実装で新たに設計した (元ハンド
オフには存在しない)。

## トークン一覧

### カラー — `OtegamiColor.swift`

用途ベースの命名。生の色名 (`ec3013` など) を UI コードに露出させない
ためのレイヤー。

| トークン | 用途 | Light | Dark |
| --- | --- | --- | --- |
| `background` | 画面の基底背景 | `#EEF3F6` | `#10191E` |
| `surface` | カード・行・シートなど背景の上に乗る面 | `#FFFFFF` | `#1F2E36` |
| `ink` | 主要テキスト・アイコン | `#1A1A1A` | `#F2F6F8` |
| `inkSecondary` | 補助テキスト (プレビュー・送信者・日時) | `#666666` | `#AAB6BB` |
| `inkTertiary` | 薄いテキスト (無効/キャプション寄り) | `#999999` | `#7C8A8F` |
| `paleBase` | 最も弱い強調地 | `#F4F9FC` | `#18262D` |
| `paleBaseStrong` | 中程度の強調地 (選択行、チップの選択状態) | `#CFE4EE` | `#25404B` |
| `paleBaseStrongest` | 最も強い強調地 | `#9FC9DD` | `#2E5A6B` |
| `accent` | アイコン/未読ドットなどの水色アクセント | `#3D7F9E` | `#7FC7E3` |
| `accentText` | リンク等、文字用の水色アクセント (本文サイズでは濃い/明るいステップを使う) | `#2A6B88` | `#9AD6EC` |
| `destructive` | 削除など破壊的操作 (Modernist accent 由来、ダークでは可読性のため明るく調整) | `#EC3013` | `#FF6A46` |
| `divider` | 主要区切り線 (2pt solid とセットで使う) | `#1A1A1A` | `#3C4A52` |
| `dividerSubtle` | 行間の区切り線 (1pt dashed とセットで使う) | `#CCCCCC` | `#2A363C` |

`Color(light:dark:)` (`DynamicColor.swift`) がこのファイル全体の基礎。
`UIColor`/`NSColor` の dynamic provider で作っているため、実機・
Simulator・Preview・`ImageRenderer` によるオフスクリーン描画のいずれで
も、描画時の `colorScheme`/appearance に応じて正しく解決される (カタロ
グのスクリーンショット取得で実際に確認済み — 下記「見た目を確認する」
参照)。

### タイポグラフィ — `OtegamiFont.swift`

英字は Archivo (SIL Open Font License、`Resources/Fonts/Archivo/` に同
梱)、日本語はシステムフォント。**別々に切り替える実装はしていない** —
Archivo が対応していないグリフ (日本語など) は CoreText のフォント
カスケードにより自動的にシステムフォントへフォールバックするので、
`OtegamiFont.body()` のような1つの `Font` を混在文字列にそのまま使えば
両方が意図通りに描き分かれる。

全スタイルが `Font.custom(_:size:relativeTo:)` 経由で Dynamic Type に
対応する (固定 pt 指定はしない)。

| スタイル | 用途 | サイズ / 相対 TextStyle |
| --- | --- | --- |
| `largeTitle()` | 画面タイトル | 28pt / `.largeTitle` |
| `title()` | セクション・シートタイトル | 22pt / `.title` |
| `headline()` | 行の見出し (送信者名・件名) | 17pt / `.headline` |
| `body()` | 本文 | 16pt / `.body` |
| `subheadline()` | 行の補助テキスト | 14pt / `.subheadline` |
| `caption()` | チップ・セクション見出しなどの小テキスト | 12pt / `.caption` |
| `badge()` | 最小テキスト (`ENBadge` など) | 11pt / `.caption2` |

ウェイトは Archivo 可変フォントの named instance
(`ArchivoRoman-Regular`/`-Medium`/`-SemiBold`/`-Bold`) を直接指定する。

#### フォント登録について (次フェーズで要対応)

`OtegamiFont.registerCustomFontsIfNeeded()` は CoreText にフォントを登録
する関数だが、**まだどこからも呼ばれていない**。今回のタスクは「新規
ファイルの追加のみ」に限定されていたため、アプリ起動時にこれを呼ぶ配線
(`OtegamiApp.swift`/`AppEnvironment` 側の変更) は次フェーズに持ち越し。
呼ばれるまでは `Font.custom` が解決できず、SwiftUI の標準動作としてシス
テムフォントに黙ってフォールバックする (クラッシュはしない) ので、この
状態のままでも安全にビルド・実行できる。

### スペーシング — `OtegamiSpacing.swift`

12pt を基本単位とするスケール: `xs=4 / sm=8 / md=12 / lg=16 / xl=24 /
xxl=32`。

### 罫線・角丸 — `OtegamiBorder.swift`

- `OtegamiStroke.primary` = 2pt (主要区切り、`divider` とセット)
- `OtegamiStroke.secondary` = 1pt (行間の区切り、`dividerSubtle` と
  ダッシュスタイルでセット — `SectionDivider.swift` の
  `.otegamiRowDivider()` 参照)
- `OtegamiRadius.none` = 0pt — カード以外 (ボタン・チップ・バッジ等) は
  引き続き角丸なし
- `OtegamiRadius.card` = 8pt — **実機フィードバック第2弾 (C) でカードのみ
  角丸を解禁** (以前の「角丸0」方針からの転換、詳細は本ファイル末尾の
  「実機フィードバック第2弾: C」節参照)

## 基本コンポーネント — `Components/`

| コンポーネント | 説明 |
| --- | --- |
| `AccountFilterChip` | 1a のアカウント絞り込みチップ。選択状態は塗り+枠線の両方で表現 (色だけに依存しない) |
| `UnreadDot` | 1d の未読ドット。未読でなければ透明円としてレイアウト分だけ確保する (行の高さが揺れない) |
| `AccountColorRail` | 1d のアカウント色左罫線 (3pt)。色は `OtegamiAccountColor` から決定 |
| `SectionDivider` / `.otegamiRowDivider()` | セクション区切り (2pt solid) と行区切り (1pt dashed) |
| `ENBadge` | 英語メールを示す "EN" バッジ (1e/1j) |
| `.otegamiMinimumTappable()` | どんな見た目のビューにも 44×44pt 以上のタップ領域を保証する `ViewModifier` |

## アカウント色の割り当て — `OtegamiAccountColor.swift`

アカウント ID (`String`) から FNV-1a ハッシュで固定パレット (8色、パレ
ブルーのトーンに調和する彩度を抑えた色相) のインデックスを決め、常に同
じ ID には同じ色を返す。`String.hashValue` はプロセスごとにソルトされ
実行のたびに変わる (Swift の意図的な仕様) ため使っていない — この色は
デバイス間・再起動間で同じでなければならない (iCloud 経由でアカウント
情報が同期される、`docs/icloud-sync.md`)。

## カタログで見た目を確認する

`Catalog/DesignSystemCatalogContent.swift`
(`DesignSystemCatalogView.swift` 内) — 全トークン・全コンポーネントを
1画面に並べた `#if DEBUG` 専用ビュー。確認方法は2つ:

1. **`apps/Otegami/DesignSystemCatalog/`** — 独立した SwiftPM 実行タ
   ーゲット。`Sources/DesignSystem` はシンボリックリンクで
   `apps/Otegami/Sources/DesignSystem` を直接指しているので、アプリ本体
   と**全く同じソース**をビルドする (コピーではないのでドリフトしない)。

   ```sh
   cd apps/Otegami/DesignSystemCatalog
   swift run DesignSystemCatalogRenderer [出力先ディレクトリ]
   # デフォルト出力先: /tmp/otegami-verify/design-light.png, design-dark.png
   ```

   `ImageRenderer` でオフスクリーン描画するため、Xcode/シミュレータ不要
   で見た目を確認できる。`ScrollView` はオフスクリーン描画で正しく描画
   されない (実ウィンドウのクリップ機構に依存するため) ことが分かったの
   で、`DesignSystemCatalogContent` (スクロールなしの素の内容) を直接描
   画している — `DesignSystemCatalogView` (スクロール付き) は実機/
   Simulator/Preview 用。
2. **Xcode Preview** — `DesignSystemCatalogView.swift` 末尾の
   `#Preview("Light")`/`#Preview("Dark")`。

このタスクの時点ではアプリの起動フローにカタログへの導線は無い (「新規
ファイルのみ」の制約のため) — 上記2通りのいずれかで確認する。

## Archivo フォントのライセンス

`apps/Otegami/Resources/Fonts/Archivo/`:

- `Archivo-Variable.ttf` — Google Fonts 配布の可変フォント
  (`wght`/`wdth` 軸、`google/fonts` リポジトリの `ofl/archivo/` から
  取得。Copyright 2020 The Archivo Project Authors)
- `OFL.txt` — SIL Open Font License 1.1 の全文

OFL は再配布・改変・同梱を無償で許可するライセンスで、単体販売しない
限り問題ない。**`NOTICE` (リポジトリ直下) はこのフォント追加を未反映**
— `NOTICE` は既存ファイルで、今回のタスクは新規ファイル追加のみに限定
されていたため、実際の追記は次フェーズで行う。追記すべき内容: Archivo
の著作権表示・OFL 参照・同梱先パス (`NOTICE` の他セクションと同じ体裁
で、"Bundled assets" のような区分を新設するのが自然)。

## design-phase-2: 実際の画面への適用 (2026-07-26)

上記のトークン・コンポーネントを実際の画面に適用し、1a/1d/1g/1h の構造
を実装したフェーズの記録。`OtegamiFont.registerCustomFontsIfNeeded()` の
起動時呼び出し (`AppEnvironment.init()`) と `NOTICE` への Archivo 帰属表
示も、このフェーズで完了した (前フェーズの申し送り事項)。

### 実装した構造

- **1a (iOS のみ)**: `OtegamiTabRootView` (下部タブ: メール/検索/設定)。
  `MailTabView` がタップ可能なフォルダタイトル (`FolderListSheet` を開
  く) + `AccountFilterChipRow` (「全部」/各アカウント/「＋」) +
  `MessageListView` を束ねる。`FolderListSheet` は旧サイドバー相当の内
  容 (アカウント別メールボックスツリー、下書き・送信待ち・同期エラーの
  バナー) を集約する。macOS は `NavigationSplitView` 3ペイン (`SidebarView`)
  のまま変更していない。
- **1d**: `ThreadRowView` (`AccountColorRail` + `UnreadDot` + 3行 + 右端
  アカウント名ラベル)。統合受信トレイをアカウントフィルタなしで見てい
  るときだけ罫線/ラベルを出す (`showsAccountAccent`) — 単一メールボック
  ス表示や1アカウントに絞ったときは冗長なので出さない、ハンドオフより
  踏み込んだ調整。
- **1g**: 左スワイプ (リーディングエッジ) = 既読/未読 (フルスワイプ可) +
  アーカイブ、右スワイプ (トレイリングエッジ) = 削除のみ。
- **1h**: 長押しで一括選択モード (チェックボックス行、キャンセル/N件選
  択中/全選択ナビ、既読に・移動・削除の下部バー)。macOS は長押しジェス
  チャーを追加せず、既存の右クリックコンテキストメニューのまま (アーカ
  イブ項目のみ追加)。

### ハンドオフからの意図的な逸脱 (理由付き)

- **翻訳/後で (1g)**: 翻訳機能は別フェーズで実装するため、スワイプ行の
  該当スロットは非表示のまま (フェイクの非機能ボタンを見せない) —
  `MessageListRow.trailingSwipeActions` のコメントに挿入位置を記録。
  「後で」(スヌーズ) も同様の理由 (専用の永続化層がなく、この UI 改修
  タスクの範囲外) でプレースホルダに留めた。
- **削除の「ハードスワイプ必須」→「常にタップ必須」**: SwiftUI の
  `.swipeActions` はグループ内の *どれか1つ* だけをフルスワイプで自動発
  火できる仕組みで、「距離に応じて別々のアクションが発火する」ことはで
  きない。削除をフルスワイプ対象にする代わりに `allowsFullSwipe: false`
  にして、削除はスワイプ距離だけでは絶対に発火しない (必ず明示タップが
  要る) 形にした — ハンドオフの意図 (誤爆防止) をより強く満たす代替案。
- **一括操作の「移動」→ アーカイブのみ**: 汎用フォルダピッカーはこのタ
  スクの範囲外と判断し、1g のアーカイブと同じ宛先 (各スレッドの所属ア
  カウントの Archive メールボックス) に固定した。
- **警告色トークンが未定義**: `.orange` の同期エラーバナーは既存のシス
  テムセマンティックカラーのまま残した (新規のブランド色ではないので
  「その場で新しい色を足す」規約には抵触しないと判断)。`OtegamiColor` に
  `warning` 系トークンを正式に追加するかどうかは未検討 — 次フェーズの
  課題。

### 開発中に見つかった実装上の落とし穴

- **`.onLongPressGesture` と `.swipeActions` の競合**: 1h の長押しジェス
  チャーに `.onLongPressGesture`/`.gesture` を使うと、同じタッチダウン
  イベントを取り合って `List` 標準のリーディングエッジ swipeActions が
  一切反応しなくなる実機バグを確認 (`OtegamiM3SwipeActionsUITests
  .testSwipeMarksMessageRead` の回帰で発覚)。`.simultaneousGesture
  (LongPressGesture(...))` に切り替えて解決 — 詳細は
  `MessageListRow.swift` のコメント参照。
- **Undo トーストの遅延コミット設計の欠陥**: 最初の実装は削除/アーカイ
  ブの実際の DB 書き込み・opQueue enqueue 自体を Undo ウィンドウ (5秒)
  分だけ `Task.sleep` で遅延させていた。`scripts/verify-ios-m3.sh` のオ
  フライン削除フェーズがこれを壊れた状態で検出: ウィンドウの途中でアプ
  リが再起動すると、遅延中だった書き込みがプロセスと一緒に消え、削除が
  サーバーへ一切 replay されなかった (サイレントなデータロス)。修正: ロ
  ーカル書き込みは即座にコミットし (再起動しても disk 上に残るので次回
  起動時の通常の opQueue replay が拾う)、Undo は「削除前の `MessageRecord`/
  `ThreadRecord` を再挿入し、まだ replay されていない opQueue 行を消す」
  という真の巻き戻しにした — `MessageListView.RemovedMessagesSnapshot`/
  `undoRemoval(_:)` 参照。
- **1a の下部タブバーが既存スワイプテストを壊した**: `OtegamiM3SwipeActionsUITests
  .testSwipeMarksMessageRead` が対象にしていた seeded 行が、新しいタブ
  バー (design-phase-2 以前は存在しなかった) の分だけ狭くなったビュー
  ポートの下端に近づき、`swipeRight()` が確実に反応しなくなっていた —
  コードの不具合ではなく、`testSwipeDeletesMessageOffline` が別の行です
  でに使っていた「スクロールでエッジから離す」パターンをこのテストにも
  追加して解決。

### 検証済み

`scripts/verify-ios-m1/m2/m3/m4/m5/m6*/m7/m8.sh`、
`verify-ios-account-edit.sh`、`verify-ios-drafts-sync.sh`、
`verify-macos-qa.sh` を実行 (m6 は `GOOGLE_OAUTH_CLIENT_ID` がこの開発機
の `Config/Local.xcconfig` に設定済みという、このタスクと無関係な既存の
環境差で1件失敗 — アプリ側のコードは変更していない)。ライト/ダークの
実機スクリーンショットと `DesignSystemCatalogRenderer` の両方で見た目を
確認済み。`make test` / `make ios` / `make mac` すべて green。

### 次フェーズへの申し送り

- `OtegamiColor` への `warning` 系トークン追加の検討。
- 翻訳機能実装時: `MessageListRow.trailingSwipeActions`/
  `selectionBottomBar` の「翻訳」「後で」「まとめて翻訳」スロットへの実
  装差し込み。
- 「移動」の汎用フォルダピッカー化 (現状はアーカイブ固定)。
- 1a の `AccountFilterChip` 横スクロール行が実際にアカウント5つ以上でど
  う見えるかは、まだ実機の多アカウント環境で確認していない。

## design-phase-3: 目視レイアウト修正・翻訳UI・残り画面

design-phase-2 の実機スクリーンショットを目視で確認したところ、2点の
レイアウト崩れが見つかった。原因調査と修正の記録。

### チップ列と一覧の間の不自然な余白

1アカウントのみの状態で `MailTabView` を実機スクリーンショットで確認す
ると、`AccountFilterChipRow` と `MessageListView` の `List` の間に、どち
らの View にも属さない空白帯が見えた。原因は `List` 側: `Section` を明示
していない `List { ForEach { ... } }` も暗黙に1つのセクションとして扱わ
れ、iOS 17+ の `List` はセクション間 (先頭セクションの上も含む) に既定の
`ListSectionSpacing.default` (見出し付きの複数セクションを視覚的に区切
る前提の、それなりに大きい固定値) を入れる。`AccountFilterChipRow` が
`List` の直前に同じ `VStack` で並ぶ 1a 特有のレイアウトでこれが単なる
「意図しない空白」として露出した。`.listSectionSpacing(.compact)` を
`MessageListView` の `List` に追加して解決 (`MessageListRow` が個々の行
で `.otegamiRowDivider()` を使っている密度に合わせた値)。

### 右端のアカウント名ラベル・左罫線の1アカウント時の出し分け

`ThreadRowView.showsAccountAccent` (アカウント色の左罫線＋右端のアカウン
ト名ラベル) は design-phase-2 で「統合受信トレイの『全部』フィルタ時だけ
表示」という条件だったが、**アカウント数を見ていなかった**ため、アカウ
ントが1つしかない状態でも統合受信トレイでは常に表示されてしまっていた
(実機スクリーンショットで発覚 — 1アカウントしかないのに全行に同じアカ
ウント名が付き、件名の表示幅を無意味に圧迫していた)。`MessageListView.
showsAccountAccent`/`SearchTabView.showsAccountAccent` の両方に
`environment.accounts.count > 1` の条件を追加。1アカウント → 2アカウント
に増やしたときに罫線・ラベルが正しく現れることも実機スクリーンショット
で確認済み (`docs/verify.md` の該当箇所参照)。

### 翻訳UI (1i) の実装

`MessageView` を「件名 → 送信者行 → 翻訳バー → 本文 → (下部) 返信/英語で
返信を下書き/全員に返信」の順に再構成した。翻訳バー本体は
`TranslationBar.swift`、訳文の段落表示は `TranslatedBodyView.swift`
(いずれも `Sources/Features/ThreadDetail/`) に分離 — 状態遷移
(`.none/.translating/.translated/.failed`) は `MessageView` 側の
`@State` が持ち、両ビューは値/バインディングを受け取るだけの「見た目だ
け」のコンポーネントにした (`MessageListRow`/`ThreadRowView` と同じ「コ
ンテナがオーケストレーション、子ビューは表示専用」という既存の分割方
針を踏襲)。

- **表示条件**: `message.detectedLanguage == "en"` の時だけバーを出す
  (プラン通り)。翻訳自体が使えるかどうか (`AppEnvironment
  .isTranslationAvailable`、`SystemLanguageModel.default.availability`
  を forward) は別軸で、非対応環境ではバーの見出しが「この端末では翻訳
  を利用できません」に変わり、セグメント/翻訳ボタンは出さない。
- **既定は訳文**: `TranslationBar` のセグメント (`showOriginal`) は
  `false` (訳文) がデフォルト。
- **自動翻訳 vs ボタン開始**: 1l の「英文を自動で翻訳」設定 (既定 ON、
  `TranslationSettingsStore`) が ON のときだけ `MessageView.load()` の
  末尾で自動的に翻訳を開始する。OFF のとき、または翻訳が失敗したときは
  バーに「翻訳」/「再試行」ボタンが出て、明示タップが起点になる。オン
  デバイス翻訳はコストがある (`docs/translation.md` 実測で数秒〜) との
  判断から、既定 ON はコストと利便性のトレードオフとして選んだデフォル
  ト値であり、いつでも設定でオフにできる。
- **段落長押しで原文表示**: `TranslatedBodyView` は
  `MessageTranslationRecord.paragraphs` (原文/訳文ペアの配列) を
  1段落ずつ `Text` として描画し、`.onLongPressGesture` で
  その段落だけ `Set<Int>` の on/off を切り替える。訳文全体を原文に戻す
  操作はセグメントピッカー側 (バー) が担当し、段落単位の切り替えとは独
  立している。
- **HTML メールの扱い (ハンドオフに無い判断)**: 翻訳エンジンは常にプレ
  ーンテキストの段落配列を返す (`docs/translation.md`)。HTML 本文のメ
  ールで「訳文」を選んだときは、`HTMLTextExtractor` で抽出したプレーン
  テキストを翻訳し `TranslatedBodyView` で表示する — つまり訳文表示時
  はリンクや太字などの HTML 装飾を失う。「原文」に戻せば元の
  `HTMLMessageView` (`WKWebView`) がそのまま出る。翻訳 API がプレーン
  文字列しか扱わない以上、HTML を保持したまま翻訳を差し込む経路は無く、
  実装コストに見合わないと判断してこの制限を受け入れた。
- **ストリーミング表示は今回見送り**: `TranslationService.translateStream`
  はエンジン層に実装・検証済み (`docs/translation.md`) だが、UI 側は
  `MessageTranslator.translate(messageId:...)` の非ストリーミング版のみ
  呼んでいる。段落ごとの逐次更新 UI は本フェーズのスコープに対して追加
  コストが見合わないと判断 (訳文/原文トグル・段落長押しの要件は非スト
  リーミングで満たせる) — 体感速度向上が欲しくなった時点で
  `translateStream` を差し込む余地は残してある。

### 1i の下部: 「返信」/「英語で返信を下書き」/「全員に返信」

ハンドオフの「「返信」と「英語で返信を下書き」を対で置く」を、返信ボタ
ンをヘッダから本文の下 (旧: ヘッダ内に「返信」「全員に返信」があった)
に移し、`返信`・`英語で返信を下書き` を隣接させ、`全員に返信` は
`Spacer()` で少し離して配置することで実現した。「英語で返信を下書き」
は `AppEnvironment.isTranslationAvailable` が `false` の端末では出さな
い (失敗するだけの導線を見せない)。

`onReply` コールバックのシグネチャを `(Int64, Bool)` (messageId,
replyAll) から `(Int64, Bool, Bool)` (messageId, replyAll,
translateToEnglish) に拡張し、`MessageView → ThreadDetailView →
MailTabView/SearchTabView → OtegamiTabRootView/RootView` の全経路と
`ComposerLaunchPayload.Kind.reply` に `translateToEnglish` を通した。
「英語で返信を下書き」は同じ `.reply` 経路を使い、`translateToEnglish:
true` を渡すだけ — `ComposerView` 側でこのフラグを見て「英語に翻訳して
送る」トグルを開いた瞬間から ON にする (1k 参照)。新しい返信文面を自動
翻訳するわけではなく、「これから書く返信を英語で送るモードで開く」だ
け — 実際に何を翻訳するかはユーザーが本文を書き終えてから決まるため。

### 1k 作成・返信画面

- **差出人を最上段に常時明示**: 既存の `ComposerView` はもともと Form
  の最初のセクションが `Picker("From", ...)` だったため、ハンドオフの
  「差出人: <アカウント> ▾」要件はほぼそのまま満たしていた。今回は変更
  していない。
- **「英語に翻訳して送る」**: 1k は「下部ツールバーに 📎 と『英語に翻訳
  して送る』」と書いているが、本アプリの Composer は `Form` ベースで独
  自の下部ツールバーを持たない (📎 も既存の「添付ファイル」セクション
  内のボタン) ため、同じ Form の並びに「翻訳」セクションとして `Toggle`
  を追加した。トグル ON で送信すると、`send()` の冒頭で `bodyText` を
  `environment.translationService.translate(_:from:.japanese,to:.english)`
  で置き換えてから送信本文を組み立てる。**`bodyText` 自体を書き換える**
  設計にした (裏で見えないまま翻訳して送るのではなく、翻訳結果がその場
  で見える/直せる) — 「翻訳を読み専用機能にしない」という 1i の精神を
  1k 側でも踏襲した判断。翻訳に失敗したら送信自体を中断し
  (`composer.translateErrorMessage`)、日本語のまま誤って送られることは
  ない。
- **既知の制限**: 返信の引用部分 (`> ` プレフィックス) も含めて丸ごと
  翻訳される。引用が英語原文であっても再翻訳の対象になり、結果が多少変
  わりうる。引用部分だけを翻訳対象から除外するには本文の構造化 (引用と
  新規入力の境界を状態として持つ) が必要で、今回のスコープでは見送っ
  た。

### `ComposerView.body` の分割 (CI 型チェック対策)

「翻訳」セクションを `Form` に足しただけで、ローカルビルドで
`the compiler is unable to type-check this expression in reasonable
time` が発生した (`docs/ci.md` が警告する形そのもの: `Form { Section {
ForEach { 複数行の HStack/VStack } } }` が1つの `body` 式に積み上がって
いた)。`fromSection`/`addressSection`/`subjectSection`/`bodySection`/
`attachmentsSection`/`translationSection` の6つの computed property に
分割し、添付行の `ForEach` クロージャも `AttachmentRow` という独立
`View` に切り出してようやく解消した — `MessageListView`/`ThreadDetailView`
がすでに確立していた「行の中身を切り出すだけでは不十分なことがある、
呼び出し側のクロージャ自体も切り出す」という教訓が、`List`/`ForEach`
だけでなく `Form`/`Section` でも同様に当てはまることを確認した。

### 1j 検索画面

`SearchTabView` にフィルタチップ行 (`SearchFilterChipRow`、
`SearchFilterOption`: 全部/添付/未読/英語) と 人/メール のセクション分
けを追加した。

- **フィルタはクライアント側**: `SearchQuery.threadSummaries` が返した
  結果に対し `hasAttachments`/`unreadCount`/`detectedLanguage` で絞り
  込むだけなので、チップを切り替えるたびに GRDB へ再クエリしない (どの
  条件も既にフェッチ済みのフィールドの上に成立する)。
- **人/メール のセクション分けは近似実装**: `SearchQuery` はマッチした
  理由 (件名か本文か送信者か) を返さない。厳密に「差出人一致」と「本文
  /件名一致」を区別するには FTS5 のクエリ自体を分けるか、`snippet()`
  などで一致位置を取得する必要があり、今回のスコープに対しては過大と
  判断した。代わりに「検索文字列がその結果の最新メッセージの送信者名/
  アドレスに含まれるか」をクライアント側で判定し、含まれれば「人」、
  そうでなければ「メール」に振り分けている。件名/本文一致のみを検出す
  る保証はないが (送信者名がたまたま一致した場合は「人」に入る)、「人
  を探しているのか、メールを探しているのか」という利用者体験上の区別
  は再現できていると判断した。

### 1l 設定画面

`AccountsListContent` (iOS の「設定」タブ・macOS Settings シーンの「ア
カウント」タブの両方が共有) に「操作」「翻訳」の2セクションを追加し、
既存の「アカウント」ブロックと合わせて 3 ブロック構成にした。

- **操作: スワイプのクイック操作**: ハンドオフの「スワイプ割り当てのカ
  スタマイズ」を、**「既読/未読 と アーカイブ のどちらを先に (フルスワ
  イプ相当で) 出すか」という1軸の設定**に絞って実装した。理由:
  `.swipeActions` は宣言順の**最初の1つ**しかフルスワイプで自動発火で
  きない (design-phase-2 で確定済みの制約)。左スワイプ (削除) は誤操作
  防止のため常にタップ確定であり、これ自体をカスタマイズ対象にしていな
  い。翻訳/後で は design-phase-2 時点でまだ機能が無くスロットが空のま
  ま。つまり実質的に選べる余地は「既読/未読 と アーカイブ、どちらが早
  いか」の2択しかなく、任意のアクションを任意のスロットに割り当てる汎
  用レジストリを作るのは (`MessageListRow`/`MessageListView` の
  `onToggleRead`/`onArchive`/`onDelete` という直書きの closure 群を丸ご
  と作り直すことになり) 得られる価値に対してリファクタリングコストが不
  釣り合いと判断した。設定は `SwipeActionSettingsStore` (`UserDefaults`
  キーのみを1箇所にまとめた enum) + `@AppStorage` で永続化し、
  `MessageListRow.leadingSwipeActions` が宣言順を切り替える。
- **翻訳: 英文を自動で翻訳 (既定 ON) / 一覧に要約を出す (既定 OFF)**:
  `TranslationSettingsStore` で2つの `UserDefaults` キーを定義し、
  `UserDefaults.registerOtegamiTranslationDefaults()` を `AppEnvironment
  .init()` から呼んで既定値を登録している。前者は実際に
  `MessageView` の自動翻訳トリガーを制御する (上記「翻訳UI」参照)。
  **後者 (一覧に要約を出す) は今回 UI に実装していない** — 一覧行の要
  約をタップせず表示するには、スクロール中の全English行に対して背景で
  翻訳/要約をトリガーする仕組み (いつ・どのタイミングで走らせるか、
  キャッシュの扱い) が新たに必要で、メッセージを開いたときにだけ翻訳す
  る現状の設計より一段大きい機能になる。トグル自体は用意し永続化もする
  が、一覧側は現時点で何も参照していない — 「設定項目だけ用意して素通
  りにする」のではなく、動かない理由をここに明記する形を選んだ (指示
  にある「実装コストを見て…docs に理由を書いて見送る」を採用)。

### 検証で見つかった実装バグ

- **`MessageView.load()` が翻訳判定に古い `MessageRecord` を使っていた**:
  本文が未取得のメッセージを初めて開いたとき、`detectedLanguage` は
  `SyncEngine.BodyFetcher` が本文取得と同時に設定するが、
  `kickoffTranslationIfNeeded(message:)` には本文取得**前**に読んだ
  `loadedMessage` (まだ `detectedLanguage == nil`) をそのまま渡してい
  た。結果、英語メールを初めて開いたときだけ翻訳バーが出ない (2回目以
  降、既にキャッシュされたメッセージを開くと直る) という不具合になっ
  ていた。実機 XCUITest (`OtegamiTranslationBarUITests`) が
  `translationBar` の待機に失敗して発覚し、コードレビューだけでは見つ
  からなかった。修正: ネットワーク経由の本文取得が終わった後に
  `MessageRecord` を再読込し、`@State message` と翻訳キックオフの両方
  をその新しい値で更新する。
- **iOS シミュレータの `.app` プロセスから `FoundationModels` を呼ぶと
  一貫して `LanguageModelError error -1` になる**: `docs/translation.md`
  の「既知の制限」に詳細を記録した。エンジン層自体は同じホスト上の
  `swift test` (サンドボックス化されていない macOS プロセス) からは毎
  回 2〜5 秒で正しく翻訳できることを都度確認しており、UI 側のコード/
  呼び出し方が原因ではないと判断している。翻訳バーの失敗状態
  (エラーメッセージ+「再試行」ボタン) は実機スクリーンショットで確認
  済み — 失敗時の見た目は正しく機能しているが、シミュレータ上での成功
  ケースは確認できなかった。

### 検証済み

`make test`/`make ios`/`make mac` すべて green。既存の XCUITest から
`OtegamiM3SwipeActionsUITests.testSwipeMarksMessageRead`
(スワイプのクイック操作を並び替え可能にした変更の回帰)、
`OtegamiM4ThreadDetailUITests` (返信ボタンをヘッダから下部バーへ移した
変更の回帰)、`OtegamiAccountEditUITests` の3ケース、
`scripts/verify-ios-m5.sh` フル実行 (作成・返信・オフラインキュー・
リプレイの10フェーズ全て) を再実行し green を確認した。新規に
`OtegamiTranslationUITests`/`OtegamiSearchFilterUITests`/
`OtegamiDesignPhase3ScreenshotUITests` を追加 (詳細は `docs/verify.md`)。

### 次フェーズへの申し送り

- 「一覧に要約を出す」設定を実際に一覧行へ反映する機能 (上記参照)。
- 翻訳のストリーミング表示 (`TranslationService.translateStream` は
  エンジン層にあるが UI からは未使用)。
- 引用部分を除いた「新規入力した本文だけ」を英訳する仕組み (1k)。
- スワイプの「操作」設定を、翻訳/後で のスロットが実装された時点で
  汎用的な割り当てに拡張するかどうかの再検討。
- シミュレータの `.app` プロセスから `FoundationModels` を呼んだ際の
  `LanguageModelError -1` の原因調査 (実機での再検証、または Apple の
  リリースノート/フォーラムでの既知の制限の有無確認)。

## 新画面構成: 下部タブバー廃止・ハンバーガーメニュー・検索強化・
メール本文フッターツールバー

design-phase-2/3 で確定した 1a (下部タブバー3つ) を、ユーザー要望により
ハンバーガーメニュー＋ヘッダ検索ボタン＋メール本文画面のフッターツール
バーへ置き換えたバッチの記録。iOS のみ (macOS の3ペインは無変更)。

### 1. ハンバーガーメニュー

`OtegamiTabRootView`/`MailTabView`/`SettingsTabView`/`SearchTabView` を
`OtegamiRootView`/`MailScreenView`/`SettingsSheetView`/`SearchScreenView`
に再編した。iOS の唯一の常設画面は `MailScreenView` で、
`HamburgerMenuContainer` (leading-edge のサイドドロワー、スクリム tap
またはドラッグで閉じる) が `FolderListSheet` の中身 (統合受信トレイ／
アカウント別ツリー／下書き／送信待ち／同期エラー) を包む。設定は
`FolderListSheet` の一番下のセクション (`settingsSection`) から
`SettingsSheetView` をシート表示する。

- **シートではなくドロワーにした理由**: Gmail 等の主要メールアプリの
  ハンバーガーメニューは leading-edge のドロワーが通例。加えて、
  `FolderListSheet` の各行が「別のシートを開く」導線を持つため、この
  メニュー自体がシートのままだと「シートからシートを開く」というこの
  アプリで既知の壊れ方 (design-phase-2 以前から) を踏む — ドロワー化した
  ことで `MailScreenView.presentAfterClosingMenu(_:)` はドロワーを閉じて
  即座に次のシートを立てるだけの単純な実装で済むようになった
  (旧 `pendingPostFolderAction` + `onDismiss` の間接呼び出しが不要に)。
- **エッジスワイプで「開く」ジェスチャーは実装していない**: この
  アプリの `NavigationStack` の戻るジェスチャー (画面端からのスワイプ)
  との競合リスクがあり、ハンバーガーボタン自体が確実な開閉手段として
  常にあるため、「閉じる」方向のスワイプ (ドラッグ追従 + 閾値) だけを
  実装した。開くのは常にボタンタップ。

### 2. 検索の移設と強化

`SearchScreenView` (旧 `SearchTabView`) はヘッダの検索ボタン
(`mail.searchButton`) からシート表示する。追加した要素:

- **アカウントの絞り込み** (`SearchAccountFilterChipRow`、2アカウント
  以上のときだけ表示 — 1アカウントのみなら「全部」チップが常に同じ
  1件を指すだけで冗長、という 1d/`showsAccountAccent` と同じ判断)。
- **検索演算子** `from:`/`to:`/`cc:`/`subject:` —
  `SearchQuery.parse(_:)` がトークンを演算子とフリーテキストに分割し、
  `SearchQuery.threadSummaries(parsed:scope:limit:db:)` が両者を
  `Set<Int64>` の積集合として組み合わせる (AND 条件)。`message.toText`/
  `.ccText` (v18 migration) は `fromText` (v7) と同じ理由でプレーン
  テキストミラーとして追加した — JSON `.blob` 列を直接 `LIKE` できない
  ため。発見可能性は検索フィールドのプレースホルダ
  ("差出人・件名・本文 (from:/to:/subject: も使えます)") で担保した。
- **検索履歴** (`SearchHistoryQuery`/`SearchHistoryRecord`, v20
  migration) — 直近 `SearchHistoryQuery.maxEntries` (20) 件を新しい順に
  表示、タップで再検索、スワイプで個別削除、「履歴をすべて削除」で
  一括削除。同じクエリ文字列を再検索すると (`UNIQUE` 制約 +
  delete-then-reinsert) 重複を作らず先頭に戻る — `updatedAt` だけの
  `UPDATE` ではなく削除→再挿入にしたのは、`id DESC` を `updatedAt DESC`
  の次点タイブレークにして「同じ `Date()` tick に収まった2回の記録」でも
  決定的な順序になるようにするため (`SearchHistoryQuery.record(_:db:)`
  のドキュメントコメント参照 — テストで実際に踏んだ)。

macOS の `MessageListView` 自身の `.searchable` インライン検索は
変更していない (`SearchQuery.threadSummaries(query:...)` を経由するため
演算子は自動的に使えるようになっているが、アカウントチップ・履歴 UI は
iOS の `SearchScreenView` 専用のまま)。

### 3. メール本文画面のフッターツールバー

`ThreadDetailView` に `MessageDetailFooterToolbar`
(`.safeAreaInset(edge: .bottom)`) を新設し、`MessageView` にあった
旧「返信/全員に返信/英語で返信を下書き」ボタン行を撤去した。対象は
常にスレッド内の**最新メッセージ** (`ThreadDetailView.newestMessage`) —
macOS の ⌘R (`RootView.replyToSelectedThread()`) が既に使っていた
「展開されている最新メッセージに返信する」という規則をそのまま踏襲した。

- **返信**: `Menu` (返信/全員に返信の2択)。
- **転送**: 新規実装。`ComposerLaunchPayload.Kind.forward` →
  `ComposerView.prefillForward(originalMessageId:)`。件名に `Fwd: ` を
  付与、`> ` 引用 (返信と同じ `quotedBody(from:)`) の前に
  「---------- 転送されたメッセージ ----------」ヘッダーブロックを挿入。
  宛先 (To/Cc) は空のまま — 転送は「誰に送るか」をユーザーが必ず選び
  直す操作という判断。`inReplyToMessageId`/`references` は設定しない
  (転送は新しい会話として扱う)。**添付ファイルは引き継ぐ** —
  `loadServerDraft(messageId:)` と同じ `syncCoordinator.fetchAttachment`
  経路で、本文同様ネットワーク越しに取得してから引き継ぐ。一部だけ
  取得できなかった場合は本文末尾にその旨を追記する (「全く引き継がない」
  ではなく「引き継げなかった分だけ明示する」形を選んだ — 指示の
  「引き継がないなら本文にその旨表示」を実用性寄りに解釈した判断)。
- **検索**: `from:<最新メッセージの差出人アドレス>` をプリセットした
  `SearchScreenView` を開く。**iOS のみ配線** — macOS の
  `detailColumn` (`OtegamiApp.swift`) には渡していない。理由: macOS の
  検索は `MessageListView` 自身の `.searchable` (`contentColumn` 側の
  状態) であり、`detailColumn` から直接書き換える手段が今のところ無い
  ため。`onSearchFromSender` が `nil` のときツールバーは検索アイコン
  自体を出さない。
- **情報**: `MessageHeaderInfoView` — Message-ID/In-Reply-To/References/
  From/To/Cc/Bcc/Reply-To/件名/日時/Content-Type/メールボックスパス/UID/
  サイズを表示。**生ヘッダ (RFC822 の `HEADER` パート全体、Received
  チェーンを含む) は表示しない** — このアプリは受信メールの生ヘッダを
  一度も保存しておらず (`MessageBodyRecord` は本文のみ)、
  `MailTransport`/`MailCoreIMAPSession` にも生ヘッダだけを取得する API
  が無い。新設するには IMAP `FETCH BODY[HEADER]` の新しい往復を
  transport 層から通す必要があり、このバッチの他の作業に対して
  不釣り合いなコストと判断し見送った。ローカル DB に既にある envelope
  情報の表示に留め、画面内にその旨の注記を出す。次フェーズの課題として
  ここに記録する。
- **「…」メニュー**: ミュート/ミュート解除、ピン留め/解除、未読にする、
  アーカイブ、迷惑メールにする、英語で返信を下書き (翻訳が使える端末の
  み)、ツールバーをカスタマイズ、削除。これらのスレッド操作
  (`ThreadDetailView` の "MARK: - 新画面構成 (3): スレッド操作" 節) は
  `MessageListView` の同等のスワイプ/コンテキストメニュー実装
  (`toggleRead`/`archiveThread`/`junkThread`/`togglePin`/`deleteThread`)
  を再利用せず、**独立した実装**にした — `MessageListView` 側は
  undo トースト (`scheduleUndo`)・検索結果配列 (`searchResults`) という
  そのビュー固有の状態と密結合しており、無理に共有するとこの画面が
  それらの状態を持つ理由のない依存関係を抱えることになる。
  `ThreadQuery`/`OpQueue` を直接読み書きする同じパターンを独立に実装する
  のは、macOS の ⌘⌫ (`RootView.deleteSelectedThread()`) が design-phase-2
  以前から既に採用している「コードは共有しないが振る舞いはブレない」
  という前例に倣った判断。**このバッチではアーカイブ/迷惑メール/削除に
  undo トーストを出さない** — 実行後 `dismiss()` で一覧へ戻ること自体が
  即座のフィードバックになる、という簡略化。
- **ミュート**: `ThreadRecord.isMuted` (v19 migration) +
  `ThreadQuery.setMuted(threadId:muted:db:)`。**ローカル限定の表示意図
  フラグであり、プッシュ通知は抑制しない** — `NotificationService`
  Extension は otegami-relay からの `mutable-content` プッシュを受けて
  *その場で IMAP 経由の envelope 取得* をトリガに動くだけで、relay
  自体はスレッドという概念もミュートという概念も持たない (メールボックス
  単位で「新着があるか」しか watch しない)。ローカル専用のミュート状態を
  relay に伝える経路 (クライアント→relay の同期チャネル) はこのアプリに
  存在せず、新設するのはこのバッチの範囲を大きく超える。一覧側の
  控えめ表示 (ダイム表示) は本バッチの範囲内で実装したが、通知抑制は
  次フェーズの課題として残す。
- **ツールバーのカスタマイズ**: `MessageToolbarSettingsStore`
  (`UserDefaults` にカンマ区切りで永続化、`SwipeActionSettingsStore` と
  同じ「素の `UserDefaults` キーの集まり」方針) + `MessageToolbarSettingsView`
  (常時編集モードの `List`/`.onMove`)。5アクション
  (`MessageToolbarAction.allCases`) は常にすべて表示、並び順だけを
  変更できる — 有効/無効の概念は無い (「その他」を含めた自由な並び替え
  も許可している。オーバーフローとして固定位置にする強制はしていない)。

### 検証で見つかった既存の環境依存の落とし穴 (このバッチで新たに確認)

- **`xcodebuild test -only-testing:` の1つのテストクラスが終わった後、
  アプリがバックグラウンドへ遷移することがある** —
  `scripts/verify-ios-m5.sh` の Phase 2/3 間 (compose→send の直後に
  Mailpit へ届くのを host 側でポーリングする) でこれを実機で確認した。
  C7 送信キャンセル (`SendCancelSettingsStore` 既定5秒) のカウントダウン
  中にこの背景遷移が起きると、`PendingSendCoordinator.finalizeNow()` が
  `beginBackgroundTask` 付きで即座に `replayOpQueue` を試みるはずだが、
  実際には `opQueue` の `send` op が `attempts=0` のまま (＝一度も
  リトライされずに) 何分も溜まり続け、**次にアプリをフォアグラウンドへ
  戻したとき (`RootView.handleScenePhaseChange` の `.active` 経由の
  `syncAllAccountsOnce()`) に初めて実際に送信された**ことを、
  App Group 内の `otegami.sqlite` を直接 `sqlite3` で確認して裏付けた
  (`opQueue`/`outboxMessage` の行が残っていること、フォアグラウンド化後
  数秒で Mailpit に届くことの両方を確認)。**このバッチの UI 変更が原因
  ではない** — `PendingSendCoordinator`/`OpQueueProcessor`/
  `RootView` のシーンフェーズ処理は一切変更していない。Simulator の
  バックグラウンド実行タイムアウトが実機より短い/不安定という既知の
  制限 (M9 の「シミュレータは実 APNs デバイストークンを発行しない」と
  同種の Simulator 固有の限界) の一種と見られるが、確証は得られていない
  ため次フェーズの調査課題として記録する。**この不具合は本バッチの
  コード変更を一切必要としない** — `docs/verify.md` へも記録した。
- **`screenshot_mid_test` 方式のタイミング window が構造変更でずれる**:
  検索/設定がタブの瞬時切り替えからシート表示 (アニメーション込み) に
  変わったことで、`verify-ios-m7.sh`/`verify-ios-m4.sh` の固定 `sleep N`
  ウィンドウが軒並み早すぎ、目的の画面 (検索結果、スレッド詳細) では
  なく直前の状態 (検索履歴、メール一覧) を捉え続けた。両スクリプトの
  ウィンドウを実測ベースで調整し、`docs/verify.md`/このファイルに記録
  した — この手法自体がタイミングに脆弱であることは M6 時点から
  既知の制約 (`docs/verify.md`) であり、今後も画面遷移の重さが変わる
  たびに再調整が必要になりうる。

### 検証済み

`make test`/`make ios`/`make mac` すべて green。
`scripts/verify-ios-m1.sh`/`verify-ios-m4.sh`/`verify-ios-m7.sh` を
実際の dev mailstack に対して実行し green (`verify-ios-m5.sh` は
Phase 1/2 の UI フロー — SMTP アカウント追加・作成・送信操作自体 — は
green、Phase 3 以降の Mailpit 到達確認は上記の背景遷移タイミング問題で
不安定)。ハンバーガーメニュー・アカウント絞り込みチップ・検索演算子の
プレースホルダ・検索履歴・スレッド詳細のフッターツールバーは実機
スクリーンショットで目視確認済み。新規 XCUITest は追加せず、既存の
壊れたテスト (`tabBars`/`mail.folderTitleButton`/`messageDetail
.replyButton` 等に依存していたもの) を新構成に合わせて更新した
(`apps/Otegami/UITests/` 配下、詳細は該当コミット参照)。

### 次フェーズへの申し送り

- メール本文画面「情報」の生ヘッダ表示 (要 IMAP `FETCH BODY[HEADER]`
  API の新設)。
- スレッドミュートによるプッシュ通知抑制 (要 relay 側のミュート対応、
  クライアント→relay 同期チャネルの新設)。
- `PendingSendCoordinator`/`OpQueueProcessor` の Simulator 固有と見られる
  バックグラウンド送信タイミング不具合の原因調査 (実機での再検証)。

## 表示・操作改善バッチ: カード状一覧・翻訳/AI要約・作成画面の添付統合・
アカウントフォーム・表示言語

ユーザー要望の表示・操作改善10項目 + リンクブラウザバグ調査をまとめた
バッチの記録。

### 1. 一覧のカード状表示

`ThreadRowView`(統合トレイ・メールボックス別・検索結果すべてで共有) の
背景に `.otegamiCardBorder()`(新規、`SectionDivider.swift`) — 2pt
`OtegamiColor.divider`の全周罫線 — を追加し、`MessageListRow`/
`SearchScreenView.searchRow`の`.listRowInsets`を`.zero`から実マージン
(`OtegamiSpacing.xs`縦・`OtegamiSpacing.sm`横) に変更した。このマージン
自体が隣接カード間の隙間になる — 罫線だけでは`List`の行同士が密着した
ままなので、隙間はマージン、区切りは罫線、の二段構えで「面で区切られた
カード」を表現している。角丸は無し (`OtegamiRadius.none`、Modernist ベ
ースの既存方針どおり)。旧来の1pt dashedの行間罫線 (`.otegamiRowDivider()`)
はこの2箇所での使用をやめた (関数自体は汎用ユーティリティとして残置)。

### 2. 一覧の時刻表示

`OtegamiDateFormat.listRowText(for:)`(新規、`DesignSystem/`) — 今日の
メールは時刻のみ、当年内は月日+時刻、それ以前は年+月日+時刻、という
一般的なメールアプリの慣習に沿ったフォーマットを1箇所に集約した。
`ThreadRowTrailing`(一覧の右端日付) と `ThreadMessageSummaryRow`(スレッ
ド詳細の折りたたみ行、後述) の両方から参照する。

### 3. スレッド詳細の折りたたみ行にプレビュー/アイコン

`ThreadMessageSummaryRow`(`ThreadDetailView.swift`) はもともと折りたたみ
時に1行スニペットを出していた (プレビュー自体は既存) — このバッチで
`SenderAvatar`(24pt、`ListDisplaySettingsStore.showAvatarInDetailKey`で
出し分け、`MessageView`本文ヘッダの既存アバターと同じ設定を共有) を追加
した。トップの一覧行 (`ThreadRowView`) と見分けがつくよう、意図的に
**カード罫線は使わず**、代わりに `OtegamiColor.paleBase`の淡いトーンと
余分な左インデント (`OtegamiSpacing.lg`) で「同じスレッド内で連続する
行」であることを表現している — カード罫線を使うと「独立した項目の集合」
という一覧と同じ信号になってしまい、スレッド内メッセージの連続性という
意味と矛盾するため。

### 4. 本文画面ヘッダから件名を除去

`ThreadDetailView.navigationTitle`を件名から固定の「メール」に変更し、
`MessageView`の`.navigationTitle(displaySubject)`は完全に削除した (件名
は`MessageView.header(for:)`内に既に表示されている — ネストされた
`MessageView`側にも`.navigationTitle`が残っていると、より深い階層にある
方がナビゲーションバーの表示を勝ち取ってしまい、「メール」固定化が効か
なくなるため、両方から取り除く必要があった)。

### 5. AI要約ボタン + 翻訳ボタンの表示条件

`AISummaryBar.swift`(新規) — `TranslationBar`と同じ「状態は親
(`MessageView`) が持ち、このビューは表示専用」という分担。言語を問わず
どのメッセージにも表示し (要約は原文が日本語でも英語でも意味がある)、
`TranslationService.summarize(_:targetLanguage:)`を呼ぶ。結果は
永続キャッシュしない (`MessageTranslator`のような専用キャッシュ層を
要約のためだけに新設するのはこのバッチの範囲に対して過大と判断 — 手動
ボタンでしか動かない機能なので、開き直すたびに再生成になる程度は許容)。
出力言語は`LocalizationSettingsStore.effectiveLanguageCode`に従う。

翻訳バー (既存の`TranslationBar`) 自体は変更していないが、**表示条件**
を「英語メールなら常に表示」から「英語メール **かつ** アプリの表示言語が
英語でない」(`MessageView.shouldShowTranslationBar`) に一般化した —
翻訳エンジンが英→日の一方向にしか対応していないため、「メールの言語 ≠
アプリの表示言語」を額面通り一般化することはできず、この一方向対応の
範囲で意味のある形に絞った。自動翻訳のキックオフ
(`kickoffTranslationIfNeeded`) も同じ条件に揃えている — バーを出さない
状況で裏でだけ翻訳が走る非一貫な状態を避けるため。

### 6. 「英語に翻訳して送る」の削除

`ComposerView`の`translationSection`(Toggle + Section、あらゆる新規/
返信作成で使えた汎用機能) を削除した。**内部の状態
(`translateToEnglishBeforeSend`) と`send()`の翻訳ロジック自体は残した**
— 翻訳バー側の「英語で返信を下書き」(`MessageDetailFooterToolbar`の
「…」メニュー、指示により維持) がこの同じ仕組みを使って動いている
(`ComposerLaunchPayload.Kind.reply`の`translateToEnglish`フラグ経由)。
つまり削除したのは「あらゆる作成画面から手動でON/OFFできる汎用トグル」
であって、「英語で返信を下書き」という特定の入口から起動する機能自体
ではない。

### 7. 添付ボタンの統合 + カメラ

`ComposerView.attachmentsMenu` — 「ファイルを追加」「写真を追加」の
2つの独立ボタンを、1つの「添付」`Menu`ボタン (ファイルを選択/写真を選択/
写真を撮る) に統合した。「写真を撮る」は`CameraPicker.swift`(新規、
`UIImagePickerController`の`sourceType == .camera`ラッパー) を別シート
で開く。シミュレータにはカメラハードウェアが無いため
`UIImagePickerController.isSourceTypeAvailable(.camera)`は常に`false`
— 項目自体は隠さず`.disabled`でグレーアウトする形にした (指示の
「シミュレータではグレーアウトか非表示」のうちグレーアウトを選択)。
`NSCameraUsageDescription`を`project.yml`に追加 (無いと権限ダイアログを
出さず即クラッシュする)。macOS には対応するカメラ/フォトピッカー API が
無いため、macOS 側は従来の「ファイルを追加」(`fileImporter`のみ) のまま。

**実装中に踏んだ実機さながらのシミュレータバグ**: `.sheet(isPresented:
$isShowingCamera)`を`attachmentsMenu`(`Form`/`Section`の奥、`Menu`本体)
に直接付けていたところ、「添付」メニューをタップした瞬間 (`isShowingCamera`
がまだ`false`のまま、何も選ぶ前) に`ComposerView`自身の`.sheet`
(`composer.sheet`) がまるごと閉じてしまう不具合をUITestで確認した —
`.fileImporter(isPresented: $isImportingFile)`が既に`body`のトップレベル
に付いている、というこのファイルの既存の配置規約に揃えて `.sheet`も
`body`直下へ移動して解決した。`PhotosPicker`をトリガービューとして
`Menu`の項目に直接埋め込む版も同時に試したが改善せず、状態駆動の
`.photosPicker(isPresented:selection:matching:)`(同じく`body`直下) に
切り替えた。

**この`Menu`をタップして開いた状態そのものをXCUITestで自動検証するのは
断念した** — 掘り下げた結果、この`Menu`固有の問題ではなく、このシミュ
レータ/Xcodeベータ環境全体の問題であることを突き止めたため:
このバッチで一切変更していない既存の`OtegamiTemplatesUITests`
(design-phase-3からある「テンプレートを挿入」`Menu`) と
`OtegamiLinkBrowserUITests`(C7、後述) の両方が、**このバッチの変更を
git stashで完全に取り除いた baseline のコードに対しても**同じ症状
(タップ後にpresentedされていたシート/画面が消え、裏のハンバーガー
ドロワー状態が見えてしまう) で失敗することを確認した。「開いた状態を
自動テストで検証する」ことそのものがこの環境では信頼できないと判断し、
`OtegamiDisplayBatchScreenshotUITests`(新規) では「添付」ボタンが単一の
統合ボタンとしてレンダリングされていること (閉じた状態) の構造確認まで
に留めている。閉じた状態の見た目・カード一覧・スレッド詳細は実機さなが
らのスクリーンショットで確認済み — 開いた状態のメニュー自体の見た目は
実機での確認が必要 (最終報告のPENDING参照)。

### 8〜10. アカウントフォーム

`AccountSetupView`/`AccountEditView`/`ICloudAccountSetupView`共通の
`otegamiEmailKeyboard()`/`otegamiNumberPadKeyboard()`(各ファイルに同じ
実装を複製 — 既存の`textFieldAutocapitalizationNone()`と同じ「ファイル
ごとに小さく複製する」既存方針を踏襲) を追加し、メールアドレス欄に
`.keyboardType(.emailAddress)`、IMAP/SMTPポート欄に`.keyboardType
(.numberPad)`を適用した。`AccountSetupView`のメールアドレス`onChange`
は、既存の「IMAPユーザー名が空ならメールアドレスを反映」に加えて
「SMTPユーザー名が空なら同様に反映」も行うようにした (どちらか一方だけ
手入力済みでも、もう片方はそのまま追従を続ける)。`AccountEditView`は
メールアドレス自体が編集不可 (既存方針、`AccountEditView`のdoc comment
参照) なため、ポート欄の数字キーボードのみ対象。

### リンクのブラウザオープン修正 (C7)

実機で「メール内リンクをタップしてもブラウザが開かない」報告を受けて
`HTMLWebViewCoordinator`(`HTMLMessageView.swift`) を調査した。ヒントに
沿って調べた結果、2点、実際のWKWebViewの既知の落とし穴に合致する未対応
箇所を発見し、修正した:

1. **`WKUIDelegate`が一切未実装だった** (`webView.uiDelegate`が`nil`の
   まま)。`target="_blank"`のようなリンクは`navigationAction.targetFrame`
   が`nil`になる — 既存の`decidePolicyFor`の`isMainFrame`判定
   (`targetFrame?.isMainFrame ?? true`) は理屈の上ではこのケースも
   フォールバックでカバーするはずだが、`decidePolicyFor`自体がこの
   ファイルの別の実測 (`loadHTMLString`が`decidePolicyFor`に一切現れない
   という、doc commentに記録済みの驚き) が示すとおり文書化された仕様と
   食い違う挙動をするWebKitバージョンがあり得る。`WKUIDelegate`の
   `webView(_:createWebViewWith:for:windowFeatures:)`を実装し (新しい
   `WKWebView`は一切作らず、対象URLを`decidePolicyFor`と同じ
   `onOpenLink`経路に渡すだけ)、`uiDelegate`をiOS/macOS両方の
   representableで設定した。
2. **`allowsLinkPreview`(既定`true`) を無効化していなかった**。実機の
   3D/Haptic Touchがリンクの長押しピーク・プレビューを認識しようとする
   ジェスチャー認識器と、単純なタップの認識が競合し得る — Simulatorには
   このハードウェアが無いため、design-phase-3時点のシミュレータ検証では
   この経路の不具合を再現できなかった、という説明と整合する。ピーク・
   プレビュー自体はこのアプリで使っていない機能なので、iOS側の
   `HTMLWebViewRepresentable.makeUIView`で明示的に`false`にした
   (`allowsLinkPreview`はiOS専用プロパティで、macOSには無い)。

**実機で直ったことを確認できていない**: シミュレータでの検証を試みた
が、上記「添付ボタンの統合」節に記録したのと**同じ環境要因**にぶつかった
— 既存の`OtegamiLinkBrowserUITests`(design-phase-3からある、C7のリンク
タップを検証するテスト) が、この修正を適用した状態でも、**この修正を
適用する前の baseline (git stash で完全に除去して再ビルド) でも**、
全く同じ症状 (リンクタップ後に`SFSafariViewController`が現れず、代わり
に本文画面自体がハンバーガードロワーの背後に消える) で失敗することを
確認した — つまりこの特定のXCUITestによる自動検証は、この修正の有無に
かかわらずこの環境では成立しない。コード自体は業界で広く知られた
WKWebViewの実際の落とし穴 (`WKUIDelegate`未設定、`allowsLinkPreview`との
ジェスチャー競合) に基づく妥当な修正だが、シミュレータ上でも実機上でも
「直ったこと」を確認できていない。実機での確認をユーザーに依頼する形で
`PENDING.md`に記録した。

### 表示言語

[docs/localization.md](localization.md) に分離して記録 (String Catalog
のセットアップ・ローカライズ手法・到達範囲)。

### このバッチで新たに確認した環境要因: シミュレータでの「開いた状態」
系操作の信頼性

design-phase-2の「`.onLongPressGesture`が`.swipeActions`を阻害する」、
M2の「`.tap()`後の`{-1,-1}`ヒットポイント」等、この環境固有の癖は既に
多数`docs/verify.md`に蓄積されているが、このバッチで新たに踏んだのは
**それらとは異なる系統の症状**: `Menu`のポップオーバー、`WKWebView`内の
リンクタップ後の`SFSafariViewController`シート提示、といった「タップの
結果、何か (シート/ポップオーバー) が追加で現れることを期待する」操作
が、この Xcode 27 beta / iOS 27 beta シミュレータでは、**タップの合成
自体は成功しているにもかかわらず**期待した提示が起こらず、代わりに
現在の画面 (シート/プッシュされた画面) 自体が消えて背後の画面が見える、
という形で失敗する。このバッチで変更していない既存コード
(`OtegamiTemplatesUITests`の対象、design-phase-3から存在) でも再現する
ことを確認済みなので、アプリのコード側の問題ではなく、環境側の何らかの
不安定性 (ベータ版シミュレータ/Xcodeの既知でない制限、またはXCUITestの
合成タッチとSwiftUIのpresentation機構の相性) と見られる。次にこの
シミュレータ/Xcodeが安定版に切り替わったタイミングで再検証する価値が
ある。

### 検証済み

`make test`/`make ios`/`make mac`すべて green。カード一覧・時刻表示・
スレッド詳細のプレビュー/アイコン・本文ヘッダの件名除去・添付ボタンの
統合 (閉じた状態) を実機さながらのスクリーンショットで確認
(`OtegamiDisplayBatchScreenshotUITests`、新規)。表示言語の英語切り替えは
一覧画面・検索画面のスクリーンショットで確認 (`docs/localization.md`)。
「開いた状態」系の目視確認 (添付メニュー展開・リンクタップ後のブラウザ
表示) は上記の環境要因により自動化できず、実機での確認をユーザーに依頼
する形で`PENDING.md`に記録した。

## 実機フィードバック第2弾: C カードデザインの変更・E スレッド表示のアコーディオン化

実機フィードバック第2弾バッチ (A〜J) のうち、デザインシステムに直接関わる
2項目の記録。

### C: カードの角丸解禁

design-phase-2 以来「Modernist ベース・角丸0」を一貫した方針として明記
してきたが (`OtegamiRadius.none`のドキュメントコメント参照)、ユーザーの
明示指定により**カードのみ**角丸を解禁した。

- **`OtegamiRadius.card = 8`** (新規、`OtegamiBorder.swift`) を追加。
  `OtegamiRadius.none = 0`はカード以外 (ボタン・チップ・バッジ・区切り線)
  に引き続き適用される — カードだけ丸めることで「これは独立してタップ
  可能な項目」という信号を一覧内の他要素と区別している。全部を丸めると
  この区別が失われるため、今回は角丸をカード限定のスコープに留めた
  (将来より統一感のある丸め方針に変える場合はこの判断を再検討する余地
  として残す)。
- **輪郭線を撤去**: `SectionDivider.swift`の`otegamiCardBorder()`
  (2pt `OtegamiColor.divider`の全周線) を`otegamiCardBackground(_:)`に
  置き換えた。新しい実装は指定色を`.background(_:)`で塗ってから
  `RoundedRectangle(cornerRadius: OtegamiRadius.card, style: .continuous)`
  で`.clipShape`するだけで、線は一切描かない — 面 (`OtegamiColor.surface`/
  `.paleBaseStrong`) だけでカードを表現するユーザー指定どおりの実装。
- **`AccountColorRail`との整合**: `ThreadRowView`の`AccountColorRail`
  (角のない矩形) は`clipShape`の対象に含まれる`HStack`の内側にそのまま
  残しており、`otegamiCardBackground(_:)`の丸め処理がカード全体
  (ラベルの縦棒を含む) に一括で効くため、ラベル縦棒もカードの丸い輪郭に
  沿って角が切り取られる — 「維持・調整」の「調整」はこのクリップだけで、
  `AccountColorRail`自体のコード (色・幅の決定ロジック) は無変更。
- カード同士の隙間は従来どおり`MessageListRow`/`SearchScreenView`の
  `.listRowInsets`が担う (角丸にしても間隔の作り方自体は変えていない)。
- カタログ (`CatalogBorderSection.swift`) に`OtegamiRadius.card`の
  スウォッチを追加し、目視確認できるようにした。

### E: スレッド表示のアコーディオン化

design-phase-2 の`ThreadDetailView`は「最新メッセージだけ初期展開、以降は
Gmail/Apple Mail 的に複数メッセージを独立して展開できる」実装だった
(`expandedMessageIds: Set<Int64>`)。ユーザー指定により**常に1通だけ展開**
する厳密なアコーディオンに変更した。

- **`expandedMessageId: Int64?`** (旧`Set<Int64>`) — 別メッセージのヘッダを
  タップすると、それが展開され他はすべて畳まれる。すでに展開中の行の
  ヘッダを再タップしても何も起きない (「展開ゼロ」はこの画面が想定しない
  状態のため — `load()`が読み込み直後に必ず最新メッセージを1つ展開する)。
- **フッターツールバーの操作対象**: 「返信」「全員に返信」「転送」「検索」
  「情報」は、E以前は常にスレッド内**最新**メッセージ (`newestMessage`)
  を対象にしていた (複数展開できる旧UIでは「対象は展開中のメッセージ」が
  曖昧になるため、最新固定という割り切りだった)。アコーディオン化により
  「展開中のメッセージ」が常に一意になったため、`targetMessage`
  (`expandedMessageId`に対応する`MessageRecord`、見つからない場合のみ
  最新へフォールバック) に対象を変更した — ユーザー指定の「フッター
  ツールバーの操作対象＝展開中のメッセージ、が明確になるように」に対応。
  macOS の ⌘R (`RootView.replyToSelectedThread()`) は今回変更していない
  (`ThreadDetailView`とは独立した実装で、引き続き「スレッド内最新」を
  対象にする — その doc comment に理由を明記済み)。
- **展開中メッセージの視覚的強調**: `ThreadMessageSummaryRow`に
  - 展開中だけ`OtegamiColor.accent`で塗る3pt左罫線 (`AccountColorRail`と
    同じ幅・同じ「この行は意味を持つ」という信号の再利用、ただしアカウント
    色ではなくアクセント色)。
  - 背景を`OtegamiColor.paleBase`(折りたたみ時と同じ) →
    `paleBaseStrong`(展開時、`ThreadRowView`の選択行と同じ「強い強調地」
    トークン) に変更。
  を追加した。左罫線の分だけ本文側の左パディングを`.lg`から`.sm`に
  調整し、罫線幅(3pt)+`.sm`(8pt)が旧`.lg`(16pt)相当の見た目になるよう
  帳尻を合わせている (展開・折りたたみで行全体の横位置がガタつかない
  ようにするため)。

### 検証

`make test`/`make mac`/`make ios` green。実機シミュレータでのライト/
ダーク両方のスクリーンショット目視確認は、他のバッチ項目 (D/F/G/H/I) と
まとめて本バッチ完了時に実施 (このファイルの後続コミット・
`docs/verify.md`参照)。

## 実機フィードバック第3弾: フラット表示の単一メッセージ化・HTML描画・
再表示高速化・過剰スレッド化抑制・設定整理

実機からの追加報告 (A〜K) をまとめて対応したバッチの記録。設定画面の
詳細は `docs/settings.md`、ローカライズの詳細は `docs/localization.md`
を参照 — このファイルは構造・描画・パフォーマンスに関わる項目 (A/B/C/D/
J/K) を扱う。

### A: フラット表示 (スレッド表示 OFF) で行をタップすると、その1通だけ
ではなくスレッド全体が展開されて開いていた

`MessageListView`のフラット行 (`ThreadSummary.singleMessageId`が非`nil`)
は、表示上は1メッセージだけの行だが、内部的には引き続き**実際の**
(複数メッセージを持ちうる) `thread.id`を保持している
(`ThreadSummary.init(flatMessage:accountId:)`のドキュメントコメント
参照)。タップ時に`ThreadDetailView(threadId: threadId)`を開く既存の経路
は、フラット行かどうかを一切見ておらず、常にその`threadId`配下の**全
メッセージ**を`ThreadQuery.messagesObservation(threadId:)`で読み込んで
いた — スレッド表示 OFF で1通だけ見せているつもりが、実際に開くとその
メッセージが属する会話の全メッセージがアコーディオンで並ぶ、という
不整合だった。

修正: `ThreadSummary.singleMessageId`を`MessageListRow.onSelect`/
`MessageListView.handleThreadSelected(_:)`経由で呼び出し側
(`MailScreenView`/`RootView`) まで伝播させ、`ThreadDetailView`に新設した
`singleMessageId`パラメータへ渡す。非`nil`のときは`load()`が
`ThreadQuery.messagesObservation(threadId:)`の代わりに、その1通だけを
監視する`ValueObservation`(`MessageRecord.fetchOne(db, key:)`) を使う —
スレッドが1通しかない場合の既存の「1行だけ表示・折りたたみ無し」の
描画パスをそのまま再利用でき、`ThreadMessageRow`/`ThreadMessageSummaryRow`
側の変更は不要だった。

- **操作対象もメッセージ単位に**: `MessageListView`の既読/未読・
  アーカイブ・迷惑メール・ピン留め・削除の各アクションは、フラット行
  でも常にスレッド全体 (`ThreadQuery.messages(threadId:)`) に対して実行
  していた。新設の`ThreadQuery.actionTargets(for summary: ThreadSummary,
  db:)`が`summary.singleMessageId`の有無で「そのスレッドの全メッセージ」
  と「その1通だけ」を切り替え、`MessageListView`の全アクション関数と
  `ThreadDetailView`の「…」メニュー (`targetMessageRecords(threadId:
  singleMessageId:db:)`、同じロジックを独立実装 — 理由は下記) の両方が
  これを経由するようにした。Undo トーストの文言も「スレッドを削除しま
  した」/「メールを削除しました」を`singleMessageId`の有無で出し分ける。
- **「次のメールを開く」設定 (G) はフラット単一メッセージ表示では効か
  ない**: `MessagePostActionSettingsStore`の「削除/アーカイブ後の動作」
  は`currentThreadOrder`(実スレッド ID の並び) を使って次を解決するが、
  フラット行はどのメッセージがどの行かという情報を保持していないため、
  「次のスレッド」は解決できても「次の行がどのメッセージか」は分から
  ない。誤って正しくないメッセージへ飛ぶよりは、`ThreadDetailView
  .notifyThreadRemoved()`が`singleMessageId != nil`のときは常に一覧へ
  戻る (`onThreadRemoved`を呼ばない) という安全側の仕様にした —
  スコープを絞った意図的な判断として doc comment に明記。
- **`ThreadDetailView.targetMessageRecords`を`nonisolated static`に
  した理由**: `dbWriter.write { db in ... }`クロージャ (task-isolated)
  から`self`を経由するインスタンスメソッドを呼ぶと Swift 6 の厳格な
  並行性チェックが「sending 'db' risks causing data races」を出す —
  `View`準拠型のメンバは (`static`含め) 既定で`@MainActor`になるため、
  `nonisolated`を明示しないと task-isolated なクロージャから呼べない。
  `threadId`/`singleMessageId`を`self`経由ではなく素の引数として渡す
  ことで解決した (`ThreadQuery.messages(threadId:db:)`のような既存の
  enum 内 static 関数が最初から問題にならなかったのと対照的)。

### B: マーケティング系 HTML メールがデスクトップ幅でレイアウトされ、
ロゴ画像が巨大に描画される

`HTMLMessageView`(`HTMLDocumentBuilder.wrap(bodyHTML:)`) は元々
viewport meta と `max-width: 100% !important`の CSS リセットを既に
持っていたにもかかわらず再現した。原因調査の結果、真因は
`MCOMessageParser.htmlBodyRendering()`が返す文字列自体にあると特定した
— 多くの実際の送信者 (特にマーケティング/通知テンプレート) はメールの
`text/html`パートに**完全な** `<html><head>...</head><body>...</body>
</html>`ドキュメントを書いており、`htmlBodyRendering()`はそれをほぼ
そのまま返す。旧実装の`<body>\(bodyHTML)</body>`は、この完全なドキュ
メントをこのアプリ自身の`<body>`タグの**内側**にネストしていた —
HTML5 のパースアルゴリズムでは「in body」挿入モード中に現れた
`<head>`開始タグは無視されるが、その後に続く`<meta>`/`<style>`は
`<body>`直下の通常コンテンツとして挿入されてしまい、この実機の WebKit
ビルドでは元メール側の (デスクトップ幅想定の) `<meta name="viewport">`
がこのアプリ自身の正しい viewport meta を実質的に上書きしてしまう
挙動を確認した。

修正: `HTMLDocumentBuilder.extractBodyContent(from:)`を新設し、渡された
HTML から`<body>...</body>`の中身だけを正規表現なしの文字列探索で取り
出してから、このアプリ自身の`<head>`(viewport meta・CSS リセット) で
包む。フラグメント (`<body>`タグを持たない、素直な HTML メール) は
そのまま返るので、この修正で既存の正常系に影響はない。追加で:

- `shrink-to-fit=yes`を viewport meta に追加。
- `overflow-x: hidden`を`html, body`に追加 (残存する横方向のはみ出しの
  安全網)。
- 幅固定テーブル対策として`table { width: auto !important; }`/
  `td, th { min-width: 0 !important; }`を追加 — `table-layout: fixed`
  (列比率を強制的に均等割りする、もっと強い手段) は見た目が崩れる
  ケースがあるため見送った (「やり過ぎない範囲で」という指示どおりの
  選択、`HTMLDocumentBuilder`内のコメント参照)。

検証用に`dev/mailstack/seed/fixtures/26-marketing-wide-html.eml`(参考
画像1相当 — 完全な`<html><head>`構造 + `viewport content="width=900"`
+ 900px 固定幅ラッパーテーブル + 900x300 の画像) を新設し、
`OtegamiWideMarketingHTMLUITests`/`scripts/verify-ios-b-html-render.sh`
で実機シミュレータに対して確認した。

### C: 一度表示したメールを再度開くと毎回読み込みが入り、体感が遅い

コードを読んだ限り、本文テキスト自体は`MessageView.load()`が
`bodyState == .fetched`ならローカル DB (`MessageBodyRecord`) から即座に
読んでおり、ネットワークには一切触れていない — 疑われていた「既読メール
でもネットワークを叩いている」という仮説はコード上は成立しなかった。
代わりに疑ったのは WKWebView 自体の初期化コスト: `HTMLMessageView`が
メッセージを開くたびに`WKWebViewConfiguration()`を新規に作っており、
`WKWebViewConfiguration.processPool`は明示的に共有しない限り**コンフィ
ギュレーションごとに新しい`WKProcessPool`**になる — つまりメールを
1通開くたびに WebKit のコンテンツプロセスをゼロから起動していたことに
なる (HTML メールに限らず、`HTMLMessageView`の設定関数自体は毎回呼ばれ
るため全メッセージが対象)。これは「起動し直すと読み込みが入る」という
報告の有力な説明になる。

修正:

1. **`HTMLWebViewProcessPool.shared`**: アプリ全体で1つの`WKProcessPool`
   を共有する。2通目以降にメールを開いたとき、同じセッション内で既に
   起動済みのコンテンツプロセスを再利用できる。
2. **`HTMLWebViewPrewarmer`**: `AppEnvironment.init()`から (`RootView`
   の初回描画をブロックしないよう`Task`経由で) 一度だけ、非表示の
   使い捨て`WKWebView`を同じ共有プロセスプールで生成し、空の HTML を
   読み込ませる。これにより*コールドランチの最初の1通*でもプロセスが
   既に温まっている可能性が高くなる — プロセスプール共有だけでは
   「2通目以降」しか救えない (最初の1通の時点ではまだ再利用できる
   プロセスが無い) ため、この事前ウォームアップを追加した。
3. `configuration.websiteDataStore = .default()`を明示 — 挙動は変えて
   いない (元々の既定値と同じ) が、WebKit 自身の永続ディスクキャッシュ
   (画像・HTTP キャッシュ) がアプリ再起動をまたいで効くことに依存して
   いる設計意図をコードとして明記した。

**リモート画像キャッシュについての判断**: `WKWebsiteDataStore.default()`
は WebKit 自身が管理する永続ディスクキャッシュで、アプリコンテナ内に
保存されアプリ再起動をまたいで残る (`.nonPersistent()`にしていない
限り)。このアプリは元々`.nonPersistent()`を使っていなかったため、正しい
`Cache-Control`ヘッダを返すサーバーの画像は既に再起動後もキャッシュ
される設計だった、との結論に至った — `URLCache.shared`(このアプリ自身
の`URLSession`用) を調整しても WKWebView 自身のネットワークスタックには
効かないため、そちら側の追加対応は行っていない。`Cache-Control: no-store`
を返す画像 (トラッキングピクセル等) はどのクライアント側キャッシュ戦略
でも救えないサーバー側の制約であり、対応範囲外とした。

計測は`scripts/verify-ios-b-html-render.sh`実行時の`xcodebuild test`ログ
上のタイムスタンプ (`docs/verify.md`参照) で確認 — 詳細な体感速度の
定量比較は今後の課題として残る。

### D: no-reply 系の通知メールが件名フォールバックで過剰にスレッド化
される

`Threader.decide(for:context:)`のステップ3 (件名フォールバック:
References が無いメッセージを、正規化件名+参加者重複+7日以内の window
で紐付ける) は、同一の`no-reply@`アドレスからの無関係な複数の日次通知
メール (それぞれ独立した内容だが同じ件名) を1つの巨大なスレッドへ束ねて
しまっていた — References/In-Reply-To が無い一方向のブロードキャスト
メールに対して「同じ件名」は会話の弱い証拠でしかない。

修正: `Threader.MessageFacts`に`fromAddress`を追加し、
`Threader.isNoReplyAddress(_:)`(`no-reply`/`noreply`/`donotreply`/
`do-not-reply`を含むアドレスを検出する簡易ヒューリスティック) が真の
とき、ステップ3の件名フォールバック自体を完全にスキップするようにした
— 「返信に一度でも関与しているか」を新しいシグナルとして`ExistingThread
Context`に通す案も検討したが、`ThreadAssigner`側の配線コストに対して、
今回観測された不具合 (no-reply の一方向配信) を直接解決できる送信者
アドレスだけのチェックの方が単純で確実と判断した。`ThreadAssigner
.assignThread`/`.assignAllUnthreaded`の両方の`MessageFacts`構築箇所を
更新し、`ThreaderTests`に回帰テストを追加。

### J: ハンバーガーメニューの「閉じる」ボタンをアイコン化

`FolderListSheet`の閉じるボタンをテキスト (`Button("閉じる")`) から
`xmark`アイコンのみ (`Label("閉じる", systemImage: "xmark")` +
`.labelStyle(.iconOnly)`) に変更した。`Label`は`.iconOnly`スタイルでも
VoiceOver 用のアクセシビリティラベルとして`title`引数 (="閉じる") を
保持し続けるため、見た目だけがアイコンに変わり読み上げは変わらない。
`.accessibilityIdentifier("folderSheet.closeButton")`は変更していない
ので既存 XCUITest への影響は無い。

### K: ハンバーガーメニューのアカウントセクションを折りたたみ可能に

`FolderListSheet`の各アカウントの`Section`ヘッダを、タップで開閉できる
`AccountSectionHeader`(自前実装、`DisclosureGroup`は使わず) に置き換え
た。折りたたみ状態は`FolderSectionCollapseStore`(`UserDefaults`、
アカウント ID の配列) に永続化し、既定は展開。折りたたみ中もそのアカウ
ントの全メールボックスの未読数合計をヘッダのバッジに表示する。
`DisclosureGroup`自体を使わなかった理由: この行を`Section`ヘッダとして
他の行 (メールボックス行) と同じスタイリング言語で描画する必要があり、
`DisclosureGroup`のヘッダ/コンテンツの見た目をこのアプリの既存の行
スタイルに完全に合わせ込むより、シェブロン回転 + `Section(header:)`の
手動実装の方が確実だった。

### 検証

`make test`/`make mac`/`make ios` green。`OtegamiWideMarketingHTMLUITests`
(B) を実機シミュレータで実行し、`XCTAttachment`(`.keepAlways`) で
xcresult バンドルへ埋め込んだスクリーンショットを目視確認 — ホスト側
シェルから`xcrun simctl io screenshot`をテストの`Thread.sleep`と競争
させる従来方式は、このテストがアカウント追加を含む可変長の前段を持つ
ため繰り返しタイミングを外し (ホーム画面やアカウント追加シートを捉える
だけに終わった)、`XCTAttachment`によるテストプロセス内蔵キャプチャに
切り替えて解決した。

## アバター強化バッチ フェーズ1: 連絡先の写真

`SenderAvatar` (旧: イニシャル+アカウント色のみ) を、優先順位付きの複数
情報源を持つ設計に拡張するバッチの記録。フェーズ1は最優先の情報源
「連絡先の写真」を実装した。フェーズ2 (Gravatar)/フェーズ3 (BIMI/企業
ロゴ favicon) は別バッチ (小出しリリース) で追加する。

### 設計: `AvatarImageResolving` + SwiftUI `EnvironmentValues`

`SenderAvatar`自体 (`DesignSystem/Components/SenderAvatar.swift`) は
`Contacts`/`URLSession`の類に一切依存しない — 実際の画像解決は
`AvatarImageResolving`プロトコル (`DesignSystem/AvatarImageResolving.swift`、
Foundation only) の背後に隠し、`@Environment(\.avatarImageResolver)`
経由で受け取る。具象型 (`ContactPhotoResolver`など) は
`apps/Otegami/Sources/Support/`側 (アプリ本体ターゲットのみ) に置く。

この分離により、`DesignSystemCatalog`(独立した SwiftPM 実行ターゲット、
`NSContactsUsageDescription`を持たない) は resolver を注入しないまま
`SenderAvatar`をそのまま安全に描画できる — 注入されなければ
`CNContactStore`に一切触れないため、使用目的文言の無いプロセスから
権限付きAPIを呼んでクラッシュする心配がない。`AppEnvironment
.avatarImageResolver`(`CompositeAvatarImageResolver`、複数情報源を優先
順に試す合成 resolver) が唯一のインスタンスを持ち、
`OtegamiApp.swift`の各`.environment(environment)`呼び出し箇所に
`.environment(\.avatarImageResolver, environment.avatarImageResolver)`を
併設してビュー階層へ配る。`ThreadRowView`/`MessageView`/
`ThreadDetailView`側の`SenderAvatar(...)`呼び出し自体は一切変更していない
(SwiftUI Environment が自動的に配られるため)。

### `ContactPhotoResolver`

`Contacts`framework (`CNContactStore`) をオンデバイスで使う actor。

- **権限**: 初回呼び出し時に一度だけ`authorizationStatus`を確認し、
  `.notDetermined`なら`requestAccess(for:)`で OS ダイアログを出す。
  `.limited`(iOS 18+ の一部連絡先のみ許可) も`.authorized`と同様に扱う —
  許可された範囲内だけを検索対象にするのは`CNContactStore`自身の仕事。
  拒否/未許可なら静かに`nil`を返すだけで、エラーも UI も一切出さない。
- **キャッシュ**: メールアドレス (小文字化、SHA-256 でファイル名化) を
  キーに、メモリ + ディスク (`Caches/AvatarCache/Contacts/`) の2段。
  「写真なし」という negative result もキャッシュし、無い連絡先を毎回
  問い合わせ直さない。`CNContactStoreDidChange`通知でメモリ・ディスク
  両方を丸ごと無効化する (差分無効化はコストに見合わないと判断)。
- **coalesce**: 同一アドレスへの同時呼び出しは`Task`を共有する — 一覧の
  高速スクロールで同じ差出人の行が複数同時に構築されても、
  `CNContactStore`への問い合わせは1回で済む。
- `CompositeAvatarImageResolver`(actor): 複数情報源を宣言順に試し、最初の
  非`nil`を返す合成 resolver。フェーズ1時点では`[ContactPhotoResolver()]`
  の1要素のみ。

### 設定

`AvatarSourceSettingsStore.showContactPhotoKey`(既定 ON)。設定 →「メール
一覧」の「送信者のプロフィールアイコンを表示」のすぐ下に「連絡先の写真を
表示」トグルを追加した。footer の説明文も、連絡先の写真を追加した時点で
もう正確ではなくなった旧文言 ("外部サービスへの問い合わせは一切行い
ません") から、実態 ("連絡先の照合はこの端末上だけで行われ、外部には
送信されません") に更新した。

### `NSContactsUsageDescription`

`project.yml`に追加 (`NSCameraUsageDescription`/`NSLocalNetworkUsageDescription`
と同じく、このプロジェクトには Info.plist キー専用の英語ローカライズ機構
が無いため日本語のみ)。

### 検証で見つかった verify script への影響

`ContactPhotoResolver`は初回呼び出しで権限が`.notDetermined`なら
`requestAccess`を呼ぶため、既存の`scripts/verify-ios-m*.sh`など
アカウント登録済みの一覧を自動検証する全スクリプトが、一覧の最初の行が
描画された瞬間に OS の連絡先アクセス許可ダイアログを踏みうる (`.claude/skills/verify/SKILL.md`が既に警告している「予期しないシステムダイアログが
次のタップを奪う」系の問題と同種)。`xcrun simctl erase`直後・アプリ起動
前に`xcrun simctl privacy "$UDID" grant contacts "$BUNDLE_ID"`で事前許可
することで OS ダイアログ自体が出ないようにし、既存の
`scripts/verify-ios-*.sh`全13本 (b-html-render/m1〜m9/account-edit/
credential-recovery/drafts-sync/icloud) に同じ1行を追加した。

新規に`scripts/verify-ios-avatar-phase1.sh`(+`OtegamiAvatarSettingsUITests`)
を追加し、設定画面に「連絡先の写真を表示」トグルが現れ操作できることを
確認した。**アカウント0件の初回起動直後だけ、ハンバーガー→設定の遷移が
`settingsSheet.navigationStack`のタイムアウトで失敗する**現象を発見 —
このプロジェクトの他の全テストは「少なくとも1回何か (アカウント追加等)
に成功した後で」ハンバーガーメニューを開いており、真に何もしていない
初回フレームでこの遷移を試すテストが実質的に無かったため、これまで
気付かれていなかった simulator/toolchain 固有の不安定さと見ている
(コード側の不具合ではない — アプリの通常起動フローでユーザーがこの
タイミングだけを狙って設定を開くことはまず無い)。数秒の猶予 + リトライ
で回避した。

**dev mailstack への実 IMAP 接続がこのセッション中に断続的に失敗する
既知の環境問題** (`docs/verify.md`「実機フィードバック第2弾 B」節に既に
記録済み — ホストプロセス/Safari からは`localhost:1143`に到達できるが
Otegami アプリのプロセスだけ`connectionFailed`になる、iOS 27 beta の
ローカルネットワーク権限まわりの未解決の環境劣化) に本バッチの検証中も
複数回遭遇した。Simulator/CoreSimulator の完全再起動を試しても再現した
ため、`docs/verify.md`の既存の記録どおり **この開発機のシミュレータ/OS
beta 環境側の問題であり、本バッチのコード変更が原因ではない**と判断し、
アカウント追加を伴う M1 等のフル検証は次回セッション (安定版シミュレータ
または環境復旧後) に持ち越した。フェーズ1の検証は上記の設定画面 UITest +
`make test`/`make mac`/`make ios` (いずれも green) の範囲に留めている。

### 次フェーズへの申し送り

- フェーズ2 (Gravatar)・フェーズ3 (BIMI/企業ロゴ favicon) を
  `CompositeAvatarImageResolver`の情報源リストに追加する。
- dev mailstack 接続断の環境問題が解消され次第、`scripts/verify-ios-m1.sh`
  等のフル回帰と、実際に連絡先に写真を登録した状態での目視確認
  (`CNContactStore`への書き込みを伴う専用 UITest、またはシミュレータの
  連絡先アプリへの手動登録) を行うこと。
