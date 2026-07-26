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
| スレッドにまとめない (フラット表示) | `listDisplay.flatMode` | OFF | ON にすると一覧がスレッド単位ではなくメール単位になる (`ThreadQuery.flatSummaries`/`unifiedInboxFlatSummaries`)。検索結果 (macOS のインライン検索・iOS の検索タブ) には適用されない — 検索は従来通りスレッド単位 (`MessageListView` のドキュメントコメント参照)。スワイプ/コンテキストメニューの各操作は、フラット表示の行から実行した場合でも**そのメールが属するスレッド全体**に対して働く (既存のグループ表示と同じ挙動に揃えてある)。 |
| 送信者のプロフィールアイコンを表示 | `listDisplay.showAvatar` | ON | 一覧の各行に、差出人のイニシャル + アカウント色の丸アイコン (`SenderAvatar`) を表示する。外部サービス (Gravatar 等) には一切問い合わせない。 |
| 本文プレビューの行数 | `listDisplay.previewLineCount` | 1行 | なし / 1行 / 2行 / 3行 から選択。 |
| メール本文にも送信者アイコンを表示 | `listDisplay.showAvatarInDetail` | ON | 詳細画面 (スレッド内の各メッセージのヘッダ) にも同じ `SenderAvatar` を表示する。 |

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
