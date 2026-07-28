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
- **自動翻訳 vs ボタン開始**: 1l の「英文を自動で翻訳」設定
  (`TranslationSettingsStore`) が ON のときだけ `MessageView.load()` の
  末尾で自動的に翻訳を開始する。OFF のとき、または翻訳が失敗したときは
  バーに「翻訳」/「再試行」ボタンが出て、明示タップが起点になる。
  design-phase-3 時点ではオンデバイス翻訳のコスト (`docs/translation.md`
  実測で数秒〜) とのトレードオフとして既定 **ON** を選んでいたが、実機
  フィードバック (「翻訳機能は、勝手に実行しないで欲しい」) を受けて
  既定 **OFF** に変更した — `docs/translation.md`「実機フィードバック:
  「勝手に翻訳しないで」「HTML はレイアウトを保って」」節参照。バー自体
  の表示条件は変えていない (英文メールなら常に出る)。いつでも設定で
  ON に戻せる。
- **段落長押しで原文表示**: `TranslatedBodyView` は
  `MessageTranslationRecord.paragraphs` (原文/訳文ペアの配列) を
  1段落ずつ `Text` として描画し、`.onLongPressGesture` で
  その段落だけ `Set<Int>` の on/off を切り替える。訳文全体を原文に戻す
  操作はセグメントピッカー側 (バー) が担当し、段落単位の切り替えとは独
  立している。
- **HTML メールの扱い (ハンドオフに無い判断、design-phase-3 時点)**:
  翻訳エンジンは常にプレーンテキストの段落配列を返す
  (`docs/translation.md`)。当初は HTML 本文のメールで「訳文」を選ぶと
  `HTMLTextExtractor` で抽出したプレーンテキストを翻訳し
  `TranslatedBodyView` で表示していた — 訳文表示時はリンクや太字などの
  HTML 装飾を失うという制限を、翻訳 API がプレーン文字列しか扱わないこと
  を理由に受け入れていた。
  **実機フィードバック (「htmlメールの場合、レイアウトをなるべく崩さない
  ように翻訳を表示して欲しい」) を受けて撤回**: `HTMLTranslationController`
  が WKWebView の DOM テキストノードを直接収集・書き換える方式に変更し、
  HTML メールも表・画像・罫線などのレイアウトを保ったまま訳文を表示できる
  ようになった (`TranslatedBodyView`への総入れ替えはプレーンテキスト
  メールにのみ残る) — 詳細は `docs/translation.md`「実機フィードバック:
  「勝手に翻訳しないで」「HTML はレイアウトを保って」」節参照。
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
- **翻訳: 英文を自動で翻訳 (design-phase-3 時点の既定 ON、実機フィード
  バックを受けて後に既定 OFF へ変更 — `docs/translation.md`参照) / 一覧
  に要約を出す (既定 OFF)**:
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

### 4. 一覧ヘッダの再編: 検索の左下フローティング化・再読込ボタン廃止・
未読のみ表示トグル

ユーザー要望により、`MailScreenView`(一覧画面)のヘッダをさらに整理した
バッチの記録。iOS のみ (macOS の3ペインは無変更 — `MessageListView`は
両プラットフォーム共有ファイルだが、変更点はすべて`#if os(iOS)`側)。

- **検索ボタンを左下フローティングに移設**: ヘッダの虫眼鏡ボタン
  (`ToolbarItemGroup(.confirmationAction)`) を廃し、`FolderListSheet
  .floatingSettingsButton`と同じ「丸い面＋影、`overlay(alignment:
  .bottomLeading)`、スクロール内容とは`.contentMargins(.bottom:)`で
  重なりを避ける」流儀で一覧画面左下に常設した
  (`MailScreenView.floatingSearchButton`)。`accessibilityIdentifier`は
  旧実装の`mail.searchButton`のまま据え置いたため、
  `SearchUITestHelpers.openSearchScreen(in:)`を含む既存 UITest は無改修で
  動く。選択モード中 (`isSelecting`) は一括操作の邪魔にならないよう
  非表示にする。
- **再読込ボタンを iOS だけ廃止**: `MessageListView.refreshToolbarItem`
  はそのまま残し (macOS はまだ pull-to-refresh 相当が無いため)、
  `listToolbarContent`の`#if os(iOS)`側だけそれを呼ばなくした —
  pull-to-refresh (`.refreshable`) は変更していないので、iOS でも
  再同期の手段自体は失っていない。
- **「未読のみ表示」トグル**: ヘッダに新設したアイコントグル
  (`MailScreenView.unreadOnlyToggleButton`) — `AccountFilterChip`の
  選択状態 (`paleBaseStrong`塗り＋`accentText`文字色) と同じ配色ルールを
  再利用し、新しい色は追加していない。状態は`ListDisplaySettingsStore
  .unreadOnlyKey`の`@AppStorage`(既定 off、永続化)。`MailScreenView`
  (ヘッダ)と`MessageListView`(実際の絞り込み)が同じキーを別々の
  `@AppStorage`で参照する形にした — ヘッダの所有者と`ThreadQuery`呼び出し
  の組み立て場所が別ビューのため。
  - `ThreadQuery.request`/`unifiedInboxRequest`に`unreadOnly`引数を追加
    し、true のとき`thread.unreadCount > 0`をWHERE句に足す (集計列を
    見るだけでジョイン不要、ピン留めの`thread.isPinned`と同じ設計)。
    フラット表示 (`flatSummaries`/`unifiedInboxFlatSummaries`) には
    スレッド集計が無いため、代わりにメッセージ自身の`flagsRaw`の
    `\Seen`ビットで絞り込む (`MessageQuery.unreadCounts`と同じ判定式)。
  - アカウント絞り込み (1a のチップ) との合成もそのまま効く —
    `unifiedInboxRequest(accountIds:unreadOnly:)`は「渡された
    `accountIds`の範囲内で未読のみ」であって「全アカウント中の未読を
    集めてから見せる」ではない (`ThreadQueryTests
    .unifiedInboxRequestUnreadOnlyCombinesWithAccountFilter`で確認)。
  - 空状態: 未読のみ表示中に0件になったときは「未読のメールはありません」
    (`MessageListView.emptyStateTitle`) — 「メールが1通も無い」と
    「フィルタで絞った結果ゼロ件」を区別する、既存の同期エラー分岐と
    同じ考え方。`Localizable.xcstrings`に日英を追加した
    (`scripts/generate-localizable.py`の辞書にも同じ2エントリを追記—
    ただし既存ファイルには本バッチ以前から同スクリプトの辞書に無い
    エントリが3件 (画像表示関連、別バッチの作業分) 混在しており、
    それらを壊さないよう`Localizable.xcstrings`はスクリプト再生成
    せず手動で2エントリだけ追記した)。
  - 検索画面 (`SearchScreenView`/`SearchQuery`) はこのキーを一切参照
    しない — 「検索画面には影響させない」という要件どおり。
  - **実装時に踏んだ落とし穴: `ToolbarItemGroup`内のアイコンのみ
    `Button`は`.buttonStyle(.plain)`が無いと自前の塗り分けが効かない**
    (このシミュレータの iOS 26 系 Liquid Glass ツールバー描画で確認)。
    `unreadOnlyToggleButton`は当初`.buttonStyle`を指定していなかった —
    コンパイルは通り、コード上は`isUnreadOnly`で`.foregroundStyle`/
    `.background`を切り替えているのに、実機シミュレータのスクリーン
    ショットで見ると ON/OFF が常に同じ見た目 (システム標準のティント
    丸背景) になっていた。ツールバーのアイコンのみ`Button`はこの iOS
    バージョンで自動的に丸い "glass" 背景を被せるらしく、それが内側の
    `Label`の`.foregroundStyle`/`.background`を覆い隠していた —
    `floatingSearchButton`(ツールバー外の`overlay`ボタンで、最初から
    `.buttonStyle(.plain)`)は同じコードパターンで正しく描画できていた
    ことから切り分けた。`.buttonStyle(.plain)`を追加して解決 — 「見た目を
    確認したと報告する前に実際の画面を見る」(`CLAUDE.md`)を実践して
    初めて見つかった実例。今後ツールバー上に状態を色で示すアイコン
    ボタンを追加する際は同じ落とし穴に注意する。

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

## 画面構造改修バッチ: スレッド選択画面・圧縮ヘッダ・カテゴリ優先メニュー

ユーザー要望3点セット (iOS のみ — macOS の3ペインは無変更、`CLAUDE.md`の
1a 系スコープをそのまま踏襲) の記録。実装中に実機報告「スレッド表示を
オフにしてるのに、スレッドで表示されることがある」も同じ領域として対応
した (末尾の節)。

### 1. スレッド選択画面 (メール本文のエリアが狭い問題)

「スレッド表示にする場合、スレッドを選ぶ画面を別で挟んで、メール本文の
画面ではスレッドは出さない方がいい」という要望どおり、iOS の push 型
遷移 (`MailScreenView`/`SearchScreenView`) では **一覧 → (スレッドに
2通以上ある場合のみ) スレッド選択画面 → 単一メール本文画面** の3段構成
にした。承認済み仕様: スレッドが1通だけなら選択画面をスキップして直接
本文へ。

- **`ThreadEntryView`** (新設): これまで一覧/検索結果のタップ先だった
  `ThreadDetailView`の代わりに push される仲介ビュー。`preselectedMessageId`
  (フラット行/フラット検索結果が既に確定させている1通) が非`nil`なら
  即座に`ThreadDetailView(singleMessageId:)`を返す (選択画面もメッセージ
  数の問い合わせも一切しない)。`nil`なら`ThreadQuery.messages(threadId:
  db:)`で実際のメッセージ数を1回だけ読み、1通以下ならそのまま
  `ThreadDetailView`へ、2通以上なら`ThreadSelectionView`を表示して選ばせる。
- **`ThreadSelectionView`** (新設): 「スレッド選択画面の行は一覧と同等の
  情報 (アイコン・プレビュー・時刻)」の要件どおり、`ThreadMessageSummaryRow`
  (下記) の行をメッセージごとに並べる。タップで`.navigationDestination
  (item:)`により`ThreadDetailView(singleMessageId:)`へ push — 本文画面
  には常にその1通だけが表示され、以前のようなアコーディオン/スタックは
  出ない。
- **`ThreadMessageSummaryRow`** (`ThreadDetailView.swift`から分離・
  一般化): 元は`ThreadDetailView`のアコーディオン行専用の`private`型
  だったものを独立ファイルに切り出し、`Mode`(`.accordion(isExpanded:)`/
  `.list`) で挙動を切り替えられるようにした — `ThreadDetailView`自身の
  見た目は無変更 (`.accordion`モード側は既存ロジックをそのまま踏襲)、
  `ThreadSelectionView`はこの同じ型を`.list`モードで再利用する。
- **macOS は対象外**: `OtegamiApp.swift`の`detailColumn`は
  `ThreadDetailView`を直接インスタンス化したまま — 3ペインの広い画面には
  「本文のエリアが狭い」問題自体が無く、選択画面を挟むのはこのバッチが
  求めた以上のインタラクション変更になるため。

### 2. Spark 式の圧縮ヘッダ

`MessageView`の本文ヘッダを、Spark を参考にした約2行の圧縮レイアウトに
置き換えた (`MessageHeaderCompactView`、新設・別ファイル):

- 1行目: 差出人の表示名 (太字) + 時刻 (`OtegamiDateFormat.listRowText`、
  一覧の行と同じ短縮フォーマット)。HTML メールなら`HTMLBadge`も併記。
- 2行目: 「宛先: <先頭の宛先の表示名/アドレス> (他N名)」+ HTML⇄テキスト
  切替ボタン (アイコンのみに圧縮)。
- **件名はヘッダに出さない** (この画面に到達する前の一覧/スレッド選択
  画面、フッターツールバーの「情報」に既にある) — 旧ヘッダは件名
  (`.title2`)・From/To のフルアドレス・秒単位の日時をすべて表示しており、
  縦に厚いことが「本文のエリアが狭い」の一因だった。詳細情報は既存の
  「情報」シート (`MessageHeaderInfoView`) に委ねる (無変更)。
- **AI要約バー/翻訳バー (`AISummaryBar`/`TranslationBar`) は変更していない**
  — 検討はしたが、既存の実機 UITest
  (`OtegamiTranslationBarUITests.testOpeningEnglishMessageShowsTranslationBarButDoesNotAutoTranslate`)
  が「英文メールを開いた直後、タップ無しで翻訳バーの見出しが見える」ことを
  前提にしており、バーをボタン化して折りたたむとこの前提が崩れる。両方
  ともヘッダ本体には元から含まれておらず (ヘッダの下の独立した薄い1行
  バー)、アイドル時は既に「アイコン+見出し+ボタン」の1行に収まっている
  ため、「常設ヘッダから外し、コンパクトに」の要件は実質的に満たしている
  と判断し、既存の挙動・テストを壊すリスクを取らないことにした。

### 3. ハンバーガーメニューのカテゴリ優先グルーピング

`FolderListSheet`に、既存の「アカウントごとの選択」(account-first) に
加えて「role (受信トレイ/アーカイブ/送信済み/下書き/ゴミ箱等) ごとに
セクションを作り、その中に各アカウントを並べる」(category-first) を
実装し、既定を category-first にした。

- **`FolderGroupingMode`/`FolderGroupingModeStore`** (新設): `category`/
  `account`の2値、`@AppStorage`で永続化 (既定`category`)。
  `groupingModeSection`のセグメントコントロールで切替。
- **`MailboxRoleRecord`の拡張** (`MailboxRoleDisplay.swift`、新設・
  `Support/`): `categoryDisplayName`/`categorySystemImage`/
  `categoryOrder` (受信トレイ→フラグ付き→アーカイブ→送信済み→下書き→
  迷惑メール→ゴミ箱→すべてのメール、の固定順)。`.none`(ユーザー作成の
  独自フォルダ) は role で束ねられないため「その他」セクションに個別行
  のまま並べる (横断ビューは作らない)。
- **横断ビュー**: 各roleセクションの先頭に「すべての<ロール名>」行
  (`categoryUnifiedRow`) — 複数アカウントがそのroleを持つ場合のみ表示
  (1アカウントしか無ければ直後の個別行と内容が完全に重複するため、
  `showsAccountAccent`と同じ判断)。新設の`SidebarSelection.unifiedRole
  (MailboxRoleRecord)`を選択する。
    - `ThreadQuery.unifiedInboxRequest`/`unifiedInboxSummariesObservation`/
      `unifiedInboxFlatSummaries`/`unifiedInboxFlatSummariesObservation`、
      `MessageQuery.unifiedInboxUnreadCount(Observation)`に`role:
      MailboxRoleRecord = .inbox`パラメータを追加 (既定値により既存呼び
      出し元は無変更) — 「すべての受信トレイ」専用だったクエリを任意の
      role に一般化した。
    - `MessageListView`の`selection`に対する`switch`6箇所すべてに
      `.unifiedRole`ケースを追加 (`observeThreads`/`title`/
      `showsAccountAccent`/`currentAccountLastSyncError`/
      `availableScopes`/`refresh()`)。`refresh()`は role 専用の同期
      スコープが`SyncCoordinator`に無いため`.all`(全メールボックスの
      フル差分同期) にフォールバックする。
    - 既存の折りたたみ状態 (`FolderSectionCollapseStore`、アカウント
      優先モード用) は変更せず、category-first 用に独立した
      `FolderCategoryCollapseStore`を新設した — 表示単位そのものが違う
      2つのモードに同じ折りたたみ状態を使い回す理由が無いため。
    - `FolderMailboxRow`に`accountLabelText`(既定`nil`)を追加 — category
      優先モードでは1セクションに複数アカウントの行が混ざるため、
      アカウント優先モードのようにSection見出し自体がアカウント名を兼ね
      られない。フォルダ名の下に小さく併記する。

### 4. Task #52: ハンバーガーメニューの改善3点 (Spark 参考)

上の3節で作った「カテゴリ優先/アカウント優先のセグメント切替」を
廃止し、Spark のメニューと同じ構成に作り直した。あわせて、カテゴリ配下
の行の見た目、Gmail の「アーカイブ」マッピング、カテゴリの並び替えの
3点を実装した。

- **セグメント切替の廃止 → 縦積み構成**: `FolderGroupingMode`/
  `FolderGroupingModeStore`/`groupingModeSection`(セグメントコント
  ロール) を削除し、`FolderListSheet.body`は常に「カテゴリ群 (受信
  トレイ/アーカイブ/送信済み/…) → その他 (独自フォルダ) → アカウント群
  (アカウント名ごとのメールボックスツリー、旧アカウント優先表示そのもの)」
  を1つの`List`に縦に並べる。両方の折りたたみ状態
  (`FolderSectionCollapseStore`/`FolderCategoryCollapseStore`) は
  従来どおり独立したまま維持 — セグメント切替時代からの永続キーを
  変えていないので、既存インストールでの折りたたみ選択も引き継がれる。
- **1. カテゴリ配下の行をアカウント名表示に**: 新設の`CategoryAccountRow`
  (`FolderListSheet.swift`) が、role で分類できるカテゴリセクション
  (受信トレイ/アーカイブ/送信済み等) 内の各アカウント行を
  `AccountColorRail`(1d の3pxアカウント色罫線、`ThreadRowView`の1覧行と
  同じ組み方) + アカウントの表示名で描画する — Spark のスクリーンショット
  と同じ「色バー+アカウント名」。表示名は`Text(verbatim:)`で素通しする
  (`AccountFilterChip.label`のdoc comment参照: `LocalizedStringKey`
  経由だと、表示名がメールアドレスそのもの (未設定時のフォールバック)
  の場合に自動リンク化して`mailto:`が開く実機バグを踏む)。role で分類
  **できない**「その他」セクション (`uncategorizedSection`) は逆に
  フォルダ名こそが差分なので、従来どおり`categoryMailboxRow`/
  `FolderMailboxRow`(フォルダ名主表示+アカウント名併記) のまま — 使い
  分けの理由は`categoryAccountRow(for:)`のdoc comment参照。
- **2. Gmail の「アーカイブ」マッピングと定義**: Gmail は`\Archive`
  special-useフォルダを持たず、All Mail (role`.all`) が実質のアーカイブ。
  「重複表示 (アーカイブと「すべてのメール」の2箇所に出る) をどうする
  か」は Spark と同じ「アーカイブに一本化」を採用 —
  `MailboxRoleRecord.categoryOrder`(`Support/MailboxRoleDisplay.swift`)
  から`.all`を除外し、`FolderListSheet.matchesCategory(mailbox:account:
  role:)`が「role が一致」または「role`.archive`を問い合わせていて、かつ
  そのメールボックスが Gmail アカウントの`.all`」の場合にアーカイブ
  カテゴリの一員として扱う。これはメニュー表示側 (どのメールボックスを
  「アーカイブ」行として出すか) のマッピングで、`OtegamiStore
  .MailboxRoleRecord.gmailArchiveQueryRole`(`ThreadQuery`/`MessageQuery`
  の unifiedInbox* 系が`role`引数を Gmail アカウントの実際の SQL 条件へ
  変換するのに使う、`.archive`→`.all`) と対になる。
  - **「アーカイブ」の中身の定義** (ユーザー指定、Gmail 検索式と等価):
    `-in:spam -in:trash -is:sent -in:drafts -in:inbox` — 単純に All Mail
    全件ではない。Gmail の IMAP モデルでは同じ物理メッセージが複数の
    ラベル (=mailbox) に重複して現れるため、All Mail に無条件で「アーカ
    イブ済み」のラベルを付けると、まだ受信トレイにあるメール・自分の
    送信コピー・下書きの写しまで「アーカイブ済み」として出てしまう。
    スパム/ゴミ箱はそもそも Gmail の All Mail に含まれないため、除外
    条件は INBOX/Sent/Drafts の3つで足りる。
    `OtegamiStore.GmailArchiveFilter`(`Records/MailboxRecord.swift`)
    がこの定義を1つの SQL WHERE 断片として実装し、`ThreadQuery
    .request(mailboxId:)`/`.flatSummaries(mailboxId:)`/`unifiedInboxRequest`
    /`unifiedInboxFlatSummaries`、`MessageQuery.unreadCounts(accountId:)`/
    `unifiedInboxUnreadCount`の全箇所で共有する。「同一メッセージ」の
    判定は同一アカウント内の`X-GM-MSGID`(`MessageRecord.gmailMessageId`)
    突き合わせ — RFC 822`Message-ID`ヘッダは欠落/複製されうる一方、
    `X-GM-MSGID`は Gmail が発行するアカウント内一意な内部識別子で確実。
    v27マイグレーションで`message.gmailMessageId`にインデックスを追加
    した (自己結合の相手方テーブル探索用)。
  - **設計判断: Gmail の All Mail を開く経路をすべて統一した**。
    `ThreadQuery.request(mailboxId:)`/`flatSummaries(mailboxId:)`は
    「渡された`mailboxId`が Gmail アカウントの All Mail かどうか」を
    SQL側で判定し、該当すればどの導線 (カテゴリ優先メニューの「アーカ
    イブ」行、アカウント優先メニュー/アカウント群の素のフォルダツリー
    にある「All Mail」行、検索) から開いても同じ「アーカイブ済み」定義
    を適用する — 一度「All Mail はアーカイブである」と決めた以上、経路
    によって「文字通りの全件 (受信トレイの写しも混ざる)」と「アーカイブ
    済みのみ」が食い違うのはユーザーにとって驚きが大きいと判断した。
    副作用として、アカウント優先モードの素のフォルダツリーで「All Mail」
    を直接タップした場合も同じフィルタがかかる (「文字通りの全件」を見る
    手段は今のところ無い) — 将来そのニーズが出た場合の拡張ポイントとして
    記録しておく。
  - テスト: `GmailArchiveFilterTests`(`Tests/OtegamiStoreTests/`) が
    「INBOX にもある All Mail メッセージはアーカイブに出ない」「アーカイブ
    済み (All Mail のみ) は出る」「送信コピーは出ない」「下書きは出ない」
    「非 Gmail アカウントの`.archive`メールボックスは影響を受けない
    (回帰確認)」を、`ThreadQuery`/`MessageQuery`双方でカバーする。
- **3. カテゴリの並び替え**: `FolderCategoryOrderStore`
  (`Support/FolderCategoryOrderStore.swift`) が`MessageToolbarSettingsStore`
  と同じ「role の`rawValue`をカンマ区切りで1つの`UserDefaults`文字列
  キーに書く」流儀でカテゴリの並び順を永続化する。設定 → メール一覧 →
  「カテゴリの並び替え」(`FolderCategoryOrderSettingsView`、
  `MessageToolbarSettingsView`と同じ「常時編集モードの`List`+`.onMove`」
  構成) から並び替えられる。`FolderListSheet`は`@AppStorage
  (FolderCategoryOrderStore.key)`で生の文字列を直接監視し、そのつど
  `FolderCategoryOrderStore.loadOrder(from:)`で`[MailboxRoleRecord]`へ
  変換する (`loadOrder()`という無引数版もあるが、こちらは`FolderListSheet`
  が常設マウントのドロワーで再生成されないビューであるため、設定画面
  での変更を反応的に拾うのに使えない — `@AppStorage`のプロパティラッパー
  経由でないと変更が伝播しない)。「その他」(独自フォルダ、role`.none`)
  は並び替え対象に含めない — 常にメニュー最後に固定表示。

**検証**: `OtegamiTask52HamburgerMenuUITests`が実機シミュレータで
`OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT`(`AppEnvironment.swift`、この
バッチで拡張 — INBOX/All Mail/Sent Mail と「アーカイブ済み」/「まだ受信
トレイにある (未アーカイブ)」の2スレッドを注入するようになった) を使い、
(a) カテゴリ群+アカウント群が同時に見える・アーカイブ配下の行がアカウント
名表示・Gmail の行がアーカイブ配下に居る・タップすると「アーカイブ済み」
の1通だけが見える (未アーカイブの写しが出ない)、(b) 並び替え設定の
ドラッグがメニューの並びに反映される、の両方をスクリーンショット付きで
確認した。実機シミュレータで判明した検証上の注意点 (このプロジェクト
固有の環境依存の話で、アプリのコードとは無関係):

- フェイクメッセージの送信者アドレス (`qa@example.com`) をアバター解決が
  連絡先と突き合わせようとして、初回起動時に「連絡先へのアクセスを
  許可しますか」という実システムダイアログが出ることがある。
  `Thread.sleep`でスクリーンショット用に画面を保持している間にこれが
  前面に出ると、座標ベースのタップ/ドラッグがそのシステムシートに
  当たってしまい本来の要素に届かない (`xcodebuild test`のログは
  「Synthesize event」が成功したと報告するが、実際にはアプリの状態が
  一切変わらない、という分かりにくい失敗になる) — 検証前に`xcrun simctl
  privacy grant contacts <bundle-id>`で事前許可しておくのに加え、
  テスト側も「要素を解決したら即アクション、間に`Thread.sleep`を挟まない」
  を徹底した。
- `-only-testing:`を複数指定して1回の`xcodebuild test`にまとめると、
  XCTest はテストメソッドをコマンドラインの指定順ではなくアルファベット順
  で実行する — フェーズ間で状態を引き継ぐ意図の2つのテスト
  (`testCategoryReorderInSettings`→`testCategoryReorderAppliesTo
  HamburgerMenu`) を1回の呼び出しにまとめたところ、"Applies" が
  "InSettings" より先に実行されて意図した順序と逆になった
  (`OtegamiAccountReorderUITests`が最初から「フェーズごとに別の
  `xcodebuild test`呼び出し」にしているのはこのため)。同じ理由で、この
  バッチの並び替えテストも2回の別々の`xcodebuild test`呼び出しに分けた。

### 実機報告「スレッド表示をオフにしてるのに、スレッドで表示されることが
ある」の調査と修正

上記の改修中に追加で報告された実機バグ。`ThreadQuery.request`/
`unifiedInboxRequest`(グループ化) と`flatSummaries`/
`unifiedInboxFlatSummaries`(フラット) の使い分けを全呼び出し箇所
(統合受信トレイ/単一メールボックス/検索結果/未読のみトグル/アカウント
絞り込みチップ) で点検した結果:

- **`MessageListView.observeThreads()`自体は既に正しい**: 単一メール
  ボックス・統合受信トレイ (今回追加した`.unifiedRole`含む) はすべて
  `isFlatMode`で正しく分岐しており、`unreadOnly`/アカウント絞り込みとの
  組み合わせも`ObservationKey`に両方の値が含まれるため設定変更のたびに
  観測が再構築される。ここに漏れは無かった。
- **本当の漏れは検索だった**: `SearchQuery.threadSummaries`(macOS の
  `MessageListView`インライン検索、iOS の`SearchScreenView`が共通で使う)
  は`isFlatMode`を一切見ず、常にスレッドをグループ化して返していた —
  実は`ThreadDetailView`の doc comment 上は「search always shows grouped
  threads」として以前から**意図的な**スコープ外と記録されていた
  (「実機フィードバック第3弾: フラット表示の単一メッセージ化」節、
  検索結果は小さく一時的なリストなので影響は薄いという判断)。今回、
  実際にユーザーがこれを踏んだと判断し、その判断を撤回して修正した。
  - **`SearchQuery.flatMessageSummaries`** (新設): `threadSummaries`と
    同じ演算子/FTS/LIKE マッチングロジックを再利用し、マッチした
    メッセージ ID 集合をスレッドへ集約する代わりに`ThreadSummary
    (flatMessage:accountId:)`でメッセージ単位の行として返す —
    `ThreadQuery.flatSummaries`が`request`に対して持つのと同じ関係。
  - `MessageListView.performSearch`(macOS インライン検索) /
    `SearchScreenView.performSearch`(iOS) の両方を`isFlatMode`/
    `!isThreadingEnabled`で分岐するよう修正。設定を検索中に切り替えた
    場合に備え、`.onChange(of: isThreadingEnabled) { scheduleSearch() }`
    も追加した (今までは`searchText`/`searchScope`の変化でしか再検索
    しなかった)。
  - `SearchScreenView`に`selectedMessageId`状態を新設し、フラット検索
    結果の行 (`summary.singleMessageId`が非`nil`) をタップした際に
    `ThreadEntryView.preselectedMessageId`へ伝播するようにした —
    これが無いと、フラットな検索結果をタップしても`ThreadEntryView`が
    グループ化モードと誤認し、実際のスレッドのメッセージ数を数え直して
    選択画面 (またはグループ化された本文) を出してしまい、今回の報告と
    全く同じ症状を検索経路で再現してしまうところだった。
- **このバッチ自身が持ち込みかけていた回帰**: 「1. スレッド選択画面」の
  実装で、グループ化モードの複数メッセージスレッドも
  `ThreadSelectionView`経由で1通だけを表示するようになった結果、
  `ThreadDetailView`が元々「`singleMessageId != nil` ⇒ フラット行」と
  推定していた前提 (「実機フィードバック第3弾: A」節) が崩れていた —
  グループ化モードでも`singleMessageId`が非`nil`になるケースが新たに
  生まれたため。放置すると「削除/アーカイブ後に次のメールを開く」設定
  (`MessagePostActionSettingsStore`) が、選択画面経由で開いたグループ化
  スレッドに対して常に無効化される (`ThreadDetailView
  .notifyThreadRemoved()`が常に`dismiss()`一択になる) 回帰になるところ
  だった。`ThreadDetailView`に`isFlatModeEntry: Bool`(既定`true`— 未修正
  の呼び出し元の暗黙の前提をそのまま保つ) を新設し、`singleMessageId`は
  「どのメッセージを表示するか」だけの意味に戻した。`ThreadEntryView`は
  `preselectedMessageId`が非`nil`のときだけ`isFlatModeEntry: true`を渡し、
  自身がメッセージ数を見て解決したケース (1通スキップ/選択画面経由の
  どちらも) では`false`のまま — 「次のメールを開く」はグループ化モードの
  スレッドである限り、選択画面を経由したかどうかに関わらず引き続き効く。
  macOS の`detailColumn`(`OtegamiApp.swift`) は唯一の直接
  `ThreadDetailView`インスタンス化経路なので、以前と同じ判断
  (`selectedMessageId != nil`) を明示的に`isFlatModeEntry`へ渡すよう更新
  した。
- **回帰テスト**: `SearchQueryTests`に`flatMessageSummaries`のテストを
  追加 — 同じスレッドに属する2通のメッセージが両方マッチするクエリで、
  グループ化検索 (`threadSummaries`) は1行、フラット検索
  (`flatMessageSummaries`) は2行 (`singleMessageId`がそれぞれ異なる)
  になることを確認する、今回の報告に直接対応する回帰テスト。

### 検証

`make test`/`make ios`/`make mac` すべて green (`SearchQueryTests`の新規
2件を含む)。実機シミュレータでの目視確認 (スクリーンショット) は
`.claude/skills/verify/SKILL.md`の手順に沿って実施し、結果を別途記録する
— このドキュメント更新の時点でまだ実施中/未完了の場合は、対応する
コミットメッセージまたは最終報告を参照。

既存 UITest への影響: `OtegamiM4ThreadDetailUITests`(旧「スレッドを開くと
全メッセージがアコーディオン」を検証していたテスト) はこのバッチの
意図した挙動変更そのものを検証する内容へ全面的に書き換えた。
`OtegamiDisplayBatchScreenshotUITests`/`OtegamiFeedbackBatch2ScreenshotUITests`/
`OtegamiColdLaunchAndSidebarSelectionUITests`/`OtegamiQASweepUITests`/
`OtegamiQASweepOfflineUITests`の一部テストは、「どのスレッドが最初に
ソートされるか」に依存する既存の (意図的な) 非決定性により、2+メッセージ
のスレッドを開くと新設の選択画面を経由するようになった影響を受けた —
新設の共有ヘルパー`waitForThreadDetailPossiblyThroughSelectionScreen(in:)`
(`DovecotAccountUITestHelpers.swift`) が選択画面を透過的に1段タップして
本文画面まで進める形で対応した。`OtegamiQASweepScenario2UITests`/
`OtegamiM4SetupUITests`は既知の単一メッセージ固定フィクスチャのみを対象
にしており無改修。

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

**追加の実機フィードバック (fit-to-width, Bの後日談)**: 上記の CSS
リセットだけでは、楽天銀行のような幅600-800px級の固定幅テーブル
HTMLメールで右端がクリップ・文字が巨大に見える不具合が残っていた —
`max-width: 100% !important`は各要素の*ボックス*の幅は正しく制約する
が、`white-space: nowrap`が指定されたセル (幅寄せ用の隣接ラベル/値行
など、固定幅前提のテンプレートで頻出) の**描画内容**がそのボックスから
はみ出すケースまでは防げない (`overflow-x: hidden`で見えなくなるだけで
縮小はされない)。Spark 等の参考実装と同じ "fit-to-width" — 実際に必要な
幅 (`scrollWidth`) を計測し、ビューポート幅を超えていれば `transform:
scale()` でページ全体を視覚的に縮小する — で解決した
(`HTMLWebViewCoordinator.fitToWidthScript`/`applyFitToWidth(to:)`、
`WKNavigationDelegate.didFinish`後に評価)。ページ自身のスクリプトは
`allowsContentJavaScript = false`で無効化済みだが、ホスト側 (Swift)
からの`evaluateJavaScript`呼び出しはこの制限と独立に動作する。
`HTMLDocumentBuilder.wrap(bodyHTML:)`が本文を`#otegami-fit-outer`/
`#otegami-fit-inner`の入れ子`div`で包むのはこのための足場 — 詳細は
同関数のドキュメントコメント参照。検証用に
`dev/mailstack/seed/fixtures/29-fixed-width-bank-notice.eml`(日本語、
実機報告と同じ幅700px級の構造) /`30-fixed-width-notice-en.eml`(英語版、
1i の HTML レイアウト保持翻訳の検証にも使う) を新設し、
`OtegamiFitToWidthUITests`で確認した。

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

**フォローアップ: 起動/フォアグラウンド復帰時の本文バックグラウンド
プリフェッチ**: 上記の調査時点では「既読メールでもネットワークを叩いて
いる」という仮説はコード上成立しなかった (`bodyState == .fetched`なら
ローカル DB から即座に読む) — が、これは*一度でも本文を取得したことが
ある*メッセージに限った話で、一覧の上の方に見えていても実際に開いた
ことが一度も無いメッセージ (`bodyState == .notFetched`) は依然として
初回オープン時に本文取得のネットワーク往復を待つ。`SyncCoordinator
.prefetchUnifiedInboxBodiesIfNeeded(accounts:now:authProvider:)`
(`packages/OtegamiKit/Sources/SyncEngine/SyncCoordinator.swift`) が
これに対応: アプリの起動完了後・フォアグラウンド復帰のたびに、低優先度
の`Task`で統合受信トレイの直近30件 (`unifiedInboxPrefetchLimit`) の
`bodyState == .notFetched`なメッセージをバックグラウンドで先読みする。
アカウントごとに逐次処理 (並列接続はしない)、5分デバウンス
(`unifiedInboxPrefetchInterval`)、オフライン/認証エラー/個別メッセージ
の取得失敗はすべて静かに諦める (エラーバナーを出さず、次回の復帰時に
再試行) — ユーザー操作 (開封時の本文取得) を妨げないことを優先した設計。
`BodyFetcher`側にも同一メッセージへの重複フェッチ防止 (`Task`ベースの
in-flight 管理) を追加し、このプリフェッチと開封時の遅延取得が同じ
メッセージを取り合っても二重にネットワークへ取得しに行かないようにした。
`packages/OtegamiKit/Tests/SyncEngineTests/UnifiedInboxPrefetchTests.swift`
で`FakeIMAPSession`を使い、対象メッセージの選定・デバウンス・エラー
時の無言スキップを検証済み。実機での2台間の体感速度比較は未検証
(`PENDING.md`)。

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

## アバター強化バッチ フェーズ2: Gravatar

フェーズ1の`ContactPhotoResolver`に続く第2優先の情報源。連絡先の写真が
見つからなかった差出人について、Gravatar (gravatar.com) に登録された
画像を試す。

### `GravatarAvatarResolver`

`AvatarImageResolving`に準拠する actor
(`apps/Otegami/Sources/Support/GravatarAvatarResolver.swift`)。

- **ハッシュ化**: アドレスを trim + 小文字化してから SHA-256 でハッシュ化
  し、`https://gravatar.com/avatar/<hash>?d=404&s=160`を`URLSession`で
  取得する。`d=404`は「登録が無ければ (デフォルトのシルエット画像ではなく)
  404 を返す」という Gravatar 側のオプション — これが無いと、Gravatar
  アカウントを持たない差出人全員に同じデフォルト画像が表示されてしまい、
  「差出人ごとに区別できる」というアバター機能の目的に反する。
- **フェッチ結果の3分類**: 200 (`.found`)/404 (`.notFound`)/それ以外・
  ネットワークエラー・タイムアウト (`.unavailable`) を区別する。
  `.notFound`だけを negative cache に書く — `.unavailable`は「無いことが
  確定した」わけではないので、キャッシュに書かず次回また試す (指示の
  「negative cache (無かった事実) も保持」を文字通り「事実が確定した
  ときだけ」と解釈した)。
- **キャッシュ**: `ContactPhotoResolver`と同じくメモリ+ディスク
  (`Caches/AvatarCache/Gravatar/`、ファイル名は`AvatarCacheKey.sha256Hex`
  で共通化) の2段。ディスクファイルの mtime を「キャッシュされた時刻」
  として使い (専用の JSON インデックスを持たずに済む)、TTL 7日を超えたら
  再取得する — found/not-found のどちら側にも同じ TTL を適用する
  (ユーザーが後から Gravatar に写真を設定/削除する可能性はどちら向きにも
  あるため)。
- **coalesce**: `ContactPhotoResolver`と同じ`Task`共有パターン。
- 一覧のスクロールはブロックしない — `SenderAvatar`の`.task(id: address)`
  が非同期に解決し、結果が届くまでイニシャルのまま表示され続ける
  (フェーズ1で確立済みの設計をそのまま踏襲)。

### 設定

`AvatarSourceSettingsStore.showGravatarKey`(既定 ON)。設定 →「メール
一覧」の「連絡先の写真を表示」のすぐ下に「Gravatar の画像を表示」トグルを
追加した。footer に「差出人アドレスのハッシュが gravatar.com に送信され
ます。設定でオフにできます。」という独立した段落を追加した (連絡先の
注記とは別の段落 — 一方はオンデバイス、他方は外部通信という性質の違いを
明確にするため)。

### 検証

`make test`/`make mac`/`make ios` green。`OtegamiAvatarSettingsUITests`
(フェーズ1で追加、フェーズ2でアサーションを拡張) を実行し、「Gravatar
の画像を表示」トグルが既定 ON で表示され、操作できることを確認した
(`scripts/verify-ios-avatar-phase1.sh`)。

実際に gravatar.com への実通信 (SHA-256 ハッシュを使った本番と同じ
クエリ形) が成功することは、Python の`urllib`でホストから直接確認した:
存在しないアドレスに対して`404`が正しく返る (negative cache 経路)。
実在の Gravatar 登録者の写真が実際に一覧に描画されるところまでの目視
確認は、検証に使える適切なテスト用アドレス (第三者の実アドレスを勝手に
使わない) が無かったため見送った — コードパス自体 (200 応答のデコード・
表示) は標準的な`URLSession`+`UIImage(data:)`/`NSImage(data:)`の組み合わせ
で、フェーズ1の連絡先写真表示 (同じ`SenderAvatar.platformImage`経路) で
実機動作を確認済みのものと完全に同じ描画経路のため、リスクは低いと判断
している。

設定画面のスクリーンショット取得は、フェーズ1で成功した「テスト実行中に
ホストからスクリーンショットを撮る」方式 (M6 節参照) が、このバッチの
検証セッション中は`xcodebuild`のビルド時間の揺らぎにより毎回ホーム画面
しか捉えられなかった (`docs/verify.md`の「dev mailstack 接続断」と同種の、
この開発機のシミュレータ/toolchain 側の不安定要因と見ている — 手動での
`xcrun simctl launch` + `screenshot`では同じ`$UDID`に対して問題無く撮影
できることを確認済みで、アプリ自体や XCUITest のアサーションは全て
green だったため、コード側の不具合ではないと判断した)。次回セッションで
再試行すること。

### 次フェーズへの申し送り

- フェーズ3 (BIMI/企業ロゴ favicon) を`CompositeAvatarImageResolver`へ
  追加する。
- 設定画面のスクリーンショット取得タイミング問題の再調査 (上記参照)。

## アバター強化バッチ フェーズ3: 企業ロゴ (favicon) — BIMI は実装見送り

**[Task #42 で判断を覆した]** 以下の節は当時の判断の記録として残すが、
BIMI は Task #42 で実装済み — 詳細は本ファイル末尾の「Task #42: BIMI
対応・自分のプロフィール写真・アバター診断」節を参照。

フェーズ1 (連絡先)・フェーズ2 (Gravatar) に続く第3優先の情報源。

### BIMI を実装しなかった判断とその理由

指示は「BIMI (DNS TXT `default._bimi.<domain>` から SVG ロゴ URL を取得)
を優先し、実装コストが見合わなければ favicon のみにして判断を報告する」
というものだった。BIMI 自体を見送り、favicon のみを実装した。理由は
`CompanyLogoAvatarResolver.swift`のドキュメントコメントに詳しく記録した
が、要点:

1. **システムリゾルバでの DNS TXT レコード取得に、Apple プラットフォーム
   上の手頃な高レベル API が無い**。`URLSession`は HTTP(S) 専用、
   `Network`framework の`NWConnection`も DNS レコード種別を選べない。
   唯一の正しい選択肢は`dnssd`framework の`DNSServiceQueryRecord`(C
   コールバック API) だが、Swift concurrency へのブリッジ・タイムアウト・
   `DNSServiceRef`のメモリ管理を新規実装する必要があり、指示が明示的に
   許容している「実装コストに見合わなければ見送る」の対象と判断した。
   指示自身が名指しで注意している、サードパーティ DoH (`dns.google`等)
   経由の実装は、プライバシー方針 (第三者への問い合わせを増やさない) 上
   採用しなかった。
2. SVG の安全なラスタライズ (`WKWebView`を使わない、サイズ制限+単純な
   SVG のみ) も別途実装が要る要素で、1と合わせて実装コストが他フェーズ
   に対して不釣り合いに大きいと判断した。

### `CompanyLogoAvatarResolver`

`AvatarImageResolving`に準拠する actor
(`apps/Otegami/Sources/Support/CompanyLogoAvatarResolver.swift`)。

- **favicon フォールバック**: `https://<domain>/apple-touch-icon.png`→
  失敗すれば`https://<domain>/favicon.ico`の順に試す。取得したバイト列は
  `UIImage(data:)`/`NSImage(data:)`でデコードできることを確認してから
  「見つかった」と確定する — `favicon.ico`が真のマルチ解像度 ICO 形式
  (`UIImage`/`NSImage`がデコードできないことがある) で配信される場合が
  あるため、デコード不能なバイト列を negative cache に汚さないための
  ガード。
- **フリーメールドメインの除外**: `OtegamiCore.FreeMailDomains`(新規、
  pure logic・依存無しなので`OtegamiCoreTests`で単体テスト可能) が
  gmail.com/icloud.com/yahoo.co.jp 等の主要フリーメールプロバイダの
  ドメインを保持する。差出人ドメインがこのリストに含まれる場合は
  ネットワークにすら問い合わせず即座に`nil`を返す — 「Gmail ユーザー
  全員に Google のロゴが付いてしまう」という誤りを防ぐ、指示の要件どおり。
  網羅的なリストではなく、主要な国際/日本語圏プロバイダを中心に収録した
  (新しいプロバイダは気付いたら追記していく運用)。
- **キャッシュキーはドメイン単位** — `ContactPhotoResolver`/
  `GravatarAvatarResolver`がメールアドレス単位でキャッシュするのとの
  明確な違い。同じ会社の複数の差出人 (`alice@acme.com`/`bob@acme.com`)
  が同じ favicon 取得結果を共有できる。TTL 30日 (Gravatar の7日より長め
  — favicon は個人の写真よりずっと変更頻度が低いと考えられるため)。
- coalesce・非同期・メモリ+ディスクの2段キャッシュ (`Caches/AvatarCache/
  CompanyLogo/`) は他の2つの resolver と同じ設計。

### 設定

`AvatarSourceSettingsStore.showCompanyLogoKey`(既定 ON)。設定 →「メール
一覧」に「企業ロゴを表示」トグルを追加し、footer に「ドメイン名が接続先
サーバーに送信されます」という3段落目の注記を追加した。

### 検証

`make test`/`make mac`/`make ios` green。新規`FreeMailDomainsTests`
(gmail.com 等が正しく除外される・大文字小文字を区別しない・
`apple.com`/`otegami.test`のような実在/開発用ドメインは対象のままである
ことを確認) を含め全テスト green。

実際の favicon 取得がネットワーク越しに成功することを Python の
`urllib`でホストから直接確認した: `apple.com`/`github.com`の
`apple-touch-icon.png`/`favicon.ico`がいずれも実際に 200 + 画像バイト列
を返すこと、dev mailstack のフィクスチャドメイン`otegami.test`(実在しない
テスト用ドメイン) は DNS 解決エラーになり、これは`CompanyLogoAvatarResolver`
の`fetchFavicon`が`try?`で捕捉して`nil`を返す (=イニシャルへフォール
バック) 経路と一致することを確認した。

`OtegamiAvatarSettingsUITests`に「企業ロゴを表示」トグルのアサーション
(既定 ON・存在確認・タップ後もクラッシュしないこと) を追加し、
`scripts/verify-ios-avatar-phase1.sh`実行で3トグルとも green。この
バッチの検証セッションを通じて、設定画面を「テスト実行中にホストから
スクリーンショットを撮る」方式で捉えることには最後まで成功しなかった
(スクリーンショット機構自体は`xrun simctl launch`+`screenshot`の手動
実行では同じ`$UDID`に対して確実に動作することを確認済みで、XCUITest の
アサーション自体は全て green だったため、アプリのコード側の不具合では
なく、この開発機のシミュレータ/toolchain 側のスクリーンショット
タイミング/フォーカス関連の不具合と判断している) — フェーズ1で取得
できた画面 (連絡先の写真トグルのみ表示) を、Gravatar・企業ロゴのトグルが
同じ見た目のスタイルでその下に並ぶことの視覚的な裏付けとして扱った。

### 次フェーズへの申し送り

- BIMI の実装 (`DNSServiceQueryRecord`によるシステムリゾルバ経由の DNS
  TXT 取得 + 安全な SVG ラスタライズ) を、将来必要になった場合の課題として
  残す。
- 設定画面のスクリーンショット取得タイミング問題の再調査 (フェーズ2から
  持ち越し、今回も再現)。
- 実際に BIMI/favicon を持つ企業ドメインからのメールを dev mailstack の
  フィクスチャに追加し (実在ドメインの From ヘッダを持つメール)、企業ロゴ
  が一覧に実際に描画されるところまでの実機目視確認を行うこと — 今回は
  ネットワーク到達性の確認 (ホストからの直接検証) に留めた。

## アバター強化バッチ「Google プロフィール写真」

フェーズ1 (連絡先)・フェーズ2 (Gravatar)・フェーズ3 (企業ロゴ) に続く
第4の情報源だが、優先順位上はフェーズ2の**前** (連絡先の写真の直後) —
Gmail 差出人については Gmail 公式アプリと同じ情報源をまず試す、という
判断。最終的な優先順位: 連絡先の写真 → **Google プロフィール写真** →
Gravatar → 企業ロゴ → イニシャル。

背景: Gmail 公式アプリが表示する差出人アイコンは Google アカウントの
プロフィール写真であり、Gravatar に未登録の相手は otegami ではイニシャル
表示のままになっていた。Gmail アカウントが接続されている場合に限り、
Google People API からプロフィール写真を取得してこの差を埋める。

### `GooglePeopleAvatarClient` (`packages/OtegamiKit/Sources/GoogleOAuth/`)

People API の `otherContacts.search` (`readMask=photos,emailAddresses`)
1回分の問い合わせと、写真バイト列のダウンロードを担う、`GoogleOAuthClient`
と同じ層のプレーンな actor。Apple 専用フレームワークに依存しない
(`URLSession`のみ) ため、`GoogleOAuthClientTests`と同じ`URLProtocol`スタブ
方式で`GooglePeopleAvatarClientTests`から直接単体テストできる — アプリ
ターゲット (`apps/Otegami/Sources/Support/`) の他の3つの resolver
(連絡先/Gravatar/企業ロゴ) がいずれも単体テストを持たない (アプリターゲット
に unit test ターゲットが無く、`OtegamiUITests`しか無い —
`apps/Otegami/project.yml`参照) のとは対照的に、この情報源は「People API
の URL 構築・JSON パース・ステータスコード分類」という最も間違えやすい
部分を`swift test`で機械的に検証できるようにした。

- **`otherContacts.search`のみ、`people.searchContacts`は使わない**: 前者は
  Gmail が自動収集する「連絡はしたが保存していない相手」、後者はユーザーが
  明示的に保存した Contacts を検索する。Gmail 公式クライアント自身が
  差出人アイコンのフォールバックに使っているのは前者の母集団で、これは
  まさにこの機能が埋めたいギャップ (Gravatar 未登録・Contacts 未保存の
  相手) と一致する。後者も追加で問い合わせると、スコープが触れる個人データ
  の範囲とリクエスト数が増える一方、その母集団は同期済みの
  `ContactPhotoResolver` (Google Contacts と端末の連絡先が同期されている
  場合) で既にある程度カバーされているため、追加コストに見合わないと判断
  した。
- **`default: true`の写真 (プレースホルダーのシルエット) は「無い」と同じ
  扱い** — 表示すれば otegami 自身のイニシャル+アカウント色フォールバック
  より明らかに劣る。
- `=s160`サイズ指定を URL に付与してから写真本体をダウンロードする —
  `GravatarAvatarResolver.gravatarURL(for:)`の`s=160`と同じ動機 (~30pt の
  丸いアバターのために原寸大の画像を取得しない)。

### `GoogleProfilePhotoAvatarResolver` (`apps/Otegami/Sources/Support/`)

`AvatarImageResolving`に準拠する actor。`GooglePeopleAvatarClient`への
1回分の問い合わせをラップし、以下を追加で担う:

- **Gmail アカウントが1つ以上あるユーザーだけに効く**: `AppEnvironment`が
  持つ Gmail アカウント一覧・`TokenStore`への参照を、`GmailAccessTokenBridge`
  (`AppEnvironment.swift`) 経由の`GmailAccessTokenProviding`プロトコル越しに
  取得する。この resolver 自身は`AppEnvironment.init()`のごく早い段階
  (`database`/`tokenStore`がまだ存在しない時点) で構築されるため、
  `PendingSendCoordinator`と全く同じ「`weak var environment` +
  `configure(environment:)`を`init()`最後尾で呼ぶ」二段階配線パターンを
  再利用した (Swift の二相初期化ルール — 詳細は`GmailAccessTokenBridge`の
  ドキュメントコメント参照)。複数 Gmail アカウントがある場合は成功する
  まで順に試す。
- **スコープ不足のフォールバック**: `contacts.other.readonly`スコープ
  追加前に接続された既存 Gmail アカウントのトークンは、再認証するまで
  この新スコープを持たない。People API が 401/403 を返した場合、その
  アカウント id を`scopeInsufficientAccountIds`(このプロセスの生存中だけ
  有効なメモリ上の`Set`) に記録し、以降の呼び出しでは問い合わせずスキップ
  する — 一覧をスクロールするたびに同じアカウントへ 401 を連打しない
  ため。**再認証を強制することはしない** — `AccountEditView`の案内文 +
  既存の「再認証」ボタン (元々は「認証切れ」時専用だったものを、この
  ヒントの導線として流用) からユーザー自身が選ぶ。
- キャッシュは Gravatar と同じ設計 (メモリ+ディスク2段、TTL 7日、
  ネットワークエラー/該当アカウント無し/全アカウントがスコープ不足は
  negative cache しない — `Caches/AvatarCache/GoogleProfilePhoto/`)。

### OAuth スコープ

`GoogleOAuthEndpoints.scope`に`https://www.googleapis.com/auth/contacts.other.readonly`
を追加した。詳細 (機密性の高いスコープであること、既存アカウントの再接続
導線、公開ステータス切替時の審査への影響) は
[`docs/oauth-setup.md`](oauth-setup.md)「`contacts.other.readonly`」節参照。

### 設定

`AvatarSourceSettingsStore.showGoogleProfilePhotoKey`(既定 ON)。設定 →
「メール一覧」の「連絡先の写真を表示」の直後・「Gravatar の画像を表示」の
直前に「Google プロフィール写真を表示」トグルを追加し、footer に「差出人の
メールアドレスが Google に送信されます」という段落を追加した (Gravatar の
ハッシュ送信の注記と同じ形式)。

### 検証

`make test`(`GooglePeopleAvatarClientTests`: 見つかった/デフォルト写真の
除外/大文字小文字を区別しないマッチ/該当なし/401・403 でスコープ不足判定/
5xx とネットワークエラーで unavailable 判定/ダウンロード成功・失敗/
URL 構築のそれぞれを検証)・`make mac`・`make ios` すべて green。

`OtegamiAvatarSettingsUITests`に「Google プロフィール写真を表示」トグルの
アサーション (既定 ON・存在確認・タップ後もクラッシュしないこと) を追加。

**未検証・ユーザー側作業として残るもの**: 実 Gmail アカウントでの People
API 呼び出しそのもの (実際に写真が取得できる差出人でのエンドツーエンド
確認) は、このセッションのシミュレータ環境でネットワーク不調
(`MailCoreErrorDomain error 1`でアカウント追加自体が失敗する既知事象) が
あり実施できなかった。`HUMAN_TASKS.md`「既存 Gmail アカウントを再接続し、
Google プロフィール写真を確認」に手順を記録した。

### 次フェーズへの申し送り

- 実 Gmail アカウントでの People API 呼び出しの実機/実ネットワーク環境
  での最終確認 (上記参照)。
- スコープ不足の 401/403 判定は、Google が実際にどちらのステータスで
  返すかの実地確認をしておらず (People API のドキュメント記述に基づく
  実装)、両方を同じ扱いにすることで判定を保守的にしてある — 実際の挙動が
  判明したら、この保守的な扱いを緩める余地があるかもしれない。

## macOS: 狭いウィンドウでサイドバーに戻れない不具合の修正

実機報告「compact になった時にサイドバーが出てこない。ハンバーガーメニュー
もない」の調査・修正記録。

### 調査

iOS 側 (`OtegamiRootView`/`MailScreenView`) はサイズクラスに関係なく常時
ハンバーガーボタンを描画する構造で、`iPad mini (A17 Pro)` シミュレータで
実機起動しスクリーンショットで確認した通りハンバーガーは常に存在する
(`design_handoff_ios_mail` 由来の 1a 構造がそもそもサイズクラス分岐を
持たない) — この報告は iOS 側のコードの不具合ではないと判断した。

macOS 側 (`OtegamiApp.swift` の `RootView.splitView`) を実機ビルドで調査
したところ、次の2点を確認した:

1. `NavigationSplitView(preferredCompactColumn:sidebar:content:detail:)`
   (旧実装) は `columnVisibility` を一切バインドしていないため、
   AppKit がサイドバーの表示状態を完全に内部管理する。ウィンドウを
   1000pt 幅から徐々に見た目上リサイズしても、システムが自動で挿入する
   はずの「サイドバー切り替え」ツールバーボタン (`sidebar.leading` の
   アイコン) は、この開発機の Xcode-beta/macOS 26 ベータの組み合わせでは
   **通常状態で全く描画されない** ことをスクリーンショットと
   `System Events` によるアクセシビリティツリー調査 (`AXToolbar`/
   `AXGroup`/`AXButton` を再帰的に列挙) で確認した — 3回の独立した
   起動全てで toolbar 内に該当ボタンが存在せず、View メニューにも
   「サイドバーを表示/隠す」の項目が挿入されなかった (`menu 1 of menu
   bar item "View"` の中身を確認、`Show Tab Bar`/`Show All Tabs`/
   `Enter Full Screen` のみ)。
2. ウィンドウ自体の最小幅 (3カラム合計の最小幅、実測 381pt) がシステム
   の window resize でクランプされるため、通常のドラッグ操作だけでは
   sidebar 自体が消えるところまでは再現できなかった (detail 列が極端に
   圧縮されるだけ)。ただし (1) の「システム自動挿入のはずの復帰用
   コントロールが実際には存在しない」という事実だけで、**一度何らかの
   経路 (ウィンドウの配置・タイル化・将来の AppKit 側の挙動変化など) で
   サイドバーが隠れた場合、戻す手段がアプリ内のどこにも無い** という
   報告内容の核心は再現・裏付けできている。

### 修正

`columnVisibility` を明示的に `@State` (既定 `.all`、3カラム表示を維持)
としてアプリ側が所有し、`NavigationSplitView(columnVisibility:
preferredCompactColumn:sidebar:content:detail:)` (SwiftUI が提供する
組み合わせ初期化子) にバインドした上で、`columnVisibility != .all` の
間だけ表示される「サイドバーを表示」ボタンを `splitView` のツールバーに
明示追加した (`RootView.macSidebarToolbarContent`,
`mac.showSidebarButton`)。AppKit 自身の自動復帰コントロールの有無に
依存しない、アプリが完全に制御する復帰導線にすることで、上記調査で
確認した「自動ボタンが無い」状態でも必ずサイドバーへ戻れるようにした。
iOS 側 (`splitView` は iOS では描画されない dead code、`rootContent`
参照) は変更していない。regular 幅の3ペイン (既定 `.all`) の見た目・
挙動も変更していない。

### 検証

`make mac`/`make ios` green (`iPad mini (A17 Pro)` シミュレータでの
実機起動・ハンバーガー常時表示のスクリーンショット確認を含む)。macOS
側はウィンドウの実配置・アクセシビリティツリー調査により「自動復帰
ボタンが存在しない」ことを実機で確認した一方、この開発機のウィンドウ
最小幅の制約により「サイドバーが実際に隠れた状態」からアプリ内蔵の
復帰ボタンをクリックして戻る、という一連の操作そのものは自動化できな
かった (`System Events` によるウィンドウリサイズ・ディバイダのドラッグ
操作の両方を試したが、対話的なドラッグジェスチャの合成は今回のツール
セットでは信頼できる形で再現できなかった)。コード側は Apple 公式の
`columnVisibility` バインディング契約に従っており (ボタンの表示条件
`columnVisibility != .all`、タップ時 `columnVisibility = .all` の単純な
ロジック)、実機での最終確認 (ウィンドウを本当に極端に狭くする/タイル
化する操作を人の手で行い、復帰ボタンが現れてタップで戻ることを確認)
は次回の実機フィードバックで裏付けることを申し送る。

## アカウント絞り込みチップ列の「＋」削除

`AccountFilterChipRow` (1a のアカウント絞り込みチップ、design-phase-2
節参照) の末尾にあった「＋」(アカウント追加) チップを削除した。ハンバー
ガーメニュー側の同等ボタン (`folderSheet.addAccountToolbarButton`、
アカウント0件時の空状態ボタンは例外として残置) は実機フィードバック
第3弾 (K) で既に削除済み — `docs/settings.md`「ハンバーガーメニューの
アカウントセクション折りたたみ」節参照。今回、チップ列側にも同じ理由
(アカウント追加は設定画面 →「アカウントの設定」→「アカウントを追加」
から常にできるため、複数の場所に同じ入口を重複させる必要が無い) が
当てはまると判断し、揃えて削除した。アカウント0件時の空状態
(`MailScreenView.emptyState`) の「アカウントを追加」ボタンは維持。

`AccountFilterChipRow`の`onAddAccount`クロージャは削除し、呼び出し側
(`MailScreenView.swift`) からも該当引数を1行だけ取り除いた — この
バッチの並行作業者が別途 `MailScreenView`/`MessageListView` の一覧
ヘッダ改修を予定していたため、それ以外の変更は加えていない
(`presentAddAccount`関数自体はアカウント0件時の空状態ボタンから引き続き
参照されるため、削除していない)。

XCUITest 側: `mail.chip.addAccount`を直接参照していた
`DovecotAccountUITestHelpers.openAccountSetup(in:)`/
`returnToMailTabRootIfNeeded(in:)`と、同じパターンをインラインで持って
いた`OtegamiM6ICloudFormUITests`/`OtegamiM6TypeSelectionUITests`を、
「アカウントが1件も無ければ空状態ボタン、既にあれば 設定 →
アカウントの設定 → アカウントを追加」という新しい導線に合わせて更新
した (共通ロジックは`openAccountTypeSelection(in:)`に切り出し)。
`saveAccount(in:)`は、設定画面経由でアカウント作成シートを開いた場合に
備え、保存後に開いたままの設定シートも閉じてメール一覧ルートへ戻る
処理を追加した (`settingsSheet.closeButton`が存在するときだけ) — チップ
「＋」経由では発生しなかった「保存後も設定シートの中にいる」状態を
吸収し、既存テストの「保存したら一覧に戻っている」という前提を壊さない
ようにした。

## メールボックス単位の非表示

`docs/settings.md`「メールボックス単位の非表示」節に実装・判断の詳細を
まとめた (設定画面からの導線、非表示にすると消える範囲、同期を止める
理由、移動先ピッカーからは除外しない理由)。ここには実装上の技術的な
注記のみ残す。

- **`MailboxRecord`への`isHidden`追加は、過去のマイグレーション自身の
  型デコードを壊しうる**: v21 マイグレーション (Gmail フォルダ名の
  文字化け修復) が`MailboxRecord.fetchAll(db)`で当時のテーブルを
  Codable 経由で読んでいたが、これは「今のSwift構造体の形」でデコード
  するため、v21 実行時点でまだ存在しない列 (今回追加した`isHidden`、
  v26 で追加) があると `column not found` で失敗する。
  `AppDatabaseTests.v21RepairsDisplayPath`が (元々は「素の SQL で
  v20 まで手動セットアップしてから `migrator.migrate(dbQueue)` で
  最新まで一気に流す」という別の理由で書かれていたテストだったが)
  この壊れ方を実際に検出した。修正: v21 マイグレーション自身を
  `MailboxRecord`の Codable デコードに頼らない素の `Row`/SQL 実装に
  書き換えた — `AccountRecord`のテストヘルパー側で既に確立していた
  「凍結されたスキーマ vs. 今の Swift 型」という回避パターンを、
  マイグレーション本体のコードにも適用した形。同種の`MessageRecord
  .fetchAll(db)`を使っている v7/v18 マイグレーションは今回変更して
  いない (今回のバッチでは`message`テーブルに列を追加していないため
  実害が無い) が、将来`message`テーブルに列を追加する際は同じ注意が
  必要になる。

### 検証

`make test`/`make mac`/`make ios` green (`MailboxQueryTests`/
`ThreadQueryTests`/`MessageQueryTests`/`AccountSyncerTests` に新規テスト
追加 — includeHidden フィルタ、setHidden、統合受信トレイからの除外、
`.all` スコープでの同期スキップ、再同期での isHidden 保持)。**実機シミュ
レータでの「メールボックスの表示設定」画面の目視確認は今回未達** — この
セッション中、dev mailstack への接続が断続的に失敗する状態 (同じ
リポジトリ・同じ dev mailstack に対して別セッションが並行して作業して
いたことを `git reflog`/コンテナの再起動履歴から確認済み — 単純な
コード不具合ではなくリソース競合と判断) が続き、XCUITest 経由のアカウント
追加が完了しなかった。GRDB データベースファイルへ直接アカウント/
メールボックス行を挿入する代替手段も試したが、`AppEnvironment.accounts`
側に (Keychain のパスワードが無い行を弾く、等の) 追加の整合性チェックが
入っている可能性が高く、この方法でも一覧に反映されなかった。コードの
静的レビュー・上記ユニットテスト・ビルド成功に加え、既に実アカウントが
入っている状態での関連画面確認 (項目1の macOS 検証時に撮ったスクリーン
ショット、ハンバーガーメニューのツリー描画自体は既存コード) までは確認
できているが、この機能固有の画面遷移そのものの実機目視は次回の実機
フィードバックで裏付けることを申し送る。

## しきい値で自動実行 (D8 スワイプ操作バッチ)

ユーザー要望「ショートスワイプやロングスワイプで、止まらずに処理して
欲しい (今はボタンが出るだけ)」— design-phase-2 で確定した「短い/長いの
2段しきい値、長い側はボタンを出してタップ確定」という妥協 (SwiftUI 標準
`.swipeActions` の「宣言順の最初の1つしかフルスワイプで自動発火できない」
という制約が理由、design-phase-2 節参照) を撤廃し、iOS の一覧行のスワイプ
を `.swipeActions` から自前の `DragGesture` ベースの実装 (`MessageListRow`)
に作り替えた。

### 実装

- **しきい値**: `shortSwipeThreshold` (72pt)・`longSwipeThreshold`
  (152pt)、`MessageListRow` の `private let`。ドラッグ量がどちらの符号
  (正=leading、負=trailing) かでどちらの辺のアクションかを、しきい値との
  比較で短い/長いどちらのアクションかを決める (`reveal(for:)`)。
  `longSwipeThreshold + 40pt` でクランプし、指を大きく動かしても行が
  画面外まで滑っていかないようにしている。
- **プレビュー**: ドラッグが `DragGesture(minimumDistance: 20)` の
  しきい値を超えた瞬間から、行の下に色付きの背景 + アイコン (`SwipeRevealBackground`)
  が現れる — `shortSwipeThreshold` 未満でもここでは短い方のアクションを
  仮表示する (Gmail 等のプレビュー挙動を参考に確定した見た目)。
  `longSwipeThreshold` を超えると長い方のアクションの色・アイコンに切り
  替わる。**ボタンではなく色 + アイコンのみ** — ラベル文字は付けない。
- **触覚フィードバック**: 表示中のアクションが切り替わるたび
  (`.none → short`, `short → long`) に `UIImpactFeedbackGenerator` を鳴らす
  (短いアクション = `.light`、長いアクション = `.medium`)。
- **即座に実行、ボタンなし**: 指を離した時点のドラッグ量が
  `shortSwipeThreshold` 以上なら、そのしきい値に対応するアクションを
  その場で実行する (`commitSwipe(translation:)`)。未満なら
  `withAnimation(.easeOut)` で行を `0` へ戻すだけで、何も実行しない。
- **削除・迷惑メールのタップ確定ガードを撤廃**: design-phase-2 で導入した
  `SwipeAction.isGuardedFromFullSwipe` (削除/迷惑メールだけはフルスワイプ
  で自動発火させず、必ず明示タップを要求する) は削除した。このバッチの
  要件が「削除・迷惑メールも自動実行してよい (既存の Undo トーストが
  受け皿)」と明言しているため — `MessageListView.scheduleUndo` の
  Undo トースト自体は無変更。
- **スクロールとの共存**: `List` 自身の縦スクロール用パンジェスチャー
  (UIKit の `UIScrollView` 由来) と、行に付けた `DragGesture` の両方が
  同じタッチストリームに対して独立に反応できるよう、`swipeGesture` の
  `onChanged` は横方向優位のドラッグ (`abs(width) > abs(height)`) のときだけ
  `dragTranslation` を更新する — 縦方向優位 (=スクロール) のドラッグでは
  行を一切動かさないので、`List` 側のスクロール認識を妨げない。1h の
  長押し選択ジェスチャー (`.simultaneousGesture(LongPressGesture(...))`)
  と合わせて、1つの行に3種類のジェスチャー (タップ・長押し・横ドラッグ) が
  同じタッチストリームで競合なく共存する。

### 実機バグ: スワイプ発火と同時に本文へ遷移してしまう不具合

実機フィードバックで、スワイプでアクション (アーカイブ) が正しく発火する
一方、**指を離した瞬間にその行のタップ判定も成立し、本文画面へ遷移して
しまう** (アーカイブで消えたスレッドを開こうとして「本文が見つかりません」
という空表示になる) というバグが見つかった。

**原因**: 初期実装は `swipeGesture` を `.simultaneousGesture` で行の
`ZStack` に付けていた。`rowButton` (`Button(action: handleTap)` で包んだ
`ThreadRowView`) はドラッグ量ぶんそのまま `.offset(x: dragTranslation)` で
指に追従させている — つまりボタンの見た目は常に指の真下にある。`Button`
自身の既定のタップジェスチャーは「指がボタンの領域から一定以上離れたら
タップを不成立にする」という drag-cancel の仕組みを内部に持つが、
ボタン自体が指に追従して見た目上まったく動かないため、この
drag-cancel が一度も発動しない。結果、`swipeGesture` の `onEnded` で
アクションが発火するのと同じタッチアップから、`Button` 自身のタップも
成立してしまっていた。

**修正**: `swipeGesture` の付与を `.simultaneousGesture` から
`.highPriorityGesture` に変更した。`DragGesture(minimumDistance: 20)` が
実際に認識される (=しきい値以上ドラッグされる) ときだけ `Button` の既定
ジェスチャーより優先され、その回のタップは完全に握り潰される。
`minimumDistance` 未満の本物のタップは `DragGesture` がそもそも認識しない
(=`.highPriorityGesture` が横取りするものが無い) ため、`Button` の通常の
タップは今まで通り成立する。`List` 自身の縦スクロール用パンジェスチャーは
SwiftUI の外側 (UIKit) の別レイヤーで調停されるため、この優先度変更の
影響を受けない。

### 検証

`make test`/`make ios`/`make mac` green (`MessageListRow.swift` の変更は
iOS/macOS 両方でビルド可能な `#if os(iOS)` 分岐に閉じている)。

新規 `OtegamiSwipeAutoFireUITests` (`apps/Otegami/UITests/`) を追加し、
以下を確認する設計にした:

- しきい値未満のドラッグは何も発火せず、行が元の位置に戻ること
  (`testDragBelowShortThresholdFiresNothing`)。
- 短いしきい値を超えたドラッグでアクション (ピン留め) が即座に発火する
  こと、ボタンを介さないこと (`testShortSwipeFiresTheShortActionImmediately`)。
- 長いしきい値を超えたドラッグで別のアクション (アーカイブ) が即座に
  発火し、行が一覧から消えること (`testLongSwipeFiresTheLongActionImmediately`)。
- 上記のバグ修正の回帰確認: スワイプでアクションが発火しても本文画面へは
  遷移しないこと (`testSwipeDoesNotAlsoNavigateToThreadDetail`)、通常の
  タップは変わらず本文画面へ遷移すること (`testPlainTapStillNavigatesToThreadDetail`)。

既存の `OtegamiM3SwipeActionsUITests`/`OtegamiM4SwipeReadUITests`/
`OtegamiPinSwipeListDisplayUITests` は、ボタンを探してタップする手順を
`performThresholdSwipe(on:distancePoints:in:)` (新設のポイント単位の
座標ドラッグヘルパー、`DovecotAccountUITestHelpers.swift`) で置き換え、
発火した結果 (行が残る/消える、ピン留め状態が変わる) を直接アサートする
形に更新した。`XCUIElement.swipeLeft()`/`.swipeRight()` は SwiftUI 標準の
`.swipeActions` 用の便宜メソッドで、この自前 `DragGesture` には使えない
(短い/長いを打ち分けられない) ため。

**このセッションでの制約**: 実機/シミュレータでの XCUITest 実行時、
アカウント追加フォームの「接続テスト」が `MailCoreErrorDomain error 1`
(connectionFailed) で一貫して失敗する現象に遭遇した。切り分けの結果:
`MailCoreIMAPSession` を直接叩く `MailCoreIMAPSessionIntegrationTests`
(macOS のプレーンプロセスから同じ dev mailstack の Dovecot へ接続) は
即座に全件成功し、dev mailstack・`MailCoreIMAPSession` 自体は健全である
ことを確認した。複数の異なるシミュレータ (Xcode 標準の iPhone 17e、
`simctl create` で新規作成したデバイスを含む)、mailstack の完全な
再作成 (`docker compose down && up`)、低いシステム負荷の状態のいずれでも
再現し、この開発機で並行稼働していた別エージェントの無関係な
`OtegamiM1VerificationUITests` でも同じ症状が独立に発生していたことも
確認した — このセッション固有の、iOS シミュレータのネットワーキング
(具体的な原因は未特定) に起因する環境要因であり、`MessageListRow` の
コード自体の欠陥ではないと判断している。上記の新規/更新 UITest は
コードとしては揃えたが、この制約により今回のセッションでは実行完了
(green) を確認できていない — 次回セッションでシミュレータ/mailstack の
状態が回復し次第、優先して再実行し結果をここに追記すること。

## 実機報告: アーカイブ後の「元に戻す」が効かない (根本原因と修正)

実機報告「アーカイブをした後、元に戻すをしても戻ってなさそう」の調査記録。
「しきい値で自動実行」節・「design-phase-2: delaying a destructive
action's entire local commit for an undo window loses data on an app kill
mid-window」節で確立した設計 (即座にローカル DB へコミットし、Undo は
「その書き込みを逆再生する」形にする) 自体は正しかったが、その逆再生
(`undoRemoval(_:)`、現 `MessageRemoval.undo(_:db:)`) の実装に**再現性の
高いバグ**があった。

### 原因

`MessageRecord.threadId` は `thread` テーブルへの外部キー
(`AppDatabase.foreignKeysEnabled = true`) で、`onDelete: .setNull` は
「参照先の `thread` 行が削除されたとき」の挙動を決めるだけで、**存在しない
`thread.id` を指す `message` 行を INSERT しようとした瞬間にも即座に違反
になる** (SQLite の外部キー制約はデフォルトで immediate、`DEFERRABLE
INITIALLY DEFERRED` を明示しない限りトランザクションの最後まで待たない)。

旧 `undoRemoval(_:)` は次の順序で書き戻していた:

1. スナップショットに含まれる `message` 行をすべて INSERT (この時点で
   `thread.id` はまだ存在しない可能性がある)
2. `thread` 行が無ければ INSERT、あれば `recomputeAggregates`

スレッドの**最後の1通**をアーカイブ/削除すると
(`ThreadAssigner.recomputeAggregates`) `thread` 行ごと削除される —
これは単一メッセージのスレッド (よくあるケース) なら常に起きる。この
状態で Undo すると、手順1の `message` 行 INSERT が外部キー違反で例外を
投げ、`dbWriter.write` のトランザクション全体がロールバックする。呼び出し
側は `catch { }` で例外を握りつぶしていたため、UI 上は「タップしても
何も起きない」ように見えていた — スレッドは実際には一切戻っていない。

もう1つ、より狭い範囲の同種のバグも同居していた: `commitArchive` は
アーカイブ先アカウントの Archive ロールメールボックスに既に入っている
メッセージを「対象から skip」する (二重アーカイブの防止) が、旧実装は
`messages` (=フィルタ前の全ターゲット) をそのままスナップショットに
入れていたため、skip されたメッセージ (=削除されていない行) を Undo が
再 INSERT しようとして主キー重複で失敗するパスがあった。

### 修正

`packages/OtegamiKit/Sources/SyncEngine/MessageRemoval.swift` (新規)
に `MessageListView` が抱えていたロジックをそのまま切り出し、以下を
直した:

- `undo(_:db:)`: `thread` 行が無ければ**メッセージを INSERT する前に**
  先に復元し、外部キー違反を起こさない順序にした。
- `commit(_:summary:accountId:db:)`: 実際に削除した (=`continue` で
  skip されなかった) メッセージだけをスナップショットの `messages` に
  積むようにした。

`MessageListView.swift` 側 (`commitArchive`/`commitDelete`/`commitJunk`/
`undoRemoval`) は `MessageRemoval` を呼ぶだけの薄いラッパーに置き換え、
アーカイブ・削除・迷惑メールの3操作すべてに同じ修正が及ぶようにした
(旧実装は3つともほぼ同じコードが個別にコピーされていた)。ロジックを
`SyncEngine` (`OtegamiKit` パッケージ) 側へ移したことで、SwiftUI ホスト
無しの `swift test` から直接検証できるようになった — 修正前の
`MessageListView` はこのロジックを private メソッドとして丸ごと抱えて
いたため、Undo パス自体に自動テストが一切無かった。

### 検証

`packages/OtegamiKit/Tests/SyncEngineTests/MessageRemovalTests.swift`
(新規) が以下を確認する:

- 単一メッセージのスレッドをアーカイブ (`thread` 行ごと削除される) →
  Undo → `thread`/`message` 行が両方復元され、`ThreadQuery.request
  (mailboxId:)` の一覧クエリに再び現れること。同じ検証を削除でも実施。
- 未送信 (未 replay) の opQueue 行が Undo で削除される (無駄なサーバ
  往復をしない) こと。
- Archive ロールに既に入っているメッセージを含むスレッドをアーカイブ
  すると、そのメッセージは skip され、Undo が主キー重複で失敗しない
  こと。
- opQueue の行が (アカウントの IDLE ループ等により) Undo 前に既に
  replay 済みでも、Undo のローカル復元自体は成功すること。

修正前の実装 (メッセージを先に INSERT する順序) に一時的に戻して同じ
テストを実行し、実際に外部キー違反で失敗することも確認した — この
テストスイートが今回のバグを検出できることを裏付けている。

`make test`/`make ios`/`make mac` green。

**未検証**: サーバ側で元の op (アーカイブ/削除の IMAP MOVE) が Undo の
5秒ウィンドウより先に replay されてしまった場合 (アカウントの IDLE
ループや手動リフレッシュとの競合)、ローカルは復元されるがサーバ側は
アーカイブ済みのまま — 次回同期で再びアーカイブに巻き戻される可能性が
ある。これは今回の修正前から存在する既知のレアケースとして
`MessageRemoval.undo(_:db:)` のドキュメントコメントに明記してあり、
今回のセッションではスコープ外とした (サーバ側の逆操作を確実に
enqueue するには「元の op がどのメールボックスへ実際に着地したか」を
追跡する仕組みが要り、実機2台での検証もできない現状ではリスクに見合わ
ないと判断)。

## スワイプの滑らかさ改善

実機報告「スワイプしたときの挙動は、sparkみたいに滑らかにして欲しい」の
調査・対応記録。参考にしたのは Spark の実機録画 (フレーム抜粋):
ドラッグ中は行が指に追従しつつ背景色 (完了アクション) が指の位置まで
伸びる → リリース後、背景色が行全体に広がり行の中身が消える → 行の高さ
自体が縮んで一覧の隙間が詰まり、下部に Undo トーストが出る、という一連の
動き。

### 調査: 「滑らかでない」の実体

指への追従自体は元から `DragGesture` の `translation` を毎フレーム
そのまま `dragTranslation` に反映する 1:1 追従で、他の主要メールアプリと
同じ設計だった (フレームレート低下の兆候も無し)。実際に見比べて分かった
差は「リリース後」:

- 旧実装は `.onEnded` で **成立/不成立を問わず常に** `withAnimation
  (.easeOut(duration: 0.2))` で `dragTranslation` を `0` に戻していた。
- それとは完全に無関係・非同期に、`commitSwipe(translation:)` が
  `perform(action)` を呼び、そのままローカル DB を書き換える —
  アーカイブ/削除ならスレッドが `MessageListView.summaries` の
  `ValueObservation` から即座に消え、`List` 自身の (アニメーション無しの)
  デフォルトの行削除が走る。

つまり「行が0へスプリングバックするアニメーション」と「行が
(ノーアニメーションで) 一覧から消える処理」という**無関係な2つの変化が
コンマ数秒ずれて同時に走る**のが、実機で「カクッ」と感じる正体だった —
指への追従そのものの問題ではない。

### 修正

`apps/Otegami/Sources/Features/MessageList/MessageListRow.swift`:

- **キャンセル (しきい値未満で離す)**: `.easeOut(duration: 0.2)` を
  `interactiveSpring(response: 0.32, dampingFraction: 0.82)` に変更
  (`cancelSwipe()`)。指を離した勢いを反映して自然に収束する。
- **コミット (しきい値を超えて離す)**: アクションの性質で分岐
  (`commitReveal(action:direction:)`)。
  - **既読/未読切替・ピン留め** (行が一覧から消えない操作): 従来通り
    即座に `perform(action)` を呼び、`cancelSwipe()` でスプリング
    バックする — 行自体の見た目 (未読ドット・ピンアイコン) が状態変化を
    伝えるので、スライドアウトさせる意味が無い。
  - **アーカイブ・削除・迷惑メール** (行が一覧から消える操作、
    `commitRemoval(action:direction:)`): `dragTranslation` を `0` へ
    戻すのではなく、行の自身の幅 (`GeometryReader` で計測) + 余白ぶん
    さらに同方向へスプリングでスライドさせ、完全に自分の `clipShape`
    の外まで出す。約240ms 待って (アニメーションが視覚的にほぼ収まる
    頃) からようやく `perform(action)` を呼びローカル DB を書き換える —
    行が既に画面外へ消えた**後で**一覧から取り除かれるため、`List` 側の
    行削除 (高さの collapse) が見えているものと衝突しない。
- **`MessageListView.swift`**: `observeThreads()` の `summaries` 代入
  (`applySummaries(_:)` に切り出し) を `withAnimation(.easeInOut
  (duration: 0.25))` で包んだ — `ForEach(displayedSummaries)` は
  `ThreadSummary.id` で差分を取るため、無関係なフィールド変更 (未読
  ドットの切替など) では何もアニメーションされず、行の増減/並び替えの
  ときだけ高さが滑らかに collapse/expand する。上記のスライドアウトと
  合わせて「背景色が広がる → 行がスライドアウト → 隙間が詰まる」が1本の
  連続したアニメーションに見えるようになる。
- しきい値切替時の触覚フィードバック、Undo トーストは無変更。

### 検証

`make test`/`make ios`/`make mac` green。既存の
`OtegamiSwipeAutoFireUITests` は `waitForExistence`/`waitForNonExistence`
をポーリング (5〜10秒) するアサーションのみで固定 `sleep` に依存していない
ため、約240msの遅延を追加しても許容範囲のはず — 「しきい値で自動実行
バッチ」節に記載の、このセッションで継続しているシミュレータの接続問題
(`MailCoreErrorDomain error 1`) の影響を受ける場合は別途この節に追記する。

実機シミュレータでの目視確認 (スクリーンショット/録画) は
`.claude/skills/verify/SKILL.md` の手順に沿って実施し、結果をここに
追記する。

## Task #42: BIMI 対応・自分のプロフィール写真・アバター診断

Google プロフィール写真の索引方式 (`adacb94`) 後も実機で写真が出ない
という報告を受けて着手したバッチ。4点まとめて実施した:

### 1. アバター診断画面

設定 → アカウント編集 (Gmail アカウント) →「アバター診断」
(`GoogleAvatarDiagnosticsView`、`apps/Otegami/Sources/Features/Settings/
GoogleAvatarDiagnosticsView.swift`)。開くたびに Google
プロフィール写真の索引を実際に強制再構築し (`GoogleProfilePhotoAvatarResolver
.forceRebuildDiagnostics(accountId:)`)、以下を1画面に表示する:

- スコープ3状態 (許可済み(完全)/(基本)/未許可/確認できず) — 既存の
  `GoogleScopeDiagnosisRow`を再利用。
- `otherContacts.list`/`people/me/connections`/`people/me`それぞれの
  結果 (成功/スコープ不足/取得失敗)・HTTP ステータス・取得エントリ数・
  写真ありエントリ数・エラー時のレスポンス本文冒頭 (`GooglePeopleDiagnosticsFormatting
  .maskEmailAddresses(in:)`でメールアドレスをマスクしてから表示)。
- 索引の総アドレス数・最終構築時刻。
- **索引構築が部分失敗で丸ごと破棄された場合、その事実と理由を表示**
  (下記「3. 索引構築失敗の可視化」参照) — 握り潰さない。

`GooglePeopleAvatarClient`(`packages/OtegamiKit/Sources/GoogleOAuth/
GooglePeopleAvatarClient.swift`)に、既存の`.list`呼び出しはそのまま
(挙動非変更) に保ちつつ、診断用の`fetch...IndexOutcome(accessToken:)`
系メソッド (`GooglePeopleIndexOutcome` = 結果 +
`GooglePeopleFetchDiagnostics`) を追加した。

### 2. 自分のプロフィール写真

`GooglePeopleAvatarClient.fetchSelfPhotoIndexOutcome(accessToken:)`が
`GET people/me?personFields=emailAddresses,photos`を叩き、自分の
アドレス (エイリアス含む全件) → 写真の索引を返す。
`GoogleProfilePhotoAvatarResolver.fetchAndStoreIndex`が既存の
`otherContacts`/`connections`と同様にこれもマージする。

**新規スコープは追加していない** —
developers.google.com/people/api/rest/v1/people/get の
Authorization scopes 一覧を実際に確認したところ、`people.get`は
`https://www.googleapis.com/auth/contacts.other.readonly`
(このアプリが`otherContacts.list`用に既に要求している既存スコープ) を
受理することを確認した。実 Google での E2E は不可のため「このスコープで
`photos`フィールドが実際に返るか」まで実機確認はできていないが、
`otherContacts.list`は同じスコープで他人の`photos`を返せている以上、
`people/me`の自分の`photos`も同じスコープで返る可能性が高いと判断した
(判断の詳細は`GooglePeopleAvatarClient.fetchSelfPhotoIndexOutcome`の
ドキュメントコメント)。実機で写真が出ない場合、アバター診断画面の
「people/me (自分のプロフィール写真)」行の HTTP ステータスが確認の
手がかりになる — 403 ならスコープ不足の可能性がある (その場合は
別途 profile 系スコープの追加要否を再検討する)。

### 3. 索引構築失敗の可視化

`GooglePeopleAvatarClient.fetchPhotoIndex`は元々「ページ途中の失敗で
索引全体を破棄する」実装 (部分索引をキャッシュに書き込むと欠落が
`indexTTL`の間ずっと気付かれないため) だったが、破棄が起きたこと自体は
どこにも記録されていなかった。`GooglePeopleFetchDiagnostics.discarded`/
`.discardReason`にこれを記録し、アバター診断画面に表示するようにした
(例: 「ページ3件目の取得に失敗したため、既に取得済みの47件を破棄しま
した。」)。

### 4. BIMI 対応

`apps/Otegami/Sources/Support/CompanyLogoAvatarResolver.swift`が
favicon より前に BIMI を試すようになった。

**方針転換 (上の「BIMI は実装見送り」節からの reversal)**: 当時の
見送り理由の2点目 (DNS TXT 取得の高レベル API 不在) は今回の指示が
明示的に DNS over HTTPS (`https://dns.google/resolve`) 経由の実装を
指定したことで解消された。1点目の懸念 (サードパーティ DoH への問い合わせ
はプライバシー上のトレードオフ) は依然として残るが、今回の指示は
このトレードオフを認識した上で明示的に DoH 実装を求めており、この
バッチの作者による意図的な再選択として実装した。BIMI 判定のたびに
差出人ドメイン名が Google の DoH エンドポイントへ送信される点は、
`CompanyLogoAvatarResolver`が favicon 取得のために元々ドメイン名を
接続先サーバーへ送っているのと同種のトレードオフとして扱った (設定の
footer 注記は変更していない — 送信先が増える差分はあるが、注記の
文言レベルでは既存の「ドメイン名が接続先サーバーに送信されます」で
包含されると判断した)。

実装は新規 SPM ターゲット`BIMI`
(`packages/OtegamiKit/Sources/BIMI/`、`Package.swift`に追加、
Linux 互換・`URLSession`のみ) に集約した:

- `BIMIRecordClient.resolveLogoURL(domain:)`: `default._bimi.<domain>`
  の TXT レコードを DoH JSON API で引き、`v=BIMI1; l=<URL>`から SVG
  URL を取り出す。複数の quoted segment に分割された長い TXT 値の
  再結合 (空白を挟まず連結) も実装 — 実際に PayPal の公開 BIMI
  レコードで確認済み。
- `BIMISVGSafety.isSafe(_:)`: **セキュリティ必須**のゲート。
  `<script>`・`javascript:`・イベントハンドラ属性・`<image>`/
  `<iframe>`/`<foreignObject>`/`<style>`・外部参照 (`#fragment`以外の
  `href`/`xlink:href`)・XXE 相当の`<!ENTITY>`・サイズ上限 (64KB) を
  拒否する。何であれ「安全とわかっている構文以外は全部拒否」の
  fail-closed。
- `BIMISVGParser`: 安全な subset のみを解釈する手書きのタグスキャナ
  (`XMLParser`は Linux 互換性のため不使用)。対応要素:
  `svg`/`g`/`path`/`rect`/`circle`/`ellipse`/`polygon`/`polyline`/
  `line`/`defs`/`title`/`desc`。パスコマンドは`M`/`L`/`H`/`V`/`C`/`S`
  (滑らかな3次ベジエ)/`Z`のみ — `Q`/`T`/`A`(2次ベジエ・弧) は
  非対応で文書全体を拒否する (誤った形状で描画するくらいなら描画しない
  方が安全、という判断)。`transform`は`translate`/`scale`/`matrix`の
  みサポート。`fill="url(#...)"` (グラデーション/パターン参照) は
  未対応と判定して文書全体を拒否する (以前は「指定なし」と誤って
  親の色を継承してしまうバグがあったが、`FillAttributeResolution`
  導入で修正済み)。
- `BIMISVGRenderer`(app 層、`apps/Otegami/Sources/Support/
  BIMISVGRenderer.swift`): `CoreGraphics`+`ImageIO`でラスタライズし
  PNG を生成する唯一の Apple-only な部分。`WKWebView`は使わない
  (指示どおり)。

**実際の公開ドメインへの1回限りの動作確認**: PayPal
(`default._bimi.paypal.com`) の実際の BIMI レコードを DoH 経由で取得し
(読み取りのみ)、実際に公開されている SVG ロゴ
(`paypalobjects.com/marketing/web/logos/paypal_ppe.svg`) を取得して
`BIMISVGSafety`/`BIMISVGParser`に通した。この検証で2つの実装ギャップを
発見・修正した:
1. Adobe Illustrator 等が出力する`<title>`要素がパーサーに未対応で
   文書全体が拒否されていた → `title`/`desc`を`defs`と同様スキップする
   対象に追加。
2. 実際のロゴが`S`/`s`(滑らかな3次ベジエ) コマンドを使っていて
   未対応だった → `S`/`s`を実装 (制御点の反射計算は SVG 仕様どおりの
   厳密な変換であり近似ではない)。
実際のロゴ SVG 全文 (PayPal のもの) を`BIMISVGParserTests`の回帰
フィクスチャとしてそのまま埋め込んである。

FreeMailDomains (gmail.com 等) は BIMI 対象外のまま (favicon と同じ
ドメイン単位の除外判定を BIMI にも適用)。

### 検証

`packages/OtegamiKit`に新規`BIMITests`(DoH 応答パース・TXT 再結合・
安全性拒否ケース・SVG パーサーの各種ケース・実際の PayPal ロゴでの
end-to-end) を追加、`GoogleOAuthTests`にも診断系メソッド・マスク
関数のテストを追加。`make test`/`make mac`/`make ios` green。

`GoogleAvatarDiagnosticsView`は実 Google 認証なしで到達できないため、
`OtegamiAvatarDiagnosticsUITests`が UITest 専用の
`OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT`環境変数
(`AppEnvironment.init()`) で実トークンを持たない偽の`.gmail`アカウントを
挿入し、設定 → アカウント編集 →「アバター診断」まで実際にタップで
遷移して画面が (スコープ確認できず/トークン取得失敗の状態で) 表示崩れ
なく描画されることを確認した。

### ユーザーへの診断手順

実機で Gmail アカウントの「アカウント編集」→「アバター診断」を開き、
画面全体のスクリーンショットを1枚送ってもらえれば、このセッションの
変更内容だけで原因を確定できるはず — スコープ3状態・3エンドポイントの
HTTP ステータス/エントリ数・索引の総アドレス数が1画面に揃っている。

## Task #45: HTMLメール表示 — ダークモードで文字が読めない・本文が
途中で切れる

実機報告 (Google のセキュリティ通知メール、スクリーンショット2枚 —
otegami と Spark の比較) から2件のバグを確定した。

### 1. ダークモードで文字が読めない

ライト前提 (白背景 + 濃色文字を明示指定) の HTML メールをダークモード
表示中に開くと、`HTMLDocumentBuilder.wrap(bodyHTML:)` の CSS リセット
(`background: transparent`) のおかげで背景は暗くなる一方、メールが
明示した濃グレー文字色 (`color: #3c4043` 等) はそのまま残り、暗地に
暗文字でほぼ読めなくなっていた。Spark/Gmail は同じメールを自動で明るい
文字色に変換して表示する。

修正: 古典的な「反転」手法 (NetNewsWire 等で使われる) を CSS だけで実装
した。`HTMLDocumentBuilder.mailDeclaresOwnDarkModeSupport(html:)` が
メール自身の `<meta name="color-scheme">` / `prefers-color-scheme` メディア
クエリの有無を判定し (プレーンな大文字小文字無視の部分文字列探索 —
`stripHTMLComments(from:)` と同じ現実的な割り切り)、メールが自前の
ダークモード対応を**持たない**場合に限り、`wrap(bodyHTML:
autoAdjustColorsInDarkMode:)` が `@media (prefers-color-scheme: dark)`
の中だけで本文ラッパ (`#otegami-fit-inner`) に `filter: invert(1)
hue-rotate(180deg)` を適用する — 白背景→暗背景・濃文字→明文字になり、
ブランドカラーも (色相環上で180度回転するだけなので) 概ね保たれる。
`img`/`picture`/`video`と、インライン `style` に `background-image` を
持つ要素には同じフィルタをもう一度適用して打ち消す (二重反転で元の色に
戻る) — 写真・ロゴが不自然に色反転しないようにするため。

**Swift 側からダーク/ライトの判定を渡さない設計**: このアプリはアプリ
全体のテーマを明示的に上書きしておらず (システム設定に従うだけ)、
`:root { color-scheme: light dark; }` を既にこのファイルの CSS リセット
に持っているため、`WKWebView` 自身がホストアプリの実際の外観に応じて
`@media (prefers-color-scheme: dark)` を正しく評価してくれる。設定値
(次段落) だけを条件に、CSS を出すか出さないかを Swift 側で決めれば
十分だった。

設定「メールビューア」→「メールの表示 (HTML)」に「ダークモードで
メールの配色を自動調整」トグルを追加 (既定 **ON**、
`HTMLDisplaySettingsStore.autoAdjustColorsInDarkModeKey`)。
`ImageSettingsStore` の2キーと同じ理由 (`docs/settings.md` の該当節
参照) で `HTMLMessageView.init` が `UserDefaults.standard.bool
(forKey:)` を直接読む — `@AppStorage`では「初回読み取り時だけ default
引数が効く」ため、メールを開くたびに新しく作られる `HTMLMessageView`
インスタンスが常に最新の設定値を反映できない。

### 2. 本文が途中で切れる (罫線から下が描画されない)

同じメールで、水平罫線 (`<hr>`) から下の本文 (段落・CTA ボタン・
フッター) が描画されず、その位置で WebView の表示がそのまま終わって
いた — fit-to-width (`HTMLWebViewCoordinator.fitToWidthScript`) が
scale を適用するケースで `outer.style.height` を明示的なピクセル値に
固定するが、その計測がページの実際のレイアウトが確定する前に走って
しまうことがあり、あとから画像が読み込まれて本当の高さが伸びても
反映されないまま — ページ末尾が `#otegami-fit-outer` の `overflow:
hidden` の外に押し出されて見えなくなる。

**根本原因**: `WKNavigationDelegate.didFinish` (ページの `load` イベント)
は仕様上「参照されている画像も読み込み終わってから発火する」はずだが、
M8 の `CIDSchemeHandler` (`cid:` 画像解決) は `WKURLSchemeTask` 経由で
**非同期に** (添付テーブルの GRDB 検索、未ダウンロードなら IMAP 経由の
オンデマンド取得まで発生しうる) レスポンスを返す実装になっており、実機
ではこの非同期解決が `didFinish` の発火より遅れることがある。修正前は
「`didFinish` 直後に1回 + 0.3秒後にもう1回」という固定ウェイトの決め
打ちでこれをカバーしていたが、0.3秒より遅い画像解決 (低速回線・未
キャッシュの添付ダウンロード等) では両方とも間に合わない。さらに、この
ファイル自身の CSS リセット `img, video, table, iframe { max-width:
100% !important; height: auto !important; }` が `height: auto` で画像の
`height` 属性を上書きするため、**メール側が `width`/`height` 属性を明示
していても** ブラウザは実際に画像が読み込まれてアスペクト比が判明する
まで最終的な高さを計算できない — 「画像に寸法指定があれば高さは事前に
確定するはず」という前提が、このアプリ自身のリセットによって成立しない。

修正: `fitToWidthScript` を書き換え、`document.images` のうち
`complete === false` なもの全てについて `load`/`error` イベント (どちらで
あっても「この画像の分のレイアウトは確定した」ことを意味する) を実際に
待ってから測定・scale 適用するようにした — 画像1枚あたり4秒のタイム
アウト付き (ブロックされたリモート画像・失敗した `cid:` 解決が永久に
`load`/`error` のどちらも発火しないケースへの安全網)。`evaluateJavaScript`
の async 版 (Swift) はページが返した `Promise` の解決を実際に待つため、
JS 側を `Promise` を返す IIFE にするだけで Swift 側の呼び出しは変更不要
だった。`didFinish` 側の「0.3秒後にもう1回」という決め打ちの2回目呼び
出しは、根本原因を実際に閉じたことで大部分不要になったため削除し、
画像読み込み以外の層 (未使用だが将来の Web フォント等) 向けの薄い安全網
として1.5秒後の呼び出し1回だけ残した。

縮小が不要なケース (`naturalWidth <= viewportWidth`) では元々 `outer`
の高さを明示的に固定していない (auto のまま) ため、このケース自体は
今回のバグの対象ではなかった — 影響したのは scale が実際に適用される
固定幅系のメールのみ。

### 検証

`dev/mailstack/seed/fixtures/31-security-notice-dark-mode.eml` を新設 —
実機報告のスクリーンショットと同じ構造 (中央寄せの角丸カード、`cid:`
画像2枚 [ロゴ + アバター、いずれも `width`/`height` 属性明示]、白背景 +
濃色文字を明示指定 [自前のダークモード対応なし]、罫線、罫線の下に本文
2段落 + CTA ボタン、fit-to-width の scale パスを画像読み込みタイミングに
左右されず決定的に踏ませる `white-space: nowrap` の注記行)。
`OtegamiSecurityNoticeDarkModeUITests` で罫線より下の本文 (2段落 + CTA
ボタン + フッター) がアクセシビリティツリーに存在することを確認 —
`OtegamiFitToWidthUITests`/`OtegamiHTMLHeightUITests` と同じ「文字色
までは目視でしか確認できない」パターンなので、ダークモードの配色自体は
シミュレータでのスクリーンショット確認に委ねた
(`xcrun simctl ui booted appearance dark`)。`make test`/`make mac`/
`make ios` green。

## Task #51: Task #45 の反転が広すぎた退行 — 実測ベースの判定に変更

### 症状

実機報告: **色指定を一切持たないシンプルな HTML メール**をダークモードで
開くと、暗いグレー文字になりほぼ読めない。Task #45 で「メールが読めない」
を直したはずが、別の (色を何も指定していない) メールを新たに読めなく
していた。

### 原因

Task #45 の初版は、`HTMLDocumentBuilder.mailDeclaresOwnDarkModeSupport
(html:)` (`prefers-color-scheme`/`color-scheme` の有無を見るだけの静的な
文字列検査) が false を返す限り、**メールが実際にライト配色を描画して
いるかどうかに関わらず**常に `#otegami-fit-inner` へ `filter: invert(1)
hue-rotate(180deg)` を適用していた。

色指定を一切持たないメールは、そもそも `HTMLDocumentBuilder.wrap` 自身の
CSS リセット (`:root { color-scheme: light dark; } html, body { background:
transparent; color: CanvasText; }`) だけで、ダークモード中は WebKit が
`CanvasText` を自動的に明るい色へ解決し、正しく読めていた。そこへ無条件
の反転がかかると、その明るい文字色が暗い文字色へ逆変換されてしまい、
透明な (＝アプリのダーク背景がそのまま透ける) 背景の上でほぼ読めなく
なる — Task #45 が直した「白背景+濃色文字を明示指定したメール」とは
真逆の失敗モード。反転が実際に必要なのは「メールが明示的にライト配色
(明るい背景) を描画するよう指定している」場合だけで、「メールが何も
指定していない」場合はむしろ逆効果、というのが実機からの教訓。

### 修正: 静的判定 → 実測判定

`mailDeclaresOwnDarkModeSupport` による「メールが自前のダーク対応を
持っているか」の判定 (持っていれば無条件にスキップ) はそのまま維持しつつ、
その判定を通過したメールに対して**常に反転する**のをやめ、**ページ
読み込み後に JS で実際の見た目を測定してから決める**方式に変更した。

- `HTMLDocumentBuilder.wrap(bodyHTML:autoAdjustColorsInDarkMode:)` は
  「反転を検討してよいか」(`autoAdjustColorsInDarkMode` が true、かつ
  `mailDeclaresOwnDarkModeSupport` が false) だけを判定する。検討して
  よい場合に限り、`@media (prefers-color-scheme: dark)` の中で
  `.otegami-invert-for-dark` クラスに対して `filter: invert(...)` を
  適用する CSS と、`#otegami-fit-outer` への `data-otegami-invert-check`
  属性 (JS 側が実測してよい対象であることの目印) を仕込む。この時点では
  実際にそのクラスを付けるかどうかまでは決めない。
- 実際に invert するかどうかの最終判断は
  `HTMLWebViewCoordinator.fitToWidthScript` (fit-to-width の画像読み込み
  待ち — `waitForImages()` — が終わった直後) が行う。`document.body` →
  `#otegami-fit-inner` → 本文中で最大面積を占める背景要素、の優先順で
  最初に見つかった不透明な `background-color` を実効背景とみなし、その
  WCAG 相対輝度が 0.5 を超える (＝明るい背景) 場合に限り
  `.otegami-invert-for-dark` クラスを `#otegami-fit-inner` へ付与する。
  代表的なテキストノード数点の `color` も測定し、背景より明らかに暗い
  ことを軽い裏付けとして使う (テキスト測定が不能な場合は背景の輝度
  だけで判定する)。**背景が最後まで不透明な値として確定しない (＝色
  指定を一切持たないメール) 場合は何もしない** — これが安全側のデフォ
  ルトで、今回の退行ケースを直す。
  - `document.body` を最初に見るのは、`HTMLDocumentBuilder
    .extractHeadStyles` が元メールの `<style>` ブロックをそのまま
    このファイル自身の `<head>` へ差し込んでいるため — 元メールが
    よく書く `body { background-color: ...; }` という CSS セレクタは、
    元の `<body ...>` タグそのもの (属性は `extractBodyContent` の
    仕様上失われる) ではなく、**このラッパーが作る実際の `<body>`
    タグ**にそのまま効く。多くのマーケティング/通知テンプレートが
    ページ全体の背景をこの `body {...}` セレクタで指定するパターンを、
    追加の仕掛けなしに拾える。
  - `filter` は視覚的なペイント効果であり、`scrollWidth`/`scrollHeight`
    などのレイアウト計測には影響しない — fit-to-width の高さ確定
    (`fit()`) の前後どちらでこの判定を挟んでも安全 (実装は
    `waitForImages()` の直後、`fit()` の直前に置いている)。
  - 実測は `didFinish` 直後・1.5秒後の遅延呼び出し・1i (HTML レイアウト
    保持翻訳) の再適用、のどの呼び出し経路からも同じ1本のスクリプトが
    自己完結して実行する — Swift 側の状態を別途持ち回る必要はない
    (`data-otegami-invert-check` 属性が DOM 自身に判定条件を保持して
    いるため)。

### 既知の制約

- 元メールが `<body bgcolor="#fff">`/`<body style="background:#fff">`
  のように**タグの属性やインライン style だけ**で背景を指定していて、
  かつ `<style>` セレクタ経由の指定を一切持たない場合、その情報は
  `HTMLDocumentBuilder.extractBodyContent` の時点で (`<body ...>` タグ
  そのものを読み捨てる既存の仕様により) 失われる。本文中の他の要素
  (テーブルの `bgcolor`、`div` の `style` 等) が実効背景として拾える
  ケースは「最大面積の背景要素」の探索でカバーされるが、拾えない場合は
  「背景が確定しない」側に倒れて無変換になる — 誤って読めなくするより
  安全な方向の割り切り。
- OS のダーク/ライト切り替えをアプリ起動中にリアルタイムには追従しない
  (実測は `didFinish` 等の限られたタイミングでしか走らない) — 既存の
  fit-to-width 自体も同じ制約を持っており、この機能固有の新しい制約では
  ない。
- 輝度の閾値 (0.5) はチューニング可能な値であり、絶対的な基準ではない。

### 検証

`dev/mailstack/seed/fixtures/32-plain-html-no-colors.eml` を新設 (今回の
退行ケース — 背景色・文字色を一切指定しない、最も単純な HTML メール)。
`AppEnvironment.uitestFakeHTMLMessages` (`OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE`
経由) にも同内容と、自前の `prefers-color-scheme` 対応を宣言するメール
(既存の反転スキップ条件が実測より優先されることの確認用) を追加し、
`OtegamiSecurityNoticeDarkModeUITests` が3ケースすべてを開いて
スクリーンショットを撮る:

- a. 色指定なしのシンプルメール (新規、今回の退行ケース) →
  ダークモードで反転なし・明るい文字で読める。
- b. 白背景+濃色文字を明示指定 (既存の `31-security-notice-dark-mode.eml`) →
  ダークモードで反転がかかり読める (Task #45 の成果を維持)。
- c. 自前のダークモード対応 (`prefers-color-scheme`) を宣言済み →
  ライト・ダークどちらでも無変換 (メール自身の配色のまま)。

ライトモードでは a/b/c すべて従来通り (このパスは `@media
(prefers-color-scheme: dark)` の外なので元々無関係)。`make test`/
`make mac`/`make ios` green。

## Task #53: スワイプの滑らかさ改善 (79aca4b) が引き起こした退行 — ショート距離でロングのアイコン/色が出る

### 症状

実機報告: しきい値 (`shortSwipeThreshold` 72pt / `longSwipeThreshold`
152pt) のうち**ショート**の距離までしか指を動かしていないのに、
リリース後にロングスワイプ用のアイコン・色がプレビューに一瞬出る。
「しきい値で自動実行」節・「スワイプの滑らかさ改善」節でこの2段階
UI を作り込んだ直後の退行。

### 原因

「スワイプの滑らかさ改善」節の `commitRemoval(action:direction:)` は、
アーカイブ・削除・迷惑メールをコミットした際に `dragTranslation` を
`0` へ戻すのではなく、行自身の幅 + 余白ぶん (`Self.exitOvershoot`)
さらに同方向へスプリングでスライドさせて完全に画面外へ出す — この
値は例えば行幅380pt程度なら「ショートスワイプ (80pt) の直後」でも
最終的に460pt前後まで動く。

`MessageListRow.swift` はこの `dragTranslation` を**単一の状態**として
2つの目的に使い回していた: (1) 行の表示位置 (`rowButton.offset(x:
dragTranslation)`)、(2) プレビューの色/アイコン判定
(`swipeActionBackground` が `reveal(for: dragTranslation)` を直接
評価)。(2) はコミット後もこの同じ値を毎フレーム再評価し続けるため、
退出スライド中に `dragTranslation` が `longSwipeThreshold` (152pt) を
通過した瞬間、実際のスワイプ距離とは無関係にプレビューがロング用の
アイコン・色へ切り替わってしまう — スワイプ距離自体が過大化したわけ
ではなく、「退出アニメーション用に人為的に伸ばした表示位置」を
しきい値判定にも使い回していたことが原因。

### 修正

`apps/Otegami/Sources/Features/MessageList/MessageListRow.swift` に
`armedReveal` (`@State`) を新設し、「プレビューに表示するアクション」を
「行の表示位置 (`dragTranslation`)」から完全に切り離した:

- `armedReveal` への書き込みは常に**生のジェスチャー値**からのみ行う —
  `swipeGesture.onChanged` は `value.translation.width` から、
  `commitSwipe(translation:)` はリリース時の最終 `translation.width`
  から、それぞれ `reveal(for:)` を再評価して書き込む。
- コミット後 (`commitRemoval` の退出スライド中) は `armedReveal` を
  一切更新しない — `dragTranslation` がどれだけ `longSwipeThreshold` を
  超えて動いても、プレビューはコミット時点で確定したアクションのまま
  固定される。
- `swipeActionBackground` は `reveal(for: dragTranslation)` の代わりに
  `armedReveal` を直接 switch する。
- `armedReveal` を `.none` へ戻すタイミングは、行が完全に静止状態へ戻る
  瞬間に揃えた: キャンセル (`cancelSwipe()`) は `withAnimation(_:
  completion:)` のコールバックで、スプリングが視覚的に収まった後に
  `.none` へ戻す (即座に `.none` にすると、指を離した瞬間に色付き背景
  だけ先に消えて行の視覚的な戻りと分離して見える退行を防ぐため)。
  `commitRemoval` の `perform(action)` が実際には行を消せなかった
  フォールバック (`dragTranslation = 0` で行を復帰させる分岐) と、
  選択モード突入時のリセット (`onChange(of: isSelecting)`) にも同様に
  `armedReveal = .none` を追加した。

### 検証

`make test`/`make ios`/`make mac` green。境界前後 (72pt 付近・152pt
付近・コミット後の退出スライド中) の挙動はコード上で確認済み — 実機
シミュレータでの目視確認 (スクリーンショット/録画) は
`.claude/skills/verify/SKILL.md` の手順に沿って別途実施し、結果を
ここに追記する。

## Task #55: 要約/翻訳バーの廃止 → 左下フローティングボタン2個

### 背景

メール本文画面は「AI要約バー」「翻訳バー」がヘッダ直下に常時2行を占有
していた — どちらのバーも条件を満たすメッセージなら常に表示され
(要約は AI 機能設定オンなら言語問わず全メッセージ、翻訳は
`shouldShowTranslationBar` を満たす英文メールのみ)、ユーザーが一度も
触れなくても画面の縦スペースを恒常的に消費していた。既存のフローティング
ボタン (`MailScreenView.floatingSearchButton`検索ボタン、`FolderListSheet
.floatingSettingsButton`設定ボタン) と同じ「一覧のスクロール位置に関係
なく常に同じ場所にある」流儀に揃え、この2つのバーを左下フローティング
ボタン2個 (縦積み、要約が上・翻訳が下) に置き換えた。

### タップ後の見せ方: 要約はシート、翻訳はボタン自身がトグルに

バーには「見出し + 状態に応じたボタン/セグメント + 結果」を並べる横幅
があったが、フローティングボタン1個にはその余地が無い。2つの機能は
「結果をどう見せるか」の性質が違うため、それぞれ別の解決策を選んだ:

- **AI要約 (`AISummaryFloatingButton`)**: 結果は本文とは独立した読み物
  (原文と並べて見比べる必要は薄い) なので、タップで下からシート
  (`MessageView.summarySheet`、`.presentationDetents([.medium, .large])`)
  を開いて見せる。未生成ならシートを開くと同時に生成を開始し (シート内は
  生成中 `ProgressView`)、生成済みなら即座に結果を表示。「再生成」は
  シート内のツールバーボタンとして残した — バーの「要約」/「再生成」の
  2ボタン切替をシートの中に押し込めた形。
- **翻訳 (`TranslationFloatingButton`)**: 結果は本文そのものに適用される
  (`content`の`htmlTranslatedTexts`/`TranslatedBodyView`分岐、既存のまま
  無変更) ため、シートで別画面に出す意味が無い。旧バーの「訳文/原文」
  `Picker(.segmented)`が担っていた切替を、ボタン自身の**トグル**に
  変更した — 翻訳済みなら、タップのたびに`translationShowOriginal`が
  反転し、本文の表示が訳文⇄原文で切り替わる。ボタンの色 (アイコン背景が
  塗り潰し `.active` か、枠線のみ `.neutral` か) で「今どちらを表示中か」
  を示す (`OtegamiFloatingButtonTone`のdoc comment参照)。

### 状態の表現: 塗り潰し/枠線/赤枠の3トーン + ProgressView

`AISummaryFloatingButton`/`TranslationFloatingButton`はどちらも同じ4状態
(未生成/生成中/生成済み/失敗) を持つ (`MessageSummaryState`/
`MessageTranslationState`)。バー時代はテキストラベルで状態を説明できたが、
アイコン1個のボタンにはその余地が無いため、`OtegamiFloatingButtonTone`
(`.neutral`/`.active`/`.attention`/`.disabled`) という共有の見た目語彙に
還元した:

- **生成中**: アイコンの代わりに`ProgressView` (要件「進行中はボタンに
  ProgressView」)。
- **未生成/生成済み(翻訳が原文表示中)**: `.neutral` — 検索/設定ボタンと
  同じ見た目 (surface塗り + accentアイコン)。
- **生成済み(要約はシートを開ける状態、翻訳は訳文を表示中)**: `.active` —
  accent色で塗り潰し、白アイコン。「タップすると何か見られる/切り替わる」
  を示す。
- **失敗**: `.attention` — destructive色の枠線+アイコン (塗り潰さない、
  `.active`の「成功」感と混同しないため)。タップで再試行 (旧「再試行」
  ボタンと同じ一発リトライ)。
- **この端末では利用不可** (`isAvailable == false`): `.disabled` — ボタン
  自体は消さず (存在に気付けるように)、`.disabled(true)`+アイコンを
  `inkTertiary`に沈める。VoiceOverには理由を`accessibilityLabel`で伝える。

この`OtegamiFloatingButtonTone`と円形ボタンのクロム (surface塗り+
`dividerSubtle`枠線+ドロップシャドウ) は`AISummaryBar.swift`に集約し、
`TranslationBar.swift`から再利用している。既存の`floatingSearchButton`/
`floatingSettingsButton`は今回のバッチでは触っていない (別エージェントが
同じ作業ツリーで`MailScreenView.swift`を並行編集中だったため) — 3箇所
目の重複になるが、既存2箇所を巻き込んだ共通コンポーネント化は今回の
スコープ外と判断した (`OtegamiFloatingButtonTone`のdoc comment参照)。

### 失敗時のフィードバック: 翻訳はキャプション、要約はシート内

翻訳の失敗メッセージ (旧バーの`footnote`) は、シートを持たないボタンの
すぐ上に赤いカプセル型キャプションとして表示する
(`TranslationFloatingButton.footnoteCaption`) — VoiceOverだけでなく晴眼
ユーザーにも見える形を残した。要約の失敗メッセージは元々シートの中に
表示先があるため、追加のキャプションは置いていない (シートを開けば
失敗理由が読める)。

### 本文とフローティングボタンの重なり回避

`content`のプレーンテキスト`ScrollView`と`TranslatedBodyView`(自前の
`ScrollView`) の両方に、フローティングボタン2個分の高さを見積もった
固定値 (`MessageView.floatingButtonsReservedBottomInset`) を
`.contentMargins(.bottom:, for: .scrollContent)`で確保した —
`FolderListSheet`が自分の`floatingSettingsButton`のために既にやっている
のと同じパターン。**`HTMLMessageView`(`WKWebView`) は当初対象外** —
同じ作業ツリーで別エージェントがその実装をダーク反転修正のため並行編集中
だったため触っておらず、HTML本文はフローティングボタンがスクロール後の
本文に重なりうる既知の制約として残っていた。Task #56 でこの制約を解消
した (下記「Task #56」節参照)。

### 検証

`make test`/`make ios`/`make mac` green。既存の`OtegamiTranslationBarUITests`
(`OtegamiTranslationUITests.swift`) を新 UI に追随させた — 旧バーの
固定見出しテキスト("…端末内で翻訳")・`訳文`セグメントラベルへの依存を、
`translationFloatingButton`系のaccessibilityIdentifier/ボタンの
accessibilityLabel (未翻訳時は"翻訳"を含む、翻訳済みは"戻す"を含む) への
依存に置き換えた。実機シミュレータでの目視確認 (スクリーンショット) は
`.claude/skills/verify/SKILL.md`の手順に沿って別途実施し、結果をここに
追記する。

## Task #56: HTMLメール表示の総仕上げ4点 (TestFlight風通知メールの実機報告)

実機報告 (TestFlight のビルド通知メール、otegami と Spark の比較
スクリーンショット2枚) から4件のバグを確定した — 背景色を指定しない
まま文字色だけ明示指定するメール、`width`属性+インライン`style`の
「レスポンシブだが上限あり」画像手法など、Task #45/#51 の対象
(31/32番フィクスチャ) には無かった新しい組み合わせが原因。

### 1. 画像の巨大化禁止

**症状**: 中央の ~120px アプリアイコン画像が画面幅いっぱいに引き伸ば
されて表示される (Spark は自然サイズのまま)。

**原因の特定**: 憶測で直さず、まず `HTMLDocumentBuilder.wrap` が出す
CSS リセットだけを抜き出したオフスクリーン `WKWebView` (Swift script、
`swift <file>.swift` で単体実行) を用意し、複数の候補となる著者側
マークアップ (`width`属性のみ/`width`属性なしのcid画像/`width:100%`+
`max-width:120px`のインラインstyleを併用する「レスポンシブだが上限
あり」手法、Litmus/Email on Acid 等が推奨し ESP テンプレートで頻出/
著者`<style>`ブロックで`img{width:100%!important}`を仕込むケース、等)
を実測したところ、「`width`属性 + `style="width:100%;
max-width:120px;"`」の組み合わせだけが確実に画面幅いっぱいまで拡大
された。

根本原因はこのファイル自身の CSS リセットの二重の見落とし:
1. `* { max-width: 100% !important; box-sizing: border-box; }`
   (全要素向け) と `img, video, table, iframe { max-width: 100%
   !important; ... }` (img含む個別) の両方が `img` にも `!important`
   で `max-width: 100%` を強制していた。CSS のカスケードでは
   `!important` 同士は詳細度を問わず勝つため、著者がインライン
   `style="max-width:120px"` (非`!important`) で明示した、より小さい
   上限をこの2つの `!important` ルールが問答無用で上書きしていた。
   結果、著者の意図した「上限120px」が消え、著者自身も併記していた
   `width:100%` (フルード化) だけが有効になり、コンテナ幅いっぱいまで
   拡大された。
2. 著者が `width`/`style`の`width`を一切指定しない画像 (稀だが著者側
   `<style>`ブロックの汎用リセットが影響しうる) を自然サイズのまま
   描画する仕組みがそもそも無かった。

**修正** (`HTMLMessageView.swift`、`HTMLDocumentBuilder.wrap`内の
`<style>`):
- `img`をブランケットの`* { max-width: 100% !important; }`の対象から
  除外 (`*:not(img)`)。
- `img`向けの上限は「著者がインライン`style`に自前の`max-width`を
  持たない画像だけ」`!important`で100%上限をかけ
  (`img:not([style*="max-width" i])`)、自前の`max-width`を持つ画像には
  非`!important`のフォールバック上限だけを与える
  (`img[style*="max-width" i] { max-width: 100%; }`) — CSSの詳細度
  (インライン`style`が最優先) により著者側のより小さい値が自然に勝つ。
- `width`属性もインライン`style`の`width`も持たない画像は常に自然
  サイズ (`width: auto !important`) で描画する
  (`img:not([width]):not([style*="width" i])`)。
- 著者が`max-width`を極端に大きく指定していた場合でも、ページ全体の
  fit-to-width (`HTMLWebViewCoordinator.fitToWidthScript`) がページ
  全体を縮小する既存の安全網としてなお機能する (29/30番フィクスチャの
  固定幅テーブル対策と同じ考え方) — 個々の画像を完全に取りこぼしなく
  抑え込む必要はない。

再現・修正確認は WKWebView 単体実行スクリプトで行った (A: width属性
のみ→120px、B: フルード+max-width併用→修正前366px/修正後120px、
C: 指定なし→自然サイズ、G: width=900の広い画像→100%上限で正しく
縮小、いずれも regression なし)。

### 2. 背景なし + 濃色文字メールの可読化

**症状**: 背景色を一切指定せず、文字色だけ `#444` 系で明示指定した
メールがダークモードで暗地に暗文字になり読めない。Task #51 の判定
(`decideDarkInversion`) は「実効背景が不透明に解決した場合のみ」反転を
検討する設計だったため、背景が最後まで解決しない (＝透明) メールは
無条件で「反転しない」に倒れていた — 32番フィクスチャ (色指定なし)
のような「本当に無指定で `CanvasText` に任せてよいメール」と、
このケース (「背景は無指定だが文字色だけ明示的に暗い」メール) を
区別できていなかった。

**方式選定**: 2案を比較検討した。
- (a) 背景が解決しない場合も、実測した文字輝度が低ければ既存の
  `.otegami-invert-for-dark` クラスをそのまま適用する。
- (b) 反転はかけず、`color` 等のテキスト系プロパティだけを CSS で
  明色に上書きする。

(a) を採用した。理由:
- 背景が透明なままの要素に `filter: invert(1)` をかけても、CSS
  Filter Effects の仕様上アルファチャンネルは反転の対象にならない
  (透明は反転しても透明のまま) — 見た目への影響はテキスト色 (と、
  既存の二重反転補正が効く img/video) にしか出ない。実測でも
  確認済み (`getComputedStyle` で透明ピクセルに副作用が出ないこと)。
- (b) は反転で自動的に得られる「テキストだけでなくボーダー・
  アクセントカラーなども込みで概ね妥当な配色になる」効果を失い、
  `color` 以外のプロパティ (`border-color` 等) は個別に手当てが要る
  — 実装・保守コストが (a) より高い割に、31/32番フィクスチャが
  既に検証済みの反転パスをそのまま再利用できる (a) ほど枯れていない。

**判定の鍵**: `color: CanvasText` (このファイル自身のCSSリセット、
文字色未指定のメールが暗黙に使う値) は、ダークモード中は WebKit が
既に明るい色へ自動解決している。一方、著者が明示的に指定した暗い
文字色 (`#444` 等) は外観に関係なく指定値のまま変わらない。
`getComputedStyle(...).color` を実測すれば、この2ケースは輝度の
実測値だけで区別できる (WKWebView単体実行スクリプトで実測:
ダークモード中の`color: CanvasText`の輝度は1.0、`#444`は0.058) —
「文字色を明示指定していないメールかどうか」を別途覚えておく仕組みは
不要で、32番フィクスチャの retention (無変換のまま) は実測ロジック
だけで自然に保たれる。

**修正**: `HTMLWebViewCoordinator.fitToWidthScript`の`decideDarkInversion`
に、背景が解決しなかった場合の分岐を追加 — 代表的なテキストノードの
輝度を実測し、0.5 未満 (暗い) なら `.otegami-invert-for-dark` を付与する。

### 3. 高さ切れの再確認

1の画像サイズ修正後、fit-to-width の高さ計測 (`fitToWidthScript`の
`waitForImages()`→`fit()`) が正しく機能することを新フィクスチャ
(33番、後述) で再確認した。33番フィクスチャは罫線を持たないぶん
31番より単純だが、複数段落+フッターまで本文全体が最後まで欠けずに
描画されることを機械的に確認する `OtegamiSecurityNoticeDarkModeUITests
.testBetaTestingNoticeRendersFullyWithoutOverlap` を追加した。切れる
別の根本原因は見つからなかった (1の修正が唯一の原因だった)。

### 4. フローティングボタンの本文被り解消

Task #55 (要約/翻訳フローティングボタン) 実装時点では、プレーンテキスト
側の2ブランチ (`ScrollView`/`TranslatedBodyView`) だけが
`.contentMargins(.bottom:, for: .scrollContent)` で
`floatingButtonsReservedBottomInset` 分の余白を確保しており、
`HTMLMessageView`(`WKWebView`) は「別エージェントが並行編集中だった
ため対象外」という既知の制約として残っていた (design-phase-3節参照)。

**修正**: `HTMLMessageView`に`bottomContentInset: CGFloat`パラメータを
追加し、`MessageView`から`floatingButtonsReservedBottomInset`と同じ値を
渡す。`WKWebView`側の`scrollView.contentInset`(iOS)は使わず —
`WKWebView`はmacOSでは`UIScrollView`を持たないため iOS/macOS 共通の
コードにならない — 代わりに`HTMLDocumentBuilder.wrap`が読み込む文書
自体の末尾 (`#otegami-fit-outer`の*兄弟*として`body`直下) に、その
高さ分の空`<div>` (spacer) を注入する方式にした。`#otegami-fit-outer`の
*外*に置くことで、fit-to-widthのスケール計算 (`#otegami-fit-inner`の
`scrollWidth`/`scrollHeight`だけを見る) と一切干渉しない。

### フィクスチャ33・検証

`dev/mailstack/seed/fixtures/33-beta-testing-notice.eml` (+
`AppEnvironment.uitestFakeHTMLMessages`への同内容の追加、
`OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE`経路): 背景色なし・`#444`系の
文字色を明示指定・中央120pxのcid画像 (`width`属性+`style="width:100%;
max-width:120px;"`)・リンク数本・複数段落、というTask #56の再現構造。
`OtegamiSecurityNoticeDarkModeUITests.testBetaTestingNoticeRendersFullyWithoutOverlap`
が本文の冒頭・中盤・末尾の存在 (3の回帰確認) を機械的に確認し、
スクリーンショットを撮る。31/32番フィクスチャの既存挙動 (32番が
無変換のまま) も同じテストファイル内の既存テストで retention 確認済み。

`make test`/`make mac`/`make ios` green。

**実機シミュレータでの検証状況**: `OtegamiSecurityNoticeDarkModeUITests`
の既存3メソッド (このバッチの変更を一切受けていない) も含め、この
シミュレータ/ツールチェーンで `messageList.list` の行タップが
`htmlWebView never appeared` で失敗する既知の環境問題
(このファイル冒頭のdoc comment) に阻まれ、XCUITest 経由の自動
スクリーンショット撮影は安定しなかった。「UITest の直接遷移経路」
フォールバックとして `AppEnvironment.uitestDirectOpenThreadId`
(`OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX`) を追加し、タップを
経由せず`selectedThreadId`を直接セットして本文へ遷移する経路を
実装 — `xcrun simctl launch`からの手動起動 (`SIMCTL_CHILD_*`環境変数
経由) では実際にこの経路で本文詳細への遷移に成功することを確認した
(スクリーンショットで本文冒頭・段落・フッターの存在を確認)。ただし
同じ経路を `XCUITest` プロセス内から使うと、今度は端末側の
「連絡先へのアクセスを許可」システムダイアログ (差出人アバター解決が
トリガー) が非決定的なタイミングで表示され、`dismissContactsPermissionPromptIfNeeded`
の複数回リトライおよび `simctl privacy grant contacts` による事前許可
のどちらでも確実には解消できず、最終的な自動スクリーンショット取得は
今回の作業時間内には安定させられなかった。

**やったこと/できなかったことの切り分け**:
- 1 (画像巨大化禁止) と 2 (背景なし+濃色文字可読化) は、実際の
  `WKWebView`/実際のCSSカスケード規則に対する単体実行スクリプトでの
  実測により、修正前後の挙動を数値で比較検証済み (上記各節参照) —
  実機シミュレータのスクリーンショットに頼らない、確度の高い検証。
- 4 (フローティングボタン被り) は、fit-to-widthのスケール計算対象
  (`#otegami-fit-inner`) の外にDOM要素を追加するだけの変更で、
  スケール計算と無関係であることをコードレビューで確認 — 視覚的な
  「被らない」ことそのものの実機確認は今回できていない。
- 3 (高さ切れ) は、1の画像修正 (誤って拡大された画像がfit-to-widthの
  `scrollHeight`計測を狂わせていた可能性) が根本原因だったと考えられる
  ことをコードパス上で確認したが、修正後に本文が最後まで実際に描画
  されることの実機/シミュレータでのスクリーンショット確認は今回
  できていない (`xcrun simctl launch`での手動確認では本文の複数段落
  ・フッターまでアクセシビリティツリー上で読めることを確認できたが、
  ダイアログに阻まれクリーンなスクリーンショットは撮れなかった)。

残作業: このシミュレータ/ツールチェーンでの連絡先許可ダイアログの
非決定的タイミング問題の解消 (`simctl privacy grant`が期待通りに
効かない原因調査を含む)、または `screenshotCurrentScreen`側の
リトライ/タイムアウト延長。

**Task #56 の「3 (高さ切れ)」は根治できていなかった** — 上記のとおり
Task #56 では画像巨大化バグの修正 (1) が原因だったと"推測"しただけで、
実際に本文が最後まで描画されることを見て確認していなかった。実機
(TestFlight通知メール) では色・画像サイズは直った一方で、本文が文の
途中で水平にスパッと切れ、その下がずっと空白のまま — というユーザー
報告が続き、Task #58 として根治した。詳細は以下。

## Task #58: HTMLメール本文の高さ切れの根治

### 再現

`OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE` + `OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=3`
(33番=TestFlight通知型フィクスチャ) を `xcrun simctl launch` の
`SIMCTL_CHILD_*` 環境変数経由で直接起動し (XCUITestのタップ経由では
連絡先/通知許可ダイアログのタイミングが非決定的なため、`simctl`直叩き
+ 各ダイアログを都度 `simctl privacy grant`/待機でかわす方式に変更)、
`xcrun simctl io booted screenshot` で撮影して再現した。症状は実機報告
と一致: 本文が「To learn more about installation, testing...」の段落
途中で切れ、その下はフッターツールバーまで空白。

### 根本原因

`HTMLMessageView`のdoc comment (冒頭) が明言していた設計: 「HTML本文は
`WKWebView`内部でスクロールする — SwiftUI側で計測して外側の`ScrollView`
に合わせるのではなく、`MessageView`がヘッダの下の残りスペースをそのまま
渡す」。この設計は**単体では正しいが、`ThreadDetailView`が実際には
`MessageView`を外側の`ScrollView`(スレッド全体を縦列挙するアコーディオン)
の中に、かつ`.frame(height: expandedHeight)`で固定した箱に入れて埋め込む
という2つの制約を後から重ねていた**ことと矛盾していた:

1. `ThreadDetailView.expandedMessageHeight(in:)`が
   `max(360, containerSize.height - 160)`という**固定の高さ予算**を
   `MessageView`(→`HTMLMessageView`→`WKWebView`)に強制していた。
   計装ログ (`os.Logger`, category `HTMLHeightDiagnostic`) の実測:
   `containerSize=(440.0, 738.0) → height=578.0`。
2. `fitToWidthScript`(`HTMLWebViewCoordinator`)を計装し、
   `#otegami-fit-outer`のJSON診断値をDOM属性経由で読み出したところ
   (`evaluateJavaScript`がPromiseの解決値をこのツールチェーンでは
   一切ブリッジできない — closure版・async版どちらも
   `WKErrorDomain Code=5 "unsupported type"` — という別の実測済みの
   不具合があり、通常の戻り値では読めなかったため、いったんDOM属性に
   書き込んでから改めて同期スクリプトで読み直す形にした)、実測値は:
   `naturalHeight=516`, `outer.scrollHeight=516`, かつ
   `document.body.scrollHeight=668`(`#otegami-bottom-inset-spacer`込み)。
   一方 実際にSwiftUIが`WKWebView`へ与えていたフレームは
   `webView.bounds=(0, 0, 440, 510.67)` — **本文そのもの (516pt) より
   even shorter**。
3. `WKWebView`は本来この差分を自分の内部`UIScrollView`でスクロール
   できるはずだが、`ThreadDetailView`の外側`ScrollView`に入れ子に
   なっているため、この環境ではパン・ジェスチャーが常に外側の
   `ScrollView`に取られ、`WKWebView`内部のスクロールへ実質的に届か
   ない — 「正しく計測されているのに何も理由なく描画が止まる」ように
   見えた原因。Task #45/#56で2度「直したはず」なのに実機で再発した
   のは、どちらの回もこの**固定フレーム予算 + 二重スクロール入れ子**
   という構造そのものには手を付けず、`fitToWidthScript`側の計測条件
   (画像待ち・拡大禁止) だけを直していたため。

### 修正

1. **実測した本文高さをSwiftUI側へ伝播する**: `fitToWidthScript`の
   `fit()`実行後に`document.documentElement.scrollHeight`/
   `document.body.scrollHeight`の大きい方 (= `#otegami-bottom-inset-
   spacer`込みの実際の全高) を`WKScriptMessageHandler`
   (`otegamiHeight`、`evaluateJavaScript`の戻り値ブリッジ不具合とは
   別経路なので影響を受けない) 経由でSwiftへ通知。後続のレイアウト
   変化 (1iの翻訳オーバーレイでの再フロー等) も拾えるよう
   `ResizeObserver`も併設。
2. **`HTMLWebViewCoordinator` → `HTMLWebViewRepresentable` →
   `HTMLMessageView` → `MessageView` → `ThreadMessageRow`**まで
   `onHeightChange`コールバックを貫通させ、`ThreadMessageRow`が
   `expandedHeight`固定値の代わりに
   `max(expandedHeight, measuredHTMLContentHeight + 180pt推定シェブロン)`
   を`MessageView`へ渡すよう変更 (`180pt`はヘッダ/添付/罫線の見積り —
   `floatingButtonsReservedBottomInset`と同じ「厳密でなくてよい、
   多めに見積もって安全側に倒す」方針)。これで固定予算より本文が長い
   メールでは行自体が伸び、外側`ScrollView`がその分スクロールできる
   ようになる。
3. **`WKWebView`自身の内部スクロールを無効化** (`webView.scrollView
   .isScrollEnabled = false`、iOS)。フレームが実コンテンツに一致する
   よう伸びるようになった以上、二重スクロール入れ子を維持する理由が
   ない — スクロール主体を外側`ScrollView`ひとつに統一し、ジェス
   チャー競合の可能性自体を構造的に消す。
4. 計装用の`os.Logger`(`HTMLHeightDiagnostic`)はそのまま残した —
   実機での追加切り分けに使えるため。

**macOS**: `ThreadDetailView`はiOS/macOS共通コードで同じ入れ子構造を
持つため理論上は同じ修正が有効なはずだが、`WKWebView`(macOS)には
`scrollView.isScrollEnabled`に相当する単純なプロパティがなく、今回は
`otegamiHeight`メッセージハンドラの登録のみ共通化して内部スクロール
無効化は見送った (`HTMLWebViewRepresentable.makeNSView`のコメント
参照) — macOSでの実機/実プレビュー確認は未実施。

**検証状況**: この修正は `make test`/`make ios`/`make mac` 緑まで確認
した。33番フィクスチャでの実機シミュレータ再現・計装ログでの数値
確認は上記のとおり完了しているが、**修正後の「最後まで描画される」
ことを同じ手順でスクリーンショット確認するところまでは、この回では
実施できていない** (作業時間の制約でOTA配信を優先) — 実機での
最終確認はユーザーに委ねる。
