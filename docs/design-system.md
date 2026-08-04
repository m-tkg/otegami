# デザインシステムと UI 設計方針

Otegami (iOS/macOS メールクライアント) の UI 設計の現状をまとめたドキュ
メント。初めてこのリポジトリの UI に触るコントリビュータ向けに、**今
現在どうなっているか**だけを書く — 変更履歴・検討過程・実機フィード
バックの経緯は書かない (それらは `git log`/コミットメッセージで追える)。

デザイントークンの実体は `apps/Otegami/Sources/DesignSystem/`
(アプリ本体のターゲットに直接コンパイルされる通常の Swift ファイル群)。

**新しい色・余白・角丸を足したくなったら、まずこのファイルと
`OtegamiColor.swift`/`OtegamiSpacing.swift`/`OtegamiBorder.swift` を見る
こと。** UI コード側で生の `Color(hex:)`/`Color(red:green:blue:)` を書か
ない・新しいトークンをその場で追加しない — 必要な用途がまだ無ければ、
先にこのドキュメントの該当節に追記する形でトークンを足すかどうかを議論
してから使う。このルールは `CLAUDE.md` にも書かれている全社的な方針で、
このファイルはその実務上の詳細を持つ。

UI の構造 (情報設計・一覧レイアウト・操作モデル) は、初期のワイヤー
フレーム議論から採用した案 (1a/1d/1g+1h+1i、下記各節) がそのまま現在の
実装。実装時に参照するのはレイアウトと動線のみ — スタイル (色・タイポ・
余白・罫線) は本ドキュメントのトークンを使う。

## 情報設計 (画面構成)

- **iOS compact 幅 (iPhone 縦向きなど)**: 統合受信トレイ＋アカウント絞
  り込みチップ (1a)。常設画面は `MailScreenView` 1つで、ヘッダタイトル
  のプルダウン (`headerTitleMenu` — 受信トレイ/フラグ付き/アーカイブ/
  すべてのメール/送信済み/下書き/迷惑メール/ゴミ箱) がカテゴリ横断
  ビューの切替を担い、左上のハンバーガーボタンから
  `HamburgerMenuContainer` (leading-edge のサイドドロワー) が
  `FolderListSheet` の中身 (アカウント別メールボックスツリー／下書き／
  送信待ち／同期エラー／設定への入口) を開く。カテゴリ横断ビューは元々
  ハンバーガーメニュー内のセクションだったが、ヘッダタイトルのプルダウン
  へ導線を統合して削除した (2026-08-02、`FolderListSheet` の doc comment
  参照)。ヘッダの検索ボタンから `SearchScreenView` をシート表示する。
  **下部タブバー (メール/検索/設定の3つ) は廃止済み** — ヘッダタイトル
  メニュー・ハンバーガーメニュー・検索ボタンがその役割を引き継いだ。
- **iOS regular 幅 (iPad、iPhone の横向き Plus/Max など)**: `MailScreenView`
  が `@Environment(\.horizontalSizeClass)` で分岐し、`NavigationSplitView`
  による左=一覧・右=本文の2ペイン構成になる (3ペインにはならない)。ハン
  バーガードロワーは compact/regular どちらでも一覧+本文の全体に被さる
  オーバーレイとして動作する。
- **macOS**: 既存の `NavigationSplitView` 3ペイン (`SidebarView` / 一覧 /
  本文) を維持。iOS 側のレイアウト変更 (一覧のフルブリード化、iPad 2ペ
  イン化など) は macOS には適用しない。ウインドウサイズ・カラム幅の既定
  値と記憶の仕組みは Task #209 (下記「SwiftUI 実装上の落とし穴」6) 参照。
- **メール本文画面**: `ThreadDetailView` が本文表示を担当し、下部に
  `MessageDetailFooterToolbar` (`.safeAreaInset(edge: .bottom)`) を常設
  する。既定で表示される操作は 返信/転送/検索/情報/要約/翻訳 の6つ (7つ
  目の「その他」は常に末尾固定)。スレッド表示 (アコーディオン) が ON の
  ときは複数メッセージをアコーディオンで展開・折りたたみでき、対象は常
  にスレッド内の最新メッセージ (macOS の ⇧⌘R と同じ規則)。スレッド表示が
  OFF のときは単一メッセージのみを表示する。
- **アカウントダイジェスト**: 一覧ヘッダの「全部」チップを `Menu` で開き
  「時系列」/「アカウント別」を選べる。「アカウント別」を選ぶと、一覧と
  同じ場所にアカウントごとの集計行 (`AccountDigestView`/`AccountDigestRow`
  — 色罫線・表示名・未読/総数バッジ・直近プレビュー数行) がインライン
  表示に置き換わる (別画面へのプッシュ遷移ではない)。行タップでそのアカ
  ウントに絞り込む。macOS でも同じダイジェスト表示が使える (2026-08-02
  に追加 — `RootView` の一覧カラムが `AccountDigestPresentation` を見て
  `AccountDigestView` を埋め込む)。グループ表示中も
  `AccountDigestSearchBar` (専用の軽量検索欄) が出て、1文字入力すると
  時系列表示へ戻して `MacListSearchBar` にクエリを引き継ぐ。
- **設定のカテゴリ構成**: ハンバーガーメニューの「設定」→一般／アカウ
  ントの設定／メール一覧／メールビューア／メール作成の5カテゴリ + ルー
  ト直下の「このアプリについて」。「一般」(`GeneralSettingsView`) には
  iCloud 同期トグルとプッシュ通知への入口が入っている (プッシュ通知は
  Task #212 でアカウントの設定から移設、アカウント別の push watch 状態
  表示ごとそのまま移った)。各カテゴリの項目の詳細な対応表は
  `docs/settings.md` 参照。
- **確認を要するトグル** (Task #212): プッシュ通知の有効/無効は標準の
  `Toggle` 1つ (以前は「有効にする」/「無効にする」の別ボタンだった)。
  資格情報の送信を伴う ON 操作だけは `.alert` の同意確認を経由し、
  `Toggle`自身の`isOn`バインディングの`get`が常にモデルの実状態
  (`AppEnvironment.isPushEnabled`) をそのまま返すことで、キャンセル時に
  トグルを明示的に戻す処理を書かずに「確認するまで見た目も動かない」を
  実現している (`PushNotificationSettingsView.pushEnabledBinding`)。
  同種の「即時反映してよいトグル」と「確認を挟むべきトグル」を今後追加
  する際の判断・実装両方の参考実装。ピン留めの IMAP `\Flagged`との連動
  は同じ Task #212 で選択式トグルを撤去し、常時 ON の内部固定挙動にした
  (`docs/settings.md`の「ピン留め」節)。

## 一覧レイアウト

- 標準3行 (送信者/件名+プレビュー/時刻) ＋ アカウント色の左罫線3px
  (`AccountColorRail`、1d)。左罫線とアカウント名ラベルは、統合ビューを
  複数アカウントで見ているときだけ表示する (1アカウントしか無ければ冗
  長なので出さない)。
- **iOS**: 行はエッジツーエッジのフルブリード。`.listRowInsets` は `.zero`、
  角丸は `OtegamiRadius.none` (0)。行の区切りは1pt の破線ハイライン
  (`.otegamiRowDivider()`、`OtegamiColor.dividerSubtle`)。`List` には明
  示的に `.listStyle(.plain)` を指定する (指定しないと既定の `.automatic`
  スタイルが先頭/末尾の行だけ角を丸めてしまう)。
- **macOS**: 行はカード形状のまま — `OtegamiRadius.card` (8pt) の角丸＋
  塗り背景 (`otegamiCardBackground(_:)`、罫線ではなく `.clipShape` +
  背景色)、`.listRowInsets` に実マージンを持つ。iOS のフルブリード化は
  macOS には適用していない。
- アバターの背景 (画像・イニシャルいずれも共通) は固定の中間グレー
  (`OtegamiColor.avatarImageBackdrop`) — アカウント色は使わない。透過
  PNG のロゴがダーク系のアカウント色に溶け込む問題を避けるため。
- アーカイブ済みメールは一覧行末尾に小さな `archivebox` アイコンを表示
  する。アーカイブビュー (アーカイブフォルダ/Gmail の全メール/統合アー
  カイブ) を見ているときは、スワイプ/右クリックメニューのアーカイブ操
  作が自動的に「アーカイブ解除」に切り替わる。
- 日付表示 (`OtegamiDateFormat.listRowText`) は一覧行・スレッド内メッ
  セージ行で共通: 当日は時刻のみ、当年内は月日+時刻、それ以前は年+月日
  +時刻。

## 操作モデル

- **スワイプ操作** (1g): `.swipeActions` ではなく独自の `DragGesture` 実
  装 (`MessageListRow`) — `.swipeActions` はグループ内の最初の1つしかフ
  ルスワイプで自動発火できない制約があるため。閾値は2段階: ショート
  (72pt 固定) でプレビュー (色+アイコンのみ、テキストラベルなし) が切り
  替わり、ロング (行幅の約75%) で長押しアクションの見た目に変わる。閾値
  を超えて指を離すと即座に発火 (確認ボタンなし)、届かなければ 0 へ戻る。
  削除もアーカイブも同様にフルスワイプで発火する — 安全弁は確認ダイア
  ログではなく Undo トースト。既定の割り当ては 左スワイプ=既読/未読 →
  アーカイブ、右スワイプ=削除。設定 (メール一覧) で「既読/未読とアーカ
  イブ、どちらを先に出すか」を切り替えられる。
- **長押し一括選択** (1h): 長押しでチェックボックス付きの一括選択モード
  に入る (キャンセル/N件選択中/全選択、下部バーに既読化・移動・削除)。
  一括操作の実行前確認は `.alert` (常に画面中央のモーダル、iPad/macOS で
  ポップオーバー化しない) で行い、設定 (メール一覧)「一括操作の前に確認
  する」(既定 ON) でオフにできる — オフにしても破壊的操作には5秒の Undo
  トーストが残るので安全弁は失わない。
- **Undo トースト**: 削除・アーカイブ・迷惑メール化などの破壊的操作後に
  5秒間表示され、ローカルの取り消し (削除前のレコードを再挿入し、まだ
  リプレイされていない送信待ちの操作を取り消す) を行う。iOS ではフロー
  ティングボタン群より後に描画されるようオーバーレイの順序を管理してい
  る (SwiftUI の `.overlay` は後から適用したものが上に乗る)。
- **macOS の操作体系**: スワイプジェスチャーは存在しない。iOS のスワイ
  プ/長押し一括選択に相当する操作は、行の右クリックコンテキストメニュー
  と本文フッターツールバー、および以下のキーボードショートカットに割り
  当てる。
  | 操作 | macOS の配置 |
  | --- | --- |
  | 既読/未読 | 右クリック / フッターツールバー / ⇧⌘U |
  | アーカイブ (アーカイブ中は解除) | 右クリック / フッターツールバー / ⌘E |
  | 削除 | 右クリック / フッターツールバー / ⌘⌫ |
  | ピン留め | 右クリック / フッターツールバー |
  | 迷惑メール化 | 右クリック / フッターツールバー |
  | 返信 / 全員に返信 | 共有コンポーネント / 右クリック / ⇧⌘R / ⌥⇧⌘R |
  | 転送 | 共有コンポーネント / 右クリック / ⇧⌘F |
  | 作成 | サイドバーの「作成」ボタン / ⌘N |
  | 検索 | 一覧上部の検索欄 / ⌘F |
  | 新規メールを受信 | 一覧上部の更新ボタン / ⌘R |

  意図的に単独修飾なしの1文字キー等価 (例: 単なる `E`) は使わない —
  macOS のメニューキー等価はテキストフィールドにフォーカスがあっても
  アプリ全体で捕捉されるため、件名/本文/検索欄への通常の入力を壊す。
  一括複数選択 (`List(selection:)` によるチェックボックス的な複数選択)
  は macOS では意図的に未実装 — 単一選択+右クリック/フッターツールバー
  /メニューコマンドの組み合わせで全操作をカバーする方針。
  スレッドのアコーディオン内で個別メッセージを右クリックすると、返信/
  全員に返信/転送はその1通を対象にし、既読化・ピン留め・迷惑メール化・
  アーカイブ・削除はスレッド全体を対象にする (このアプリの「削除/アー
  カイブ/ピン留め/既読状態はスレッド単位」という既存の規則と一貫)。

## 翻訳機能

Apple Foundation Models によるオンデバイス翻訳 (英語→日本語の一方向)。
エンジンの詳細・既知の制限・ガードレールの調整は
[`docs/translation.md`](translation.md) を参照— ここでは UI 面だけ書く。

- 本文フッターツールバーの「翻訳」/「要約」アイコンとして常設。かつて
  はフローティングボタンだったが、フッターツールバーへ統合済み。どちら
  のボタンも**言語判定に関わらず常に有効** — 英語判定に依存していた頃、
  判定ミスでボタンが出ない/効かないという実機報告が繰り返し出たため、
  表示条件から言語判定を外した (自動翻訳の起動条件には引き続き言語判定
  を使う)。
- アイコンは本文未読込/AI 機能無効時もグレーアウトで表示したまま (非表
  示にはしない)。処理中はアイコンが `ProgressView` に置き換わる。翻訳済
  みの状態はアイコン自体の強調色で示し、再タップで原文に戻す。失敗時は
  アイコン付近に短いキャプションでエラーを表示する。
- 既定は**手動起動** (設定「英文を自動で翻訳」は既定 OFF) — 自動翻訳を
  嫌うユーザーの実機フィードバックを受けた設定。
- HTML メールは `WKWebView` の DOM テキストノードを直接書き換える方式
  (`HTMLTranslationController`) で翻訳し、表・画像・罫線などのレイアウ
  トを保ったまま訳文を表示する。プレーンテキストメールは段落ごとに
  `Text` を並べる `TranslatedBodyView` を使い、段落を長押しするとその段
  落だけ原文表示に戻せる。
- スレッド全体の AI 要約 (「■経緯/■現状」ではなく map 系の要約パイプラ
  イン、詳細は `docs/translation.md`) はスレッド表示 (アコーディオン)
  モードのときだけ、ナビゲーションタイトル付近の専用ボタンから使える。

## 作成・返信・転送 (Composer)

- 返信/全員に返信/転送はスレッド内の最新メッセージを対象にする。転送は
  宛先を空のまま開く (「誰に送るか」を必ず選び直させる)。件名に "Fwd: "
  を付与し、引用の前に区切りヘッダーを挿入する。添付ファイルは可能な限
  り引き継ぎ、一部取得できなかった場合は本文にその旨を追記する。
- 署名はコンポーズ本文へ**挿入しない** — 選択した署名はグレーの編集不
  可プレビュー行として本文の下に表示するだけで、実際の本文への合成
  (`RichTextDocument.appendingSignature(_:)`) は送信直前に行う。
- 添付は「添付」メニュー1つに集約 (ファイル選択/写真選択/カメラ撮影)。
  カメラは実機のみ有効 (Simulator はグレーアウト)。
- リッチテキスト編集 (フォントサイズ4段階・文字色・背景/ハイライト色・
  リンク・引用) に対応。文字色/ハイライト色のパレットは黒白を含む9色。
  「デフォルト」色は属性を除去するのではなく明示的な動的カラー (`.label`
  など) を割り当てる実装 — 属性を除去すると入力継続中の文字色が黒に固
  定されてしまう不具合があったため。
- 宛先 (To/Cc/Bcc) はプレーンなカンマ区切りテキストのまま、入力中に過去
  のやり取り (連絡先ではなくメッセージ履歴のみ) からの候補をインライン
  表示する。並び順は頻度 (対数減衰) と直近性 (180日で線形減衰) の加算。
- 「英語で返信を下書き」機能は**廃止済み** (実装なし)。

## 検索

- iOS: `SearchScreenView` にアカウント絞り込みチップ (2アカウント以上の
  ときだけ表示)、検索履歴タブ、保存済み検索タブを持つ。検索演算子
  `from:`/`to:`/`cc:`/`subject:` に対応 (`SearchQuery.parse(_:)`)。フィ
  ルタ (添付あり/未読) はクライアント側の絞り込みで、再クエリはしない。
- macOS: `MessageListView` 自身が一覧ペイン上部に持つ独自の検索バー
  (`MacListSearchBar`、カプセル型 `TextField` + スコープ絞り込み + 未読
  のみトグル + 再読込ボタン) を使う。システム標準の `.searchable` では
  ない — `NavigationSplitView` のツールバーに乗せると検索欄が本文ペイン
  側の右上に見えてしまう表示上の問題があったため、一覧ペインの直上に自
  前で描画している。⌘F でフォーカスする。
- 検索結果もスレッド表示設定 (アコーディオン/フラット) に従う。フラッ
  ト表示のときはメッセージ単位、スレッド表示のときはスレッド単位でグ
  ルーピングされる — 検索だけこの設定を無視して常にグルーピングする、
  ということはない。

## アカウント色とアバター

- アカウント ID から FNV-1a ハッシュ、または新規作成時は「既存アカウン
  ト色から色相環上でもっとも離れた色」を選ぶ形で、20色のパレット
  (`OtegamiAccountColor.swift`) から固定色を割り当てる。同じ ID には常
  に同じ色を返す (`String.hashValue` はプロセスごとにソルトされ使えない
  ため、独自の安定ハッシュを使う)。20色のうち19色は色相を持つ通常色、最
  後の1色は純白 — 白は自動割り当てでは選ばれず、設定のカラーピッカーか
  ら明示的に選んだ場合のみ使われる。
- アバターの解決順序: 連絡先の写真 → Google プロフィール写真 → Gravatar
  → 企業ロゴ (BIMI → favicon) → イニシャル。`SenderAvatar` 自体は
  Contacts/URLSession に依存せず、`@Environment(\.avatarImageResolver)`
  経由で具象リゾルバ (`apps/Otegami/Sources/Support/`) を注入される構成
  — アプリ本体以外 (DesignSystemCatalog など) からも安全に使える。フリ
  ーメールドメイン (Gmail/iCloud/Yahoo! JAPAN 等) は企業ロゴ/BIMI の対象
  から除外する。各ソースは個別に設定でオン/オフでき、それぞれどの情報
  が外部に送信されるか (メールアドレスのハッシュ、ドメイン名など) を
  フッターに明記している。

## HTML メール表示

- **ダークモード時の配色判定** (既定、トグル OFF): 3つの判定に分岐する。
  (1) 明るい配色で作られたメール (背景が明るい、または背景指定が無く文
  字色が暗い) と判定した場合は反転せず**そのままライト表示**に固定する。
  (2) 色指定が一切無いメールはダークネイティブのまま何もしない (アプリ
  の基本 CSS リセットに任せる)。(3) メール自身がダークモード対応
  (`prefers-color-scheme`) を宣言している場合は一切手を加えない。
  かつて既定だった「色反転」(`filter: invert(1) hue-rotate(180deg)`) は
  設定でオプトイン (既定 OFF) の別モードとして残っている。「メールの背
  景を常に白 (ライト表示)」設定は上記の判定を無視して常に強制的にライ
  ト表示する、独立した強めのオプション。
- 高さは `#otegami-fit-outer` の実測 (`ResizeObserver` 併用) を JS→Swift
  へブリッジして `WKWebView` のフレームに反映し、内部スクロールは無効化
  (`scrollView.isScrollEnabled = false`、iOS のみ) して外側の `ScrollView`
  1枚だけがスクロールを持つ構成にしている (二重スクロールのジェスチャ
  競合を避けるため)。
- 画像は `max-width:100%` 相当のブランケットルールでレイアウト崩壊を防
  ぐが、メール自身がインラインで明示的な `max-width` を指定している画像
  はそのルールから除外し、通常のカスケード (インライン優先) に委ねる。
- 引用履歴 (返信の `>` 引用/HTML の入れ子引用) はメッセージ単位に分解し
  て「表示/非表示」トグル付きのカードとして時系列表示する。HTML メール
  では引用より新しい部分だけを `WKWebView` に読み込み、引用部分はネイ
  ティブの同じカードコンポーネントで表示する (DOM を直接操作しない)。
- WebView は初期状態で透明にしておき、上記の判定が確定してから一度だけ
  フェードインする (読み込み中のチラつき防止)。

### Task #205 (実機報告: 実メールで「画像が出ない」「幅・高さが崩れる」
「ソースを表示が空白」の3件が同時発生)

ユーザー提供の実メール (サブスクリプションのメンテナンス完了通知、
`multipart/alternative`) を Mac 版で開いたときの報告。3つは互いに独立した
別々のバグだった — 詳細な原因調査・修正は `HTMLMessageView.swift`/
`MessageSourceView.swift` の Task #205 doc comment 参照。フィクスチャは
`AppEnvironment.uitestFakeHTMLMessageBodyResponsiveTableFooterNotice`
(`scripts/verify-screen.sh html-10`) — 内容は架空だが、再現に必要な構造
(`http:` 外部画像2枚 / ネストした `width="100%"` レスポンシブテーブル /
濃色背景フッター) は実メールと同じ。

1. **`http:` (非 `https`) 画像が常に壊れたアイコンになる (iOS/macOS 共通)**:
   「リモート画像を自動で読み込む」が既定 ON のため、このアプリ自身の
   `WKContentRuleList` による遮断は効いておらず (＝「画像を表示」バナー
   も出ない)、実際には読み込みを試みて **App Transport Security (ATS)**
   が Info.plist に例外の無い平文 `http` を既定でブロックしていたために
   毎回失敗していた。`project.yml` の Info.plist に
   `NSAppTransportSecurity.NSAllowsArbitraryLoadsInWebContent: true` を
   追加 — `WKWebView` が読み込むコンテンツだけに ATS 制限を解除する
   Apple 公式のキーで、アプリ自身の通信 (IMAP/SMTP/OAuth/relay/iCloud)
   には影響しない。あわせて、読み込みに失敗した `<img>` を WebKit 既定の
   壊れたアイコン (枠線付きの箱に「?」) のままにせず、意図の分かる中立
   なプレースホルダ (斜線入り画像アイコン、灰色破線枠) へ差し替える処理
   を `HTMLWebViewCoordinator.fitToWidthScript` に追加 (`img`の`error`
   イベント/`complete && naturalWidth===0`の両方を検知)。開封トラッキング
   用の1x1透明画像のような極小画像 (`width`/`height`属性が2px以下) は
   この装飾の対象から除外 — 敷くと「元は完全に不可視だったものが急に
   見える化する」副作用があるため。
2. **macOS で HTML 本文の幅・高さがおかしい**: `HTMLDocumentBuilder.wrap`
   の CSS リセットに、img 向けには Task #56 で既に対策済みだった「著者の
   明示指定 (`max-width`/`width:100%`) を `!important` で問答無用に踏み
   潰す」バグが、img 以外の要素・`table` には残っていた。実メールは
   `<table style="width:100%; max-width:700px;">` (幅いっぱいに広がるが
   700pxで頭打ち) という現代的なレスポンシブテーブルを使っており、この
   `max-width:700px` が `100%` (＝ビューポート幅) で上書きされる一方、
   内側の `width="100%"` のモジュールテーブル (フッターの濃色帯を含む)
   は逆に `width: auto !important` で無効化されていた — 結果、フッターの
   帯が本来の700pxにも実ビューポート幅にも一致しない中途半端な内容依存
   の幅に縮み、右側に白い余白が残っていた (「フッターの濃い帯が途中で
   切れる」の正体)。img と同じ「著者が明示指定を持つ要素は非`!important`
   のフォールバックに倒す」形に揃えて修正。ローカルの WKWebView 計測
   スクリプト (再現メールと同じ構造、内容は架空に差し替えたもの) で
   900pxビューポートに対し修正前は700pxキャップが効かず全幅まで広がる
   こと/修正後は700pxに収まりセンター寄せされることを確認済み。「本文の
   下に広い空白」の報告は、この幅計算バグと同時に発生していたが、実機
   アプリで修正後に確認したところ内容に比例した高さに収まっており、
   単独の別バグとしては再現しなかった (幅計算バグの副作用だった可能性が
   高い)。
3. **macOS で「ソースを表示」が空白 (iOS は無関係)**: `MessageSourceView`
   が Task #103 で追加された際、M10 で確立済みだった「macOS の `.sheet`
   は `NavigationStack { ... }` の中身の内在サイズから算出されない (中身
   が `List` や柔軟なレイアウトだけだと、シートがタイトルバー＋ツール
   バーだけのほぼ無に近い高さで開く)」という既知のパターン
   (`AccountTypeSelectionView`等の doc comment 参照、`AccountSetupView`/
   `AccountsSettingsView`/`ICloudAccountSetupView`等は既に対策済み) への
   追従を1箇所だけ付け忘れていた、という単純な見落とし。`#if os(macOS)`
   で `.frame(minWidth: 640, minHeight: 480)` を追加して解決 — 実機アプリ
   で修正前後を確認済み (修正前はメニューから「ソースを表示」を選んでも
   目に見える変化がなかった=シートがほぼ無に近い高さで開いていた、
   修正後は正しいサイズのダイアログが開く)。iOS は `.sheet` が画面いっぱ
   いに広がる既定の挙動なのでこの問題自体が発生しない。

### Task #207 (ユーザー要望: 平文 http の画像は許可する方針でよいが、
確認ダイアログを出してほしい)

Task #205 で `NSAllowsArbitraryLoadsInWebContent` を追加し、平文 `http`
の画像も (ATS に弾かれず) 読み込めるようにした直後の要望。`http` は経路
上で改竄されうるため、`https` と同じ「既定で自動表示」にはせず、メール
ごとに「http の画像があるが読み込むか」を確認してから読み込む。

- **既存の仕組みを拡張** — 新しい遮断機構を並立させず
  `HTMLWebViewCoordinator` の `WKContentRuleList` に http 専用の追加
  ルール (`^http://.*` を対象、`https://` は前方一致しないので除外不要)
  を足しただけ。`allowsExternalContent`(既存、リモート画像全般の可否) が
  false の間は従来どおり全リモート画像を一括ブロックし、true になって
  初めて http 専用ルールが (`allowsPlaintextHTTPImages` が false の間)
  効く — `https` の挙動・既定は一切変更していない。
- **判定は画像限定・http 限定の狭いスキャナ**
  (`HTMLExternalResourceScanner.containsPlaintextHTTPImage`、
  `packages/OtegamiKit`) を新規に切り出した。既存の
  `containsExternalResource`(バナー表示要否の判定に使う、`href` も含む
  広い判定) とは別物 — `href` だけのメール (画像なし) で誤って確認
  ダイアログを出さないよう、`src`/`background`/`poster` 属性と CSS の
  `background-image: url(...)` だけを対象にした。ユニットテストは
  `packages/OtegamiKit/Tests/OtegamiCoreTests/HTMLTextExtractorTests.swift`。
- **確認の出し方**: 「画像を表示」バナーと同じ帯には混ぜず、意図的に
  別立てのバナー (`plaintextHTTPImagesBanner`、警告色
  `OtegamiColor.destructive`) をタップすると `.alert` (中央モーダル) が
  開き、そこで初めて実際に許可する。Task #190 が一括操作の実行前確認を
  `.confirmationDialog`(iPad/macOS でポップオーバー化する) から `.alert`
  (常に画面中央) へ差し替えた方針と揃えた — 安全性に関わる確認である点
  は共通で、吹き出しより中央モーダルの方が見落としにくいと判断した。
  文言 (「保護されていない接続の画像を読み込みますか？」+ 「暗号化され
  ていない接続 (http) …通信内容は経路上で書き換えられる可能性がありま
  す。」) で平文であることそのものが伝わるようにした。
- **許可の範囲**: 既存の「画像を表示」バナー
  (`allowsExternalContent`/`allowsEmbeddedImages`) と同じ「そのメール
  だけ、このアプリセッション中」— `HTMLMessageView` の `@State` はメッ
  セージを開くたびに `init` から作り直されるため、別のメールを開く/
  アプリを再起動すると既定 (設定の `PlaintextHTTPImagePolicy`) に戻る。
  既存の設計にすでにある唯一のスコープなので、新しい粒度 (送信者ごと・
  恒久的等) を増やさずこれに揃えた。
- **設定 (画像設定「保護されていない画像 (http)」)**: 「確認する」(既定)
  /「常に許可」/「常に拒否」の3値 (`ImageSettingsStore
  .plaintextHTTPImagePolicyKey`、`PlaintextHTTPImagePolicy`)。「常に
  拒否」はバナー自体を出さない (毎回のバナーが「常に拒否」を選んだ人へ
  の催促になるのを避けるため)。「リモート画像を自動で読み込む」が OFF
  の間はこの設定自体に意味が無い (既存の「画像を表示」バナーが先に全
  リモート画像を覆っているため) — 設定画面でも `.disabled` にしている。
- **検証**: `scripts/verify-screen.sh html-10`(平文 http 画像2枚を含む
  Task #205 のフィクスチャ) で「保護されていない画像を確認」バナーが
  出ること、ブロックされた画像がプレースホルダ表示になること
  (＝実際に `WKContentRuleList` が該当リクエストを遮断していること) を
  iOS シミュレータのタップ不要経路で確認済み。`html-0`(http 画像を含ま
  ない既存フィクスチャ) でバナーが一切出ないこと、`https` 画像がこれ
  までどおり自動表示されることも確認済み。**バナーをタップして `.alert`
  自体が開き、「読み込む」で実際に画像が表示される一連の流れは実機/
  シミュレータでのタップ操作で未確認** (macOS の CGEvent 駆動でのクリッ
  クがこのセッションでは安定せず、`docs/verify.md` の「粘らない」方針
  により打ち切った) — 状態遷移の実装自体は `allowsExternalContent`/
  `allowsEmbeddedImages` の既存バナーと全く同じパターン
  (`allowsPlaintextHTTPImages = true` → `reloadIfNeeded` → content rule
  list 再適用) で、そちらは `OtegamiImageSettingsUITests` でカバー済み。

## ビジュアルスタイル

- フラットデザイン。角丸は `OtegamiRadius.none` (0) が既定で、**カード
  のみ** `OtegamiRadius.card` (8pt) の角丸を許容する (macOS の一覧行カー
  ド、iOS では一覧行はフルブリード化のため角丸なし)。ボタン・チップ・
  バッジは常に角丸なし。検索画面のトップバー (カプセル型テキストフィー
  ルド・丸い閉じるボタン) だけは `Capsule()`/`Circle()` を直接使う、閉じ
  たスコープの例外。
- 罫線は2段階: 主要区切り線は2pt実線 (`OtegamiStroke.primary`、
  `OtegamiColor.divider`)、行間の区切りは1pt破線/ハイライン
  (`OtegamiStroke.secondary`、`OtegamiColor.dividerSubtle`)。
- 英字は Archivo (SIL Open Font License、`Resources/Fonts/Archivo/` に同
  梱)、日本語はシステムフォント。フォント種別を切り替える実装はしてい
  ない — Archivo が対応しないグリフは CoreText のフォントカスケードで自
  動的にシステムフォントへフォールバックするので、1つの `Font` を混在
  文字列にそのまま使えば両方が意図通り描き分かれる。全スタイルが
  `Font.custom(_:size:relativeTo:)` 経由で Dynamic Type に対応する (固定
  pt 指定はしない)。ウェイトは Archivo 可変フォントの named instance
  (`ArchivoRoman-Regular`/`-Medium`/`-SemiBold`/`-Bold`)。
- 淡い水色ベースのライトテーマ (背景 `#EEF3F6`、面 `#FFFFFF`、アクセン
  ト `#3D7F9E` 系) と、それに対応するダークテーマ (背景 `#10191E`、面
  `#1F2E36` — 単純な反転ではなく、暗い紙の上でも階調が読み取れるよう独
  自に設計した値)。破壊的操作の色 (`destructive`、`#EC3013` 系) だけは
  水色ファミリーから独立した既存のブランド色をそのまま使っている。
  `Color(light:dark:)` (`DynamicColor.swift`) が全トークンの基礎で、
  `UIColor`/`NSColor` の dynamic provider により実機・Simulator・
  Preview・`ImageRenderer` オフスクリーン描画のいずれでも正しく解決さ
  れる。

### トークン一覧

| 種類 | ファイル | 内容 |
| --- | --- | --- |
| カラー | `OtegamiColor.swift` | 用途ベースの命名 (`background`/`surface`/`ink`/`accent`/`destructive`/`divider` 等)。生の色名を UI コードに露出させないレイヤー |
| タイポグラフィ | `OtegamiFont.swift` | `largeTitle`/`title`/`headline`/`body`/`subheadline`/`caption`/`badge`/`monospaceBody` |
| スペーシング | `OtegamiSpacing.swift` | 12pt を基本単位とするスケール: `xs=4/sm=8/md=12/lg=16/xl=24/xxl=32` |
| 罫線・角丸 | `OtegamiBorder.swift` | `OtegamiStroke.primary/secondary`、`OtegamiRadius.none/card` |
| アカウント色 | `OtegamiAccountColor.swift` | 20色パレット + 自動割り当てロジック |

### 基本コンポーネント — `Components/`

| コンポーネント | 説明 |
| --- | --- |
| `AccountFilterChip` | アカウント絞り込みチップ。選択状態は塗り+枠線の両方で表現 |
| `UnreadDot` | 未読ドット。未読でなくても透明円としてレイアウト分を確保 (行の高さが揺れない) |
| `AccountColorRail` | アカウント色の左罫線 (3pt) |
| `SectionDivider` / `.otegamiRowDivider()` | セクション区切り (2pt実線) と行区切り (1pt破線/ハイライン) |
| `ENBadge` / `HTMLBadge` / `ArchivedBadge` | 英語メール/HTML メール/アーカイブ済みを示す小バッジ |
| `OtegamiFloatingButton` | フローティングボタンの共通見た目 (検索・作成・設定などで使用) |
| `SenderAvatar` | 送信者アバター (解決順序は上記「アカウント色とアバター」参照) |
| `SyncProgressBanner` | 同期進捗バナー (pull-to-refresh の進捗表示・キャンセル) |
| `UndoToast` | Undo トースト |
| `.otegamiMinimumTappable()` | どんな見た目のビューにも 44×44pt 以上のタップ領域を保証する `ViewModifier` |

### カタログで見た目を確認する

`apps/Otegami/Sources/DesignSystem/Catalog/DesignSystemCatalogView.swift`
— 全トークン・全コンポーネントを1画面に並べた `#if DEBUG` 専用ビュー。
確認方法は2つ:

1. **`apps/Otegami/DesignSystemCatalog/`** — 独立した SwiftPM 実行ター
   ゲット。`Sources/DesignSystem` はシンボリックリンクでアプリ本体の
   `Sources/DesignSystem` を直接指しているので、コピーではなく**全く同
   じソース**をビルドする。

   ```sh
   cd apps/Otegami/DesignSystemCatalog
   swift run DesignSystemCatalogRenderer [出力先ディレクトリ]
   ```

   `ImageRenderer` によるオフスクリーン描画のため Xcode/シミュレータ不
   要で確認できる。
2. **Xcode Preview** — `DesignSystemCatalogView.swift` 末尾の
   `#Preview("Light")`/`#Preview("Dark")`。

### Archivo フォントのライセンス

`apps/Otegami/Resources/Fonts/Archivo/` に `Archivo-Variable.ttf`
(Google Fonts 配布、`wght`/`wdth` 軸) と `OFL.txt` (SIL Open Font License
1.1 全文) を同梱。OFL は再配布・改変・同梱を無償で許可するライセンスで、
単体販売しない限り問題ない。帰属表示はリポジトリ直下の `NOTICE` に記載
済み。

## SwiftUI 実装上の落とし穴

このアプリの UI 実装で繰り返し踏んだ、SwiftUI/AppKit 固有の落とし穴。
実装時に同じ問題を再発明しないための備忘録。

1. **`Menu` の項目順序が開く向きで反転する**: `.menuOrder` の既定値
   `.automatic` は、iOS でメニューが**開く向きに合わせて項目順を反転**
   させる (ボタンに近い側を先頭にするための挙動)。同じメニューでも、画
   面内の位置やスクロール状態によって上向き/下向きどちらで開くかが変わ
   り、そのたびに項目の並びが丸ごと入れ替わる。`.menuOrder(.fixed)` を
   付けると、開く向きに関わらず常にソースコード上の宣言順を維持する
   (`MessageDetailFooterToolbar.swift` の「その他」メニュー参照)。
2. **動的な文字列は `Text(verbatim:)` で渡す**: アカウント表示名・検索
   クエリ・メール件名など、ユーザー/サーバー由来の動的文字列を
   `Text`/`Label` に渡すときに `LocalizedStringKey` 経由 (`Text(title)`
   のような素の呼び出し) にすると、SwiftUI がその文字列を Markdown とし
   て解釈する。表示名がメールアドレスそのもの (アカウント追加時に表示
   名を空にした場合の既定) だと自動的にリンク化され、タップすると
   `mailto:` が開いてしまう実機バグが実際に発生した
   (`AccountFilterChip.swift` の doc comment に詳細)。固定の UI 文言
   (「全部」「キャンセル」等、ローカライズ対象の文言) は引き続き
   `LocalizedStringKey` 経由で問題ない — 対象はあくまで動的な値。
3. **macOS のボタンは明示的なスタイルが要る**: `Button`/`Menu` に
   `.buttonStyle`/`.menuStyle` を何も指定しないと、macOS では既定の
   `.automatic` が黒っぽい角丸背景付きのボーダー付きスタイルを適用す
   る (iOS の既定はこうならない)。アイコンだけのツールバーボタンがやけ
   に大きく重く見える場合はこれが原因であることが多い。
   `.buttonStyle(.plain)` + `.menuStyle(.borderlessButton)` をコンテナ
   単位でまとめて適用すれば解決する (`MessageDetailFooterToolbar.swift`
   の `#if os(macOS)` 分岐参照)。
4. **`List` 行の高さには環境値の下限があり、`.frame(minHeight:)` だけで
   は縮まらない**: `List` の行の実効最小高さは `defaultMinListRowHeight`
   環境値が握っており、これが個々の行に付けた `.frame(minHeight:)` より
   大きい場合はそちらが勝つ。行を詰めたい場合は
   `.environment(\.defaultMinListRowHeight, <値>)` を `List` 自体に設定
   する必要がある。さらに `Section` ヘッダーには `List` 側が付加する
   固定のパディングコストが別途乗り (公開 API で制御できない)、これが
   無視できない差になる場合は、その `Section` を使わず素の行として描画
   する回避策もある (`FolderListSheet.swift` 参照)。
5. **SwiftUI `body` の型チェックタイムアウト**: `Form`/`List` の中で
   `ForEach`/条件分岐/モディファイアチェーンを1つの式に積み上げすぎる
   と、ローカルでは通っても CI (`ci-app`) の型チェックが
   "the compiler is unable to type-check this expression in reasonable
   time" で落ちることがある。ローカル Xcode より CI ランナーの方が型
   チェックが遅い/挙動が異なることがあるため、ローカルで警告が出なくて
   も CI で落ちうる。ルール: `body` を短く保つ、`ForEach`/`List` の行の
   中身は独立した `View` 型に切り出す、タップハンドラは名前付きメソッド
   参照にする。詳細な事例と教訓は
   [`docs/ci.md`](ci.md#既知の落とし穴-swiftui-ビューの型チェックタイムアウト)
   と [CONTRIBUTING.md](../CONTRIBUTING.md#a-note-on-swiftui-views-and-ci)
   を参照。
6. **macOS の `WindowGroup`/`NavigationSplitView` は、ウインドウ位置・
   サイズもカラム幅も AppKit がすでに自動で覚えている**: Task #209
   (実機フィードバック「mac で起動した時、ウインドウや各カラムのサイズを
   覚えるようにして欲しい。特に、初回起動時のメールビューが狭すぎる」)
   で、自前の永続化コード (`@AppStorage`/`@SceneStorage` でウインドウ矩形
   やカラム幅を保存する等) を書く前に実機ビルド (`make mac-app`) で検証
   したところ、**何もしなくてもすでに記憶・復元されていた**: ウインドウ
   を動かす/リサイズする、`NavigationSplitView` の仕切りをドラッグする
   → quit → 再起動、で両方とも元通りになることを確認した。実体は AppKit
   の状態復元機構で、`~/Library/Preferences/<bundle id>.plist` に
   `NSWindow Frame <Scene の中身の型のマングル名>-1-AppWindow-1` と
   `NSSplitView Subview Frames <同じ型名>-1-AppWindow-1, SidebarNavigation
   SplitView` というキーで書かれる (`defaults read <bundle id>` で確認
   可能)。**このキーは `WindowGroup { ... }` の中身に直接付けた修飾子の
   型で決まる** — 逆に言うと、この `WindowGroup` のクロージャ内
   (`OtegamiApp.body`) に新しい `.environment`/`.background` 等を足す/
   減らす/並べ替えると型名が変わり、既存ユーザーの保存済み状態が1回だけ
   孤立する (実害は小さいが要注意)。`.defaultSize`/`.commands` のような
   **Scene 側の修飾子はこの型名に影響しない**ので安全に足せる。
   Task #209 で実際にやったのはこの2つだけ:
   - `OtegamiApp.body` の main `WindowGroup` に
     `#if os(macOS) .defaultSize(width: 1200, height: 800) #endif` を追加
     — 上記の自動復元は「保存済み状態が無い最初の1回」には効かず、それ
     までの既定値は実測 900×450 と3ペインに収めるには明らかに狭かった
     (「メールビューが狭すぎる」の直接原因)。1200×800 は3カラムの min/max
     (次項) を引いても本文側に400pt超残ることを実機目視で確認して選んだ。
   - `OtegamiApp.splitView` のサイドバー/一覧カラムに
     `.navigationSplitViewColumnWidth(min:ideal:max:)` を追加 — 極端な
     値で保存されて戻せなくなる事態 (要求③) への対策。この修飾子が無いと
     カラム幅の自動復元に上限が無いため、開発中に一覧カラムを大きくド
     ラッグしたまま忘れる、といった degenerate な状態が永続してしまう
     (実際にこの開発機の `~/Library/Preferences` にその状態が残っていた
     — 一覧カラムが本文を圧迫していた)。`min`/`max` を付けると、SwiftUI
     がライブドラッグだけでなく**復元時の古い/壊れた値もこの範囲へ
     クランプする**ことを、`NSSplitView Subview Frames` を意図的に極端な
     値 (一覧1300pt・本文60pt) に書き換えてから再起動する実機検証で確認
     した — 再起動後は範囲内に戻り、本文も再び読める幅になった。本文
     (`detailColumn`) 自体には明示的な幅を付けていない (他2カラムの
     `max` 引いた残り全部を受け取る、既存の挙動のまま)。
   - 保存先はどちらも上記の通り AppKit 標準の `~/Library/Preferences`
     ローカルファイルであり、`AppSettingsCloudDirectory` の同期対象
     allowlist には一切含まれない (そもそも `UserDefaults` の自前キーで
     すらない) — Task #186 の「ウインドウ位置・カラム幅は端末ごとに違っ
     て自然なもの」という同期対象外の方針 (`docs/icloud-sync.md`) と
     矛盾なく両立する。

## 関連ドキュメント

- [`docs/translation.md`](translation.md) — 翻訳・要約エンジンの詳細
  (ガードレール、既知の制限)
- [`docs/ci.md`](ci.md) — CI の既知の落とし穴 (型チェックタイムアウト等)
- [`docs/settings.md`](settings.md) — 設定画面の項目一覧
- [`docs/verify.md`](verify.md) — 実機シミュレータでの検証手順
- [`docs/icloud-sync.md`](icloud-sync.md) — アカウント情報の iCloud 同期
