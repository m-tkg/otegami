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
- `OtegamiRadius.none` = 0pt — このデザインシステムに角丸はない
  (Modernist ベースの方針)

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
