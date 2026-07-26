# 設定項目一覧

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

**削除・迷惑メールは常にタップ確定** (`SwipeAction.isGuardedFromFullSwipe`):
「短いスワイプ」の位置に削除/迷惑メールを割り当てても、フルスワイプでは
発火しない — ボタンが表示された状態からの明示タップのみで実行される。
これは SwiftUI の `.swipeActions` が「宣言順の最初の1つだけがフルスワイプ
で自動発火できる」という制約の上で、誤操作防止を優先した意図的な設計
(`docs/design-system.md` の design-phase-2 節を参照)。既読/未読・
アーカイブ・ピン留めはワンタップで元に戻せる操作なので、フルスワイプ
対象にできる。

## 一覧・表示

`ListDisplaySettingsStore.swift`。iOS・macOS 共通。

| 項目 | キー | 既定値 | 説明 |
| --- | --- | --- | --- |
| スレッド表示 | `listDisplay.threading` | ON | ON で一覧を会話 (スレッド) 単位にまとめる。OFF にすると一覧がメール単位になる (`ThreadQuery.flatSummaries`/`unifiedInboxFlatSummaries`)。検索結果 (macOS のインライン検索・iOS の検索タブ) には適用されない — 検索は従来通りスレッド単位 (`MessageListView` のドキュメントコメント参照)。スワイプ/コンテキストメニューの各操作は、フラット表示の行から実行した場合でも**そのメールが属するスレッド全体**に対して働く (既存のグループ表示と同じ挙動に揃えてある)。 |
| 送信者のプロフィールアイコンを表示 | `listDisplay.showAvatar` | ON | 一覧の各行に、差出人のイニシャル + アカウント色の丸アイコン (`SenderAvatar`) を表示する。外部サービス (Gravatar 等) には一切問い合わせない。 |
| 本文プレビューの行数 | `listDisplay.previewLineCount` | 1行 | なし / 1行 / 2行 / 3行 から選択。 |
| メール本文にも送信者アイコンを表示 | `listDisplay.showAvatarInDetail` | ON | 詳細画面 (スレッド内の各メッセージのヘッダ) にも同じ `SenderAvatar` を表示する。 |

## メールの表示 (A9)

`HTMLDisplaySettingsStore.swift`。iOS・macOS 共通。

| 項目 | キー | 既定値 | 説明 |
| --- | --- | --- | --- |
| 常にテキストで表示 | `htmlDisplay.alwaysShowPlainText` | OFF | ON にすると、HTML メールを開いたときの既定表示がテキスト (`text/plain` パートがあればそれ、無ければ `HTMLTextExtractor` の抽出結果) になる。メール詳細画面の切替ボタン (件名の下、"テキストで表示"/"HTMLで表示") でメールごとに一時的に上書きできる — この上書きはそのメールを開いている間だけで、別のメールを開くとこの設定の既定に戻る。 |

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

既知の制約: この開発機のシミュレータ/ツールチェーン (Xcode-beta.app,
iOS 27 beta) では、実リンクタップ時に `WKNavigationDelegate
.decidePolicyFor` が呼ばれないという未解決の環境依存の問題があり、
自動検証・目視確認とも green にできなかった (詳細は `docs/verify.md`
の C7 節)。JavaScript は引き続き無効なままなので実害は無いと判断して
いるが、Xcode 安定版での再検証が今後の課題。

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
| 英文を自動で翻訳 | `translation.autoTranslateEnglish` | ON |
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

## 表示言語 (表示・操作改善バッチ)

`LocalizationSettingsStore.swift`。設定 →「表示言語」セクションの
Picker (`.pickerStyle(.menu)`) から「システムに従う」「日本語」
「English」を選ぶ。

| キー | 既定値 |
| --- | --- |
| `app.languageOption` | `system` (`AppLanguageOption.system`) |

選択は `AppleLanguages`(`UserDefaults`標準キー) の上書きも兼ねる —
`.system`なら`AppleLanguages`を削除してOS本来の言語解決に戻し、`.ja`/
`.en`ならその1言語だけの配列を書き込む。**変更の反映にはアプリの再起動
が必要** (設定画面にもその旨のfooterを表示) — `Bundle.main`のローカライズ
解決はプロセス起動時に一度だけ行われるため。詳細な仕組み・ローカライズ
のカバレッジ範囲は [docs/localization.md](localization.md) 参照。
