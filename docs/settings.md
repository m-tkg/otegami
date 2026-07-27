# 設定項目一覧

## 設定画面の構成 (実機フィードバック第2弾: I → 第3弾: I で再編)

設定画面 (iOS: ハンバーガーメニュー→「設定」シート、macOS: Settings シーン
の「設定」タブ) のルートは、以前は全設定項目がフラットな1画面に並んで
いたが、カテゴリへ再構成した。各カテゴリは`AccountsListContent`(設定
ルート、`AccountsSettingsView.swift`) からの`NavigationLink`で、iOS・
macOS 共通の実装 (`AccountsListContent`自体を両プラットフォームの
`NavigationStack`が共有しているため、カテゴリ構造は自動的に両方に揃う)。

実機フィードバック第3弾 (I): 当初の5分類 (アカウントの設定/メール
ビューア/メール一覧/署名テンプレート/その他) を4分類 + ルート直下の
「このアプリについて」に再編した。「その他」は雑多な置き場になっていた
項目を性質の近い既存カテゴリへ再配置した結果空になったため廃止し
(`OtherSettingsView.swift`自体を削除)、ルート直下の独立項目だった
「署名テンプレート」は新設「メール作成」カテゴリへ統合した。

| カテゴリ | 実装 | 内容 |
| --- | --- | --- |
| アカウントの設定 | `AccountSettingsCategoryView.swift` | アカウントの追加削除、G「デフォルトのアカウント設定」、iCloud 同期、プッシュ通知 (いずれも実機フィードバック第3弾 (I) で「その他」から移設)。ラベル色 (D) は各アカウントの編集画面 (`AccountEditView`) 側 |
| メールビューア | `MailViewerSettingsView.swift` | ブラウザの設定 (C7)、G「削除/アーカイブ時の挙動」、本文へのプロフィール画像表示、AI 機能 on/off (翻訳・要約をまとめて)、画像設定 (B)、HTML表示設定 (A9) (画像・HTML表示は実機フィードバック第3弾 (I) で「その他」から移設) |
| メール一覧 | `MailListSettingsView.swift` | 一覧のプロフィール画像表示、プレビュー行数、スワイプ設定 (D8)、一覧に要約を出す、スレッド表示、ピン留めのフラグ連動 (スレッド表示・ピン留め連動は実機フィードバック第3弾 (I) で「その他」から移設) |
| メール作成 | `MailComposeSettingsView.swift` (実機フィードバック第3弾 (I) で新設) | テンプレート (C8)、署名テンプレート (F、旧ルート直下から統合)、送信キャンセルの猶予 (C7、旧「その他」から移設) |

「このアプリについて」(`AboutView`) はルート直下 (iOS のみ — macOS は
`OtegamiSettingsView`の独立した「情報」タブに既にあるため重複させない)。

- **AI 機能 on/off (メールビューア)**: `AIFeaturesSettingsStore` (新規、
  既定 ON) — `MessageView`の翻訳バー・AI要約バーの両方をまとめて表示/
  非表示にするマスタースイッチ。OFF でも「英文を自動で翻訳」設定自体は
  残るが、マスターが OFF の間は一切参照されない (バーそのものが出ない
  ため)。作成画面 (Composer) の「英語に翻訳して送る」トグルはこのマスター
  の対象外 (独立した、常時表示の機能のまま)。
- **送信キャンセルの猶予**: `SendCancelSettingsStore`自体は表示・操作
  改善バッチ (C7) で実装済みだったが、値を変更する`Picker` UI が第2弾の
  再構成まで存在しなかった (`ComposerView`が既定値を読むだけの状態) —
  その再構成のついでに配線し、第3弾 (I) で新設の「メール作成」カテゴリへ
  移した。
- **メール作成カテゴリへの「署名テンプレート」統合の判断**: テンプレート
  (C8) と署名テンプレート (F) はどちらも「メールを書くときに使う設定」
  という共通点があり、ルート一覧に似た名前の項目が2つ (このカテゴリへの
  入口と、旧ルート直下の署名テンプレート) 並んで見えるより、1つのカテゴ
  リの中に「テンプレート」「署名テンプレート」の2つの入口がある方が発見
  しやすいと判断した。`SignatureTemplateRecord`のドキュメントコメントが
  説明する「テンプレート (全文定型) と署名 (本文末尾への付加) は別機能・
  別テーブル」という区別自体は変えていない — 設定画面上の置き場所だけの
  統合。
- **macOS**: `OtegamiSettingsView`の "設定" タブ (旧「アカウント」タブ、
  中身がカテゴリ一覧に変わったためタブ名も変更) がこの`AccountsListContent`
  をそのまま埋め込むため、iOS と全く同じカテゴリ構造になる (「このアプリ
  について」は例外 — 上記参照)。

otegami の設定項目を一箇所に整理したもの。2026-07-26 のユーザー要望
バッチ（バグ修正・一覧表示・送信キャンセル・スワイプ設定・ピン留め）で
設定項目が大きく増えたため新設。実装は `apps/Otegami/Sources/Support/`
配下の各 `*SettingsStore` (プレーンな `UserDefaults` キーの集まり、
`@AppStorage` で各 View から直接参照する — なぜ `AppEnvironment` 経由に
していないかは各ファイルのドキュメントコメント参照) と、
`AccountsListContent`（iOS の「設定」タブ / macOS Settings シーンの
「アカウント」タブが共有する実体、`apps/Otegami/Sources/Features/
Settings/AccountsSettingsView.swift`）の UI。

## 操作 (スワイプの割り当て) — iOS のみ

`SwipeActionSettingsStore.swift`。**iOS のみ表示** — macOS にはスワイプ
ジェスチャー自体が無く、同等の操作はすべて行の右クリックコンテキスト
メニュー (`MessageListRow.contextMenuContent`) に常時揃っている。

左右それぞれに「短いスワイプ」「長いスワイプ」の2アクションを個別に
割り当てられる。選べる操作は5つ:

- 既読/未読切替
- アーカイブ
- 迷惑メールにする (Junk ロールのメールボックスへ移動。無ければ Trash
  と同じパターンで自動作成)
- ピン留め
- 削除

| キー | 既定値 |
| --- | --- |
| `swipeActions.leadingShort` | 既読/未読切替 |
| `swipeActions.leadingLong` | アーカイブ |
| `swipeActions.trailingShort` | 削除 |
| `swipeActions.trailingLong` | 削除 |

既定値は変更前 (design-phase-3 まで) の固定割り当て「右短=既読/未読、
右長=アーカイブ、左=削除」と完全に一致させてある。

**しきい値で自動実行バッチ**: ボタンをタップして確定する UI (SwiftUI 標準
の `.swipeActions`) から、指を離した瞬間にその場でアクションが実行される
カスタムジェスチャーに作り替えた (`MessageListRow` のドキュメントコメント
に実装の全体像、`docs/design-system.md` の同名の節にしきい値の設計・
検証記録がある)。

- ドラッグ中は行の下から短いアクションの色 + アイコンが現れ、ドラッグ量が
  長いしきい値を超えるとアイコン/色が長いアクションのものに切り替わる
  (それぞれの切替時に軽い触覚フィードバック)。
- 指を離した時点でしきい値を超えていれば、そのアクションが**その場で
  即座に実行される** — ボタンは無く、確認タップは要らない。しきい値未満で
  離すと行は元の位置に戻り、何も実行されない。
- **削除・迷惑メールも自動実行の対象** — 従来あった「削除/迷惑メールは
  常にタップ確定」というガード (`SwipeAction.isGuardedFromFullSwipe`) は
  撤廃した。取り消したい場合は既存の Undo トースト (`MessageListView
  .scheduleUndo`) が受け皿になる。
- ピン留めスロットは、対象スレッドが既にピン留め済みのときはアイコンが
  `pin.slash` (ピン解除) に、色も別トーンに変わる — 既読/未読切替の表示が
  現在の状態に応じて切り替わる (`toggleReadLabel`) のと同じ流儀。
- スワイプでアクションが発火しても、その行のタップ (本文を開く) は発生
  しない — ドラッグが認識された場合は `Button` 自身の既定タップより優先
  される (`.highPriorityGesture`)。しきい値未満の本物のタップは今まで
  どおり本文を開く。
- **スワイプの滑らかさ改善**: 指への追従・離した後の挙動をスプリング
  ベースにし、削除/アーカイブ/迷惑メールのようにスレッドが一覧から消える
  操作は「行が画面外までスライドアウト→一覧の隙間が詰まる」までを1つの
  連続したアニメーションにした (`docs/design-system.md` の「スワイプの
  滑らかさ改善」節に実装の詳細)。既読/未読切替・ピン留めは行自体が消えな
  いため、実行後はスプリングで元の位置へ戻るだけ。

## 一覧・表示

`ListDisplaySettingsStore.swift`。iOS・macOS 共通。

| 項目 | キー | 既定値 | 説明 |
| --- | --- | --- | --- |
| スレッド表示 | `listDisplay.threading` | ON | ON で一覧を会話 (スレッド) 単位にまとめる。OFF にすると一覧がメール単位になる (`ThreadQuery.flatSummaries`/`unifiedInboxFlatSummaries`)。検索結果 (macOS のインライン検索・iOS の検索タブ) には適用されない — 検索は従来通りスレッド単位 (`MessageListView` のドキュメントコメント参照)。スワイプ/コンテキストメニューの各操作は、フラット表示の行から実行した場合でも**そのメールが属するスレッド全体**に対して働く (既存のグループ表示と同じ挙動に揃えてある)。 |
| 送信者のプロフィールアイコンを表示 | `listDisplay.showAvatar` | ON | 一覧の各行に、差出人のアバター (`SenderAvatar`) を表示する。 |
| 連絡先の写真を表示 | `avatarSource.showContactPhoto` | ON | アバター強化バッチ フェーズ1。差出人アドレスを `CNContactStore` (オンデバイス、Contacts framework) と照合し、一致する連絡先に写真があればイニシャルより優先して表示する。初回照合時に OS の連絡先アクセス許可ダイアログが出る (`NSContactsUsageDescription`)。拒否/未許可なら静かにイニシャル表示にフォールバックする。iOS 18+ の limited access (一部の連絡先のみ許可) にも対応 — 許可された範囲だけを照合する。照合結果はメモリ+ディスクにキャッシュし (`Caches/AvatarCache/Contacts/`)、連絡先の変更 (`CNContactStoreDidChange`) で丸ごと無効化する。外部には一切送信しない。 |
| Gravatar の画像を表示 | `avatarSource.showGravatar` | ON | アバター強化バッチ フェーズ2。連絡先の写真が見つからなかった差出人について、アドレスを正規化 (trim + 小文字化) して SHA-256 ハッシュ化し `https://gravatar.com/avatar/<hash>?d=404&s=160` から画像を取得する (`d=404`: 登録が無ければ 404、デフォルトのシルエット画像は表示しない)。**差出人アドレスのハッシュが gravatar.com に送信される** — 設定画面にその旨の注記あり、いつでも OFF にできる。取得はスクロールをブロックしない非同期処理。アドレス単位でメモリ+ディスクキャッシュ (`Caches/AvatarCache/Gravatar/`)、TTL 7日 (見つかった/見つからなかったの両方に適用)。ネットワークエラー/タイムアウトは negative cache に書き込まず次回再試行する。 |
| 企業ロゴを表示 | `avatarSource.showCompanyLogo` | ON | アバター強化バッチ フェーズ3 + Task #42。連絡先の写真・Gravatar のどちらも見つからなかった差出人について、まず BIMI (DNS TXT `default._bimi.<domain>` を DNS over HTTPS (`https://dns.google/resolve`) で引き、`v=BIMI1; l=<SVG URL>` の SVG を安全な subset のみパースして描画 — `BIMISVGSafety`/`BIMISVGParser`/`BIMISVGRenderer`、`docs/design-system.md`の Task #42 節参照) を試し、見つからない/安全でない/パース不能なら差出人ドメインの `https://<domain>/apple-touch-icon.png` → `/favicon.ico` の順にフォールバックする。gmail.com/icloud.com/yahoo.co.jp 等の主要フリーメールドメイン (`FreeMailDomains`) は BIMI/favicon いずれも対象外 — ネットワークにすら問い合わせない。ドメイン単位 (メールアドレス単位ではない) でメモリ+ディスクキャッシュ (`Caches/AvatarCache/CompanyLogo/`)、TTL 30日、negative cache 含む。デコードできない画像データ (favicon.ico が真の ICO 形式の場合など) は「見つからなかった」として扱う。ドメイン名が接続先サーバー (BIMI 判定時は Google の DoH エンドポイントにも) 送信される旨を設定画面に注記。 |
| 本文プレビューの行数 | `listDisplay.previewLineCount` | 1行 | なし / 1行 / 2行 / 3行 から選択。 |
| メール本文にも送信者アイコンを表示 | `listDisplay.showAvatarInDetail` | ON | 詳細画面 (スレッド内の各メッセージのヘッダ) にも同じ `SenderAvatar` を表示する。 |

## メールの表示 (A9)

`HTMLDisplaySettingsStore.swift`。iOS・macOS 共通。

| 項目 | キー | 既定値 | 説明 |
| --- | --- | --- | --- |
| 常にテキストで表示 | `htmlDisplay.alwaysShowPlainText` | OFF | ON にすると、HTML メールを開いたときの既定表示がテキスト (`text/plain` パートがあればそれ、無ければ `HTMLTextExtractor` の抽出結果) になる。メール詳細画面の切替ボタン (件名の下、"テキストで表示"/"HTMLで表示") でメールごとに一時的に上書きできる — この上書きはそのメールを開いている間だけで、別のメールを開くとこの設定の既定に戻る。 |
| ダークモードでメールの配色を自動調整 | `htmlDisplay.autoAdjustColorsInDarkMode` | **ON** | Task #45。ライト前提 (白背景 + 濃色文字を明示指定) の HTML メールをアプリのダークモード表示中に開くと、背景だけが透過で暗くなる一方メール指定の濃色文字はそのまま残り、暗地に暗文字でほぼ読めなくなる実機不具合の修正。メール自身が `<meta name="color-scheme">` や `prefers-color-scheme` メディアクエリで自前のダークモード対応を持つ場合は何もしない (二重反転を避ける)。持たない場合のみ `@media (prefers-color-scheme: dark)` の中で本文ラッパに `filter: invert(1) hue-rotate(180deg)` を適用し (NetNewsWire 等と同じ古典的な反転手法)、`img`/`picture`/`video`/インライン`background-image`を持つ要素には同フィルタを再適用して元の色を維持する。`ImageSettingsStore`の2キーと同じ理由で `HTMLMessageView.init` が `UserDefaults.standard.bool(forKey:)` を直接読む (`@AppStorage`ではない)。 |

HTML メールの詳細画面には、件名の隣に控えめな "HTML" バッジ (`HTMLBadge`、
`ENBadge` と同じトークンを使った兄弟コンポーネント) が付く。実質的に
空の HTML (可視テキストも `<img>` も無い、`MessageView.isHTMLMessage`
参照) にはバッジも切替ボタンも出ない — 本文なしの表示 (下記) に譲る。

本文が完全に空 (HTML・テキストいずれも実質的な内容が無い) の場合は、
本文の位置に薄い文字 ("本文なし"、`OtegamiColor.inkTertiary`) を表示する。

## 画像 (B)

`ImageSettingsStore.swift`。iOS・macOS 共通。**既定値が design-phase-3
以前の挙動と逆になっている** — ユーザーと仕様を確定した上での意図的な
変更。

| 項目 | キー | 既定値 | 説明 |
| --- | --- | --- | --- |
| 埋め込み画像を自動表示 | `images.autoShowEmbedded` | **OFF** | メールに直接埋め込まれた画像 (cid: インライン画像 / 画像添付)。以前は無条件で自動表示していたが、既定 OFF に変更。 |
| リモート画像を自動で読み込む | `images.autoShowRemote` | **ON** | 外部サーバーから読み込む画像。以前は既定でブロック + バナー表示だったが、既定 ON に変更。設定画面に「開封トラッキング」の注意書きを表示。 |

いずれも `HTMLMessageView` の「画像を表示」系バナー (埋め込み用・
リモート用の2つ、独立に動作) が手動解除手段として残る — 設定が OFF の
メールでもバナーをタップすればそのメールだけ一時的に表示できる。バナーの
状態はメールごと・アプリセッションの間だけで、別のメールを開く・
アプリを再起動すると設定の既定値に戻る。

`HTMLMessageView` は `@AppStorage` ではなく `init` で
`UserDefaults.standard.bool(forKey:)` を直接読む (`UserDefaults
.registerOtegamiImageDefaults()` を `AppEnvironment.init()` から起動時に
一度呼び、未設定キーでも正しい既定値に解決されるようにしてある) —
理由は `HTMLMessageView` の doc comment 参照 (メールを開くたびに新しい
インスタンスが作られるため、`@AppStorage` の「初回読み取り時だけ default
引数が効く」という挙動と相性が悪い)。

## リンク (C7)

`LinkBrowserSettingsStore.swift`。**iOS のみ** — `SFSafariViewController`
(「アプリ内ブラウザ」) は iOS/iPadOS 専用の API のため、macOS にはこの
設定自体が無く、メール内リンクは常にシステムのデフォルトブラウザで開く。

| 項目 | キー | 既定値 | 説明 |
| --- | --- | --- | --- |
| リンクを開く方法 | `links.openInAppBrowser` | アプリ内ブラウザ | 「アプリ内ブラウザ」(`SFSafariViewController` を sheet 表示) か「デフォルトブラウザ」(`UIApplication.shared.open`) を選べる。HTML 本文・テキスト本文どちらのリンクにも適用される。 |

この開発機のシミュレータ/ツールチェーン (Xcode-beta.app, iOS 27 beta) では
実リンクタップ時に `WKNavigationDelegate.decidePolicyFor`/`WKUIDelegate
.createWebViewWith` が一切呼ばれないというプラットフォーム側の異常が
あったが (実機でも再現確認済み)、`WKWebView.url` の KVO 監視による委譲
非依存のフォールバック (`HTMLWebViewCoordinator.strayNavigationObservation`)
で解決済み。詳細・検証結果は `docs/verify.md` の C7 節参照。

## アカウントのラベル色 (実機フィードバック第2弾: D)

`AccountRecord.labelColorKey` (migration v22)。設定 →「アカウント」→ 各
アカウントの編集画面 (`AccountEditView`) の「ラベル色」セクションから、
`OtegamiAccountColor` の固定8色パレット (`OtegamiAccountColor.PaletteColor`)
+「自動」を選べる。iOS・macOS 共通、Gmail/iCloud/その他 IMAP のどの `kind`
でも編集可能 (アカウント種別に関係ない見た目の設定のため)。

- **既定値・「自動」**: `nil`。既存の FNV-1a ハッシュによる固定パレット
  割り当て (`OtegamiAccountColor.color(for:)`) がそのまま使われる — 移行
  前のアカウント全件、およびユーザーが明示的に選び直していないアカウント
  はこの状態のまま。
- **反映範囲**: `AccountColorRail` (一覧のアカウント色罫線)・`SenderAvatar`
  (一覧・スレッド詳細の送信者アイコン背景) の両方 —
  `OtegamiAccountColor.color(for:override:)` を経由する箇所すべて。
- **iCloud 同期**: `CloudAccountSnapshot.labelColorKey` として他の非秘匿
  フィールドと同様に同期される (`docs/icloud-sync.md`) — 端末間で選んだ色
  が揃う。

## アカウントの並び替え

`AccountRecord.sortOrder` (migration v25、既存アカウントは現在の表示順
= createdAt 順で初期化)。設定 →「アカウントの設定」のアカウント一覧で
ドラッグして並び替えられる — iOS は `EditButton` (`settings.accounts
.editButton`) をタップして編集モードに入ってからドラッグハンドルが出る
通常の流儀 (`MessageToolbarSettingsView`の「常時編集モード」とは違い、
このリストは `NavigationLink`によるアカウント編集画面への遷移とスワイプ
削除も同居しているため、常時編集モードにすると両方を潰してしまう)。
macOS は元々編集モードなしでドラッグ並び替えできる (`List`+`.onMove`の
プラットフォーム標準の挙動、`MessageToolbarSettingsView`のドキュメント
コメント参照) ため `EditButton` は iOS のみ表示。

- **反映範囲**: `AppEnvironment.accounts`(アカウント一覧を裏で支える
  唯一の`ValueObservation`、`ORDER BY sortOrder, createdAt`)を経由する
  画面すべて — 設定のアカウント一覧、ハンバーガーメニューのアカウント
  セクション (`FolderListSheet`)、統合トレイのアカウント絞り込みチップ
  (`AccountFilterChipRow`)、Composer の差出人ピッカー。個別の画面ごとに
  並び替えロジックを持たせる必要はなく、`AppEnvironment.reorderAccounts
  (_:)`がこの1クエリの元データを書き換えるだけで全画面に伝播する。
- **新規アカウント**: `AppEnvironment.nextAccountSortOrder()`(現在の
  最大値+1) を作成時に採番し、常に一覧の末尾に追加される (`AccountSetupView`
  /`ICloudAccountSetupView`/`createGmailAccount`のいずれも)。
- **iCloud 同期**: `CloudAccountSnapshot.sortOrder` として同期される
  (`docs/icloud-sync.md`) — 端末間で並び順を揃えるのが自然な設定のため、
  `labelColorKey`と同様に last-writer-wins の対象。`defaultSignatureId`
  のようなデバイスローカルな id とは異なり、並び順は端末をまたいで意味を
  持つ値のため同期対象にした。

## アプリアイコンの未読バッジ (実機フィードバック第2弾: H → 第3弾: G で on/off トグルを削除)

統合受信トレイ基準 (`MessageQuery.unifiedInboxUnreadCountObservation`、
既存のハンバーガーメニュー/macOS サイドバーの未読数表示と同じクエリを
再利用) の未読数をアプリアイコンに表示する。

実機フィードバック第3弾 (G): アプリ内蔵の on/off トグル
(`BadgeSettingsStore`、設定 →「その他」) を**廃止した** — 代わりに **iOS
の通知設定 (設定 → 通知 → otegami → バッジ)** に完全に従う。
`AppEnvironment.restartBadgeObservationIfNeeded(accountIds:)` が
`UNUserNotificationCenter.current().notificationSettings().badgeSetting`
を確認し、`.enabled`でなければ`BadgeCenter.setBadge(count: 0)`にして
未読監視自体を開始しない — OS 側で有効なら常に未読数を反映する。この
チェックはアプリがフォアグラウンドへ戻るたびにも再実行される
(`RootView.handleScenePhaseChange(.active)` → `environment
.refreshBadgeObservation()`) — OS の通知設定はこのアプリがバックグラウ
ンドの間にいつでも変更されうり、変更を検知する通知の仕組みが無いため。
`BadgeSettingsStore`自体は削除済み (`badge.enabled`キーの残骸は無視して
問題ない)。

- **通知許可**: `PushTokenCenter` (プッシュ通知の opt-in、`[.alert, .badge,
  .sound]`) とは独立に、`BadgeCenter.requestAuthorizationIfNeeded()` が
  `.badge` のみを要求する。自宅サーバーの otegami-relay を使わないユーザー
  でも、ローカル同期だけでバッジは機能する。
- **更新契機**: `AppEnvironment` が `unifiedInboxUnreadCountObservation` を
  常時購読しているため、既読操作・同期・フォアグラウンド復帰など未読数に
  影響するすべての操作で自動的に更新される (専用のイベントハンドラ不要)。
- **プッシュ受信時のインクリメント**: `NotificationService` Extension は
  新着プッシュのたびに App Group 共有 `UserDefaults` (`badge.sharedCount`)
  の値を+1し、通知の `content.badge` にセットする (Extension が直接
  `setBadgeCount` を呼ぶのではなく、配信される通知の `badge` プロパティに
  設定するのが Extension からバッジを更新する正規の方法)。Extension は
  新着メッセージをローカル DB に書き込むわけではない (表示用の envelope
  読み取りのみ) ため正確な未読数を計算できず、暫定的な+1に留まる —
  次にメイン app 側の `ValueObservation` が発火した時点で正しい数へ
  自己修正される。
- **macOS**: `NSApplication.dockTile.badgeLabel` (権限不要) — 通知設定の
  確認は iOS 限定 (`#if os(iOS)`)。App Group がそもそも存在しない
  (`OtegamiAppGroup.identifier` が常に `nil`) ため Extension 連携の対象外
  — メイン app プロセス内の同じ `ValueObservation` だけで完結する。

## デフォルトのアカウント (実機フィードバック第2弾: G)

`DefaultAccountSettingsStore`。キー `account.defaultAccountId`、既定は未設定
(空文字列)。**未設定時、またはアカウント削除等で無効な値になっている時は
従来どおり「先頭のアカウント」にフォールバックする** — 常に何らかの
アカウントが選ばれている状態を保証する。

`ComposerView` の**新規メール作成時のみ**この設定を参照する — 返信・転送・
下書きは元のメッセージ/下書きが属するアカウントを常に使う (この設定より
優先度が高い、そもそも「デフォルト」という概念が意味を持たない)。設定 UI
は現状アカウント編集画面ではなく (D「ラベル色」/F「デフォルト署名」とは
異なりアカウント単位の設定ではないため) 今後の設定画面再構成 (下記「設定
画面の再構成」参照) の中に配置する。

## メール削除/アーカイブ時の挙動 (実機フィードバック第2弾: G)

`MessagePostActionSettingsStore`。キー `messageAction.afterDeleteArchive`、
選択肢は「メール一覧に戻る」(既定、この設定が導入される前からの唯一の挙動
と完全に一致させてある) / 「次のメールを開く」。

- **適用範囲**: メール本文画面 (`ThreadDetailView`) の「…」メニューからの
  削除・アーカイブ・迷惑メール操作、および macOS の ⌘⌫ (`RootView
  .deleteSelectedThread()`)。**一覧画面のスワイプ/コンテキストメニュー/
  一括選択からの削除・アーカイブには適用されない** — 一覧はその場で行が
  消えるだけで「次に何を開くか」という問いがそもそも発生しないため。
- **「次のメールを開く」の判定**: `MessageListView` が最後に報告した
  画面上のスレッド順序 (`onSummariesChanged`) の中から、削除・アーカイブ
  したスレッドの次の行を開く。次が無ければ (リストの最後だった場合) 1つ
  前の行を開く。それも無ければ (リストにそのスレッドしか無かった場合)
  一覧に戻る。iOS (`MailScreenView`)・macOS (`RootView` の3ペイン) の両方
  に同じロジック (`MessagePostActionSettingsStore.nextThreadId(after:in:
  action:)`) を適用している。検索結果画面 (`SearchScreenView`) から開いた
  メール本文には適用されない (検索結果の順序は一覧とは別の並びであり、
  このバッチのスコープ外と判断した)。

## 署名テンプレート (実機フィードバック第2弾: F)

`SignatureTemplateRecord` (GRDB テーブル `signatureTemplate`、migration
v23)。設定 →「署名テンプレート」で追加・編集・削除。iOS・macOS 共通。C8
の「テンプレート」(`MailTemplateRecord`) とは別機能・別テーブル — 詳細は
`SignatureTemplateRecord` のドキュメントコメント参照 (テンプレートは全文
定型、署名は本文末尾への付加。テンプレートの `accountId` は単一 optional
だが、署名の `accountIds` は複数選択できる配列)。

- **項目**: 名前、使用するアカウント (複数選択可)、本文。
- **アカウント編集画面 (`AccountEditView`) の「デフォルト署名」**:
  `AccountRecord.defaultSignatureId` (migration v24、参照先の署名が削除
  されると `onDelete: .setNull` で自動的に `nil` に戻る)。そのアカウントに
  使用可能として選択されている署名の中から選べる。**iCloud 同期の対象外**
  — `signatureTemplate.id` は端末ローカルの自動採番値で、端末をまたいで
  同じ意味を持たない (`AccountRecord.id` のような UUID とは異なる) ため、
  そのまま同期すると別端末では無関係または存在しない行を指してしまう。
  署名テンプレート自体の iCloud 同期は今回のスコープでは実装していない。
- **Composer (作成画面) の「署名」欄**: 差出人アカウントに使用可能な署名が
  1つ以上あるときだけ Picker が表示される (「なし」+ 各署名名)。選択すると
  本文末尾に挿入され、別の署名に切り替えると直前に挿入した文字列だけを
  正確に取り除いてから新しい署名を挿入する (`ComposerView
  .updateSignatureText(newId:)`)。
- **デフォルト署名の自動挿入は新規作成時のみ**: 返信・転送・下書き復元では
  自動挿入しない (本文の非同期プリフィル処理と競合するリスクを避けるため
  の意図的なスコープ判断)。返信・転送でも「署名」欄から手動で選べる。

## テンプレート (C8)

`MailTemplateRecord` (GRDB テーブル `mailTemplate`、migration v17)。設定 →
「テンプレート」で追加・編集・削除。iOS・macOS 共通。

**設計判断: テンプレートは全体で1つのフラットなリストとして管理し、
各テンプレートに任意で「使用するアカウント」を設定できる形にした**
(`accountId` 列、`nil` = 全アカウントで使用可能)。「アカウントごとに設定
できる」の2通りの解釈 (①各テンプレートが特定アカウント専用、②アカウント
ごとにデフォルトテンプレートを持つ) のうち①寄りの実装だが、
「アカウントを指定しない」を既定にすることで②の「全アカウント共通の
署名的テンプレート」というニーズも1つの仕組みでカバーできる。②の
「アカウントごとのデフォルト」(複数ある候補から自動選択) は、Composer
を開くたびに毎回選び直す方式より複雑になる割に得られる価値が小さいと
判断し見送った。

- **項目**: 名前、使用するアカウント (すべて/特定の1つ)、件名 (任意)、
  本文。
- **Composer からの呼び出し**: 「添付ファイル」の下に「テンプレート」
  セクションが (使えるテンプレートが1つ以上あるときだけ) 出現し、
  「テンプレートを挿入」メニューから選ぶ。**件名・本文が両方空の状態
  (新規作成直後) でテンプレートに件名があれば、件名・本文の両方が
  そのテンプレートの内容に置き換わる (定型メール全体としての使い方)。
  それ以外 (すでに何か書いている、またはテンプレートに件名が無い) の
  場合は本文の末尾に追記される (署名的な使い方)。**
- 選べるテンプレートは、Composer の「差出人」で選択中のアカウントに
  応じて絞り込まれる (`accountId IS NULL OR accountId = <選択中の
  アカウント>`) — 差出人を切り替えると一覧も追従する。

## ピン留め

`PinSettingsStore.swift`。iOS・macOS 共通。

| 項目 | キー | 既定値 | 説明 |
| --- | --- | --- | --- |
| サーバーのフラグ (`\Flagged`) と連動 | `pinning.syncWithFlagged` | OFF | OFF の間、ピン留めは otegami だけのローカルな印 (`MessageRecord.isPinnedLocal`)。ON にすると、ピン留め/解除のたびに IMAP の `\Flagged` フラグも更新し (`setFlags` opQueue 経由)、サーバー再同期のたびに現在の `\Flagged` を読み取ってピン留め状態に反映する (他クライアントでのフラグ操作も拾える)。 |

ピン留めされたメール/スレッドは一覧の**最上位**に来る (`ThreadQuery` の
`ORDER BY isPinned DESC, lastMessageDate DESC, ...`)。スレッド内の
1通でもピン留めされていれば、スレッド自体が最上位になる
(`ThreadRecord.isPinned` は所属メッセージの `isPinnedLocal` の OR
集計、`ThreadAssigner.recomputeAggregates` が保守)。

## 送信キャンセル (iOS のみ)

`SendCancelSettingsStore.swift`。**iOS のみ** — macOS の作成画面は
シート化された iOS と違い独立ウィンドウで、常設のタブバーの上にバーを
出す自然な置き場所が無いため、macOS は送信ボタンを押した時点で
即座に送信される (design-phase-3 以前と同じ挙動)。

| キー | 既定値 | 選択肢 |
| --- | --- | --- |
| `sendCancel.window` | 5秒 | なし / 5秒 / 10秒 |

**30秒・60秒はあえて選択肢から外してある**: iOS はバックグラウンドに
回ったアプリを任意のタイミングで凍結・一時停止できるため、
`beginBackgroundTask` の猶予時間には確定的な保証が無い。長い待機時間を
提示すると「キャンセル可能な時間が残っている」という約束を守れないこと
があるため、確実に運用できる短い時間だけを提示している。

**アプリを離れると即座に送信が確定する**: カウントダウン中にアプリを
バックグラウンド/非アクティブへ切り替えると、残り時間に関わらずただちに
送信処理へ進む (`PendingSendCoordinator.finalizeNow()`、
`RootView.handleScenePhaseChange` から呼ばれる)。これは意図的な仕様
— バックグラウンドでカウントダウンを継続する保証ができないため。

**送信の消失防止**: 「送信」を押した瞬間に、下書きの内容はまず
`outboxMessage` テーブル + `opQueue` の `send` オペレーションとして
ローカル DB に確定保存される (この時点で `OutboxAttachmentRecord` も
含め永続化済み)。カウントダウン・キャンセルの仕組みはすべて「いつ
ネットワークに実際に投げるか」だけを制御しており、アプリがどのタイミング
で終了・強制終了されても、次回起動時の通常の opQueue リプレイが未送信の
メールを拾って送信する。カウントダウンが終わった瞬間 (または離脱で
即時確定した瞬間) の実際の送信は iOS の `beginBackgroundTask` で
バックグラウンド猶予を確保してから行う。

**「送信を取り消す」**: カウントダウンバー上のボタンをタップすると、
ローカルに書き込んだ `outboxMessage`/`outboxAttachment`/`opQueue` の
`send` 行を削除し (真の取り消し — サーバーには一切送信されない)、
同じ宛先・件名・本文・添付ファイルで Composer を再度開く
(`ComposerLaunchPayload.Kind.cancelledSend`)。

## 翻訳 (既存)

`TranslationSettingsStore.swift`。

| 項目 | キー | 既定値 |
| --- | --- | --- |
| 英文を自動で翻訳 | `translation.autoTranslateEnglish.v2` | **OFF** (実機フィードバック「翻訳機能は、勝手に実行しないで欲しい」を受けて design-phase-3 の ON から変更、キーも `.v2` にリネーム — `docs/translation.md`「実機フィードバック: 「勝手に翻訳しないで」「HTML はレイアウトを保って」」節参照。OFF でも翻訳バー自体は英文メールに表示され、「翻訳」ボタンを押した時だけ翻訳する) |
| 一覧に要約を出す | `translation.showListSummaryInList` | OFF (設定項目のみ存在し、一覧側は現状未実装 — `docs/design-system.md` 参照) |

## iCloud アカウント同期 (既存)

`CloudSyncSettingsStore.swift`。キー `icloudSync.accountsEnabled`、
既定 ON。同じ Apple ID の他デバイスとアカウントの接続設定 (パスワード
以外) を同期する。詳細は [docs/icloud-sync.md](icloud-sync.md)。

## プッシュ通知 (既存)

`PushSettingsStore.swift` (Keychain 併用、`push.*` キー群)。設定 →
「プッシュ通知」から有効化。詳細は
[docs/relay-deployment.md](relay-deployment.md)。

## メール本文フッターツールバーの並び順 (新画面構成) — iOS のみ

`MessageToolbarSettingsStore.swift`。メール本文画面 (`ThreadDetailView`)
下部のフッターツールバーに並ぶ5アイコン (返信/転送/検索/情報/その他) の
順序。メール本文画面の「…」メニュー →「ツールバーをカスタマイズ」
(`MessageToolbarSettingsView`、常時編集モードの並び替えリスト) から
変更できる。

| キー | 既定値 |
| --- | --- |
| `messageToolbar.order` | `reply,forward,search,info,more` (カンマ区切り) |

有効/無効の概念は無く (5つとも常に表示)、並び順だけを変更できる。詳細・
各アイコンの動作は `docs/design-system.md`「新画面構成」節を参照。

## 表示言語 (表示・操作改善バッチ → 実機フィードバック第3弾 F で廃止)

表示・操作改善バッチで追加したアプリ内蔵の「表示言語」設定 (システムに
従う/日本語/English の3択ピッカー + 反映には再起動が必要という案内) は
**廃止した**。代わりに **iOS 標準の「アプリごとの言語」** (設定アプリ →
otegami → 言語) に委ねる — このアプリの `Info.plist` は元々
`CFBundleLocalizations: [ja, en]` を宣言しており、OS 標準機能がまさに
この用途のために存在する。OS 標準の言語切替は設定変更時に OS 自身が
プロセスを再起動するため、旧実装が抱えていた「ホーム画面に戻っただけ
では反映されない」という問題自体も構造的に解消される。

`LocalizationSettingsStore.swift`は削除せず、`effectiveLanguageCode`
(現在有効な表示言語を`Bundle.main.preferredLocalizations`から読む、読み
取り専用の計算プロパティ) だけを残した — 本文画面の翻訳ボタン表示条件・
AI要約の出力言語判定 (「メールの言語 ≠ アプリの表示言語」の判定) に
引き続き必要な機能で、廃止対象は選択 **UI** のみ。

**移行処理は削除した (タスク#43)**: 上記廃止と同時に「旧設定で明示的に
「日本語」/「English」を選んでいた既存ユーザーの端末に残る`AppleLanguages`
上書きを一度だけ削除する」移行処理 (`AppEnvironment.init()`から起動の
たびに呼ぶ`LocalizationSettingsStore
.migrateAwayFromLegacyAppleLanguagesOverrideIfNeeded()`) を入れていたが、
これが**「起動し直すと言語設定が毎回英語に戻る」という重大な実機バグの
原因**だった。iOS の「設定 → このアプリ → 言語」(OS 標準のアプリ単位
言語設定) も内部的には同じ`AppleLanguages`キーを使って実現されている —
「一度だけ削除」のつもりが実装には一度きり実行済みかを覚えるフラグが無く、
このキーに値がある限り**毎起動**削除する実装になっていたため、ユーザーが
OS 設定で選んだ言語を毎起動削除していた。
「フラグを立てて一度だけ実行にする」対処も検討したが、旧ピッカーの
存在期間はわずか約8時間 (2026-07-27 06:07 導入 → 同日13:53 廃止) で、
その残骸は廃止直後の初回起動でとっくに一度消えている — フラグ化しても
「今この瞬間まで壊れていた状態」を直す最後の一回の誤削除は避けられない
ため、移行処理自体を削除するのが最も安全と判断した。廃止済み設定の選択値
(`app.languageOption`キー) 自体は引き続き削除しない (無害な残骸)。

詳細な仕組み・ローカライズのカバレッジ範囲は
[docs/localization.md](localization.md) 参照。

## ハンバーガーメニューのアカウントセクション折りたたみ (実機フィードバック第3弾: K) — iOS のみ

`FolderSectionCollapseStore`(`FolderListSheet.swift`内)。ハンバーガー
メニュー (`FolderListSheet`) の各アカウントのメールボックスツリーは、
アカウント名の行 (セクションヘッダ) をタップして開閉できる。

- **設定項目としてではなく `UserDefaults` 直書き**: `folderSheet
  .collapsedAccountIds`キーに、折りたたみ中のアカウント ID の配列を
  保存する。ユーザーが選ぶ「設定」ではなく画面状態の記憶なので、他の
  `*SettingsStore`と違い設定画面には出てこない。
- **既定は展開**: 一度も折りたたんだことのないアカウントは常に展開状態。
- **未読バッジは折りたたみ中も表示**: `AccountSectionHeader`がそのアカ
  ウントの全メールボックスの未読数を合計して表示するため、折りたたんで
  受信トレイが見えなくなっても未読の有無は分かる。
- **シェブロンの向きで状態を表現**: `chevron.right`を展開時に90°回転
  (下向き) — `DisclosureGroup`の慣習を手動で再現したもの
  (`AccountSectionHeader`のドキュメントコメント参照、`DisclosureGroup`
  自体を使わなかった理由も記載)。

`FolderListSheet`のツールバーに常設されていた「アカウントを追加」の
「＋」ボタン (`folderSheet.addAccountToolbarButton`) は削除した — アカウント
追加は設定 (「アカウントの設定」→「アカウントを追加」) から常にできるため、
ハンバーガーメニューという別動線に同じ入口を重複させる必要がなかった。
**例外**: アカウント0件のときの空状態に出る「アカウントを追加」ボタン
(`folderSheet.addAccountButton`) は残した — 0件の状態で設定画面まで辿ら
せるのは不親切なため。

## アカウント追加/編集フォームのフィールドラベル (実機フィードバック第3弾: H)

`AccountSetupView`/`AccountEditView`/`GmailAccountSetupView`/
`ICloudAccountSetupView`の各テキストフィールド (表示名・メールアドレス・
ホスト・ポート・ユーザー名・パスワード等) に、`LabeledContent`による
永続的なラベルを付けた。以前は`TextField(プレースホルダ, text:)`のみで、
値を入力するとプレースホルダが消えるため、埋まったフィールドが何を表す
か分からなくなる問題があった。`AccountEditView`の「メールアドレス」/
「種類」(既存の`LabeledContent`) と見た目を揃えている。

## メールボックス単位の非表示

`MailboxRecord.isHidden` (migration v26)。設定 →「アカウントの設定」→
各アカウントの編集画面 (`AccountEditView`) →「メールボックスの表示設定」
(`MailboxVisibilityView`、新規画面) から、そのアカウントのメールボックス
一覧を表示/非表示に個別切替できる。iOS・macOS 共通。主用途は Gmail の
`[Gmail]/すべてのメール`のような、INBOX と重複した内容を持つ大量フォルダ
をハンバーガー/サイドバーのツリーから隠すこと。

- **非表示にすると消える範囲**: ハンバーガーメニュー/サイドバーの
  メールボックスツリー (`MailboxQuery.request(accountId:includeHidden:
  false)` を `SidebarView`/`FolderListSheet` の両方が使う)、macOS の
  ⌘]/⌘[ によるメールボックス切り替え循環 (`OtegamiApp
  .cycleMailboxSelection`)、統合受信トレイの一覧・未読数集計
  (`ThreadQuery.unifiedInboxRequest`/`unifiedInboxFlatSummaries`,
  `MessageQuery.unifiedInboxUnreadCount` に `mailbox.isHidden = 0` 条件を
  追加 — 実務上意味を持つのは inbox ロールのメールボックス自体を隠した
  場合のみで、Gmail の「すべてのメール」(role `.all`) はそもそも統合
  受信トレイの集計対象外)。
- **同期も止める** (`AccountSyncer.performIncrementalSync`の`.all`スコープ
  = 手動フル更新から除外。`.inboxOnly`/`.mailbox(path:)`はそもそも INBOX
  や、ツリー経由で選ばれた=非表示ではないメールボックスしか対象にしない
  ため個別のチェックは不要)。**判断理由**: 電池・通信の節約。「すべての
  メール」のような巨大フォルダを同期し続ける実利が薄く、隠した以上は
  差分同期の対象からも外すのが利用者の意図に合うと判断した。
- **移動先ピッカーには出す (操作対象からは消さない)**: このアプリには
  まだ汎用の「移動先」ピッカー自体が存在しない (`docs/design-system.md`
  「次フェーズへの申し送り」参照) — 実装される際は`MailboxQuery
  .request(accountId:)`の既定`includeHidden: true`のまま使う想定。
  **判断理由**: 「表示したくない」と「操作対象として選べなくしたい」は
  別の要求であり、後者まで一緒に潰すと「非表示にしたメールボックスへは
  二度とメールを移動できない」という意図しない制約になってしまうため。
- **サーバー側の再一覧化で消えない**: `AccountSyncer.upsertMailboxes`は
  `IMAP LIST`のたびに全メールボックスを再 upsert するが、`isHidden`列は
  `.noOverwrite`で保護しているため、次回同期でユーザーの選択が勝手に
  戻ることはない。
