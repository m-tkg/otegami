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

## 次フェーズへの申し送り

- `OtegamiFont.registerCustomFontsIfNeeded()` をアプリ起動時に呼ぶ配線
  (`OtegamiApp.swift`/`AppEnvironment`)。
- `NOTICE` に Archivo の帰属表示を追記。
- 実際の画面 (Sidebar/MessageList/ThreadDetail/Composer など) への適用。
  このタスクではトークン・コンポーネントの用意のみで、既存 View は一切
  変更していない。
- 1a (統合受信トレイ) の実装時、`AccountFilterChip` の横スクロール行が
  アカウント5つ以上でどう振る舞うかの検討 (ハンドオフ側もリスクとして
  明記)。
