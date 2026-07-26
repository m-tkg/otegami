# QA 探索的スイープ: 所見メモ

`docs/verify.md` に記録済みの実機バグ4連発 (VoIP ソケット/部分同期→スレッド
未割当/空応答→全削除/状態復元→UI崩壊・livelock) を踏まえ、シミュレータ上で
実ユーザーの雑な操作列 (kill/再起動連打、画面遷移の乱打、同期中の操作、
オフライン遷移の組合せ、Composer 境界ケース、境界データ、設定往復) を
`OtegamiQASweepUITests`/`OtegamiQASweepScenario2UITests`/
`OtegamiQASweepOfflineUITests` として XCUITest 化して実行したセッションの
所見。バグを見つけて修正できたものは各コミット + `docs/verify.md` に記録済み
(コールドランチがサイドバー最上位を素通りする問題、直前に選択していた行の
再タップが効かない問題 — commit `19fc366`)。本ファイルには、それ以外の
「修正不能級/設計判断が要る」項目、および「軽微な見た目の違和感 (真バグで
ないもの)」を記録する。

## 実機フィードバック第2弾: Gmail でアーカイブが効かない実バグの原因と修正

**症状**: 実 Gmail アカウントでスレッド/メールをアーカイブしても、サーバー
側に何も反映されない (INBOX から消えない)。

**原因**: `MessageListView.commitArchive(_:)`/`ThreadDetailView
.archiveThread()` は「アカウントの `MailboxRole.archive` メールボックスへ
`OpQueue.enqueueMove`」という実装だったが、**Gmail には `\Archive`
special-use のメールボックスが存在しない** — Gmail の「すべてのメール」は
IMAP の `SPECIAL-USE` 拡張で `\All` を返し、このアプリは `\All` を
`MailboxRole.all` (`.archive` とは別の値) にマッピングしている
(`MailCoreIMAPSession+Mapping.role(for:path:)`)。結果、Gmail アカウントでは
ローカルの Archive-role ルックアップが常に `nil` を返し、`commitArchive`
自身が「アーカイブ先が無い」と判断してアーカイブ操作全体を**サイレントに
何もしない**まま終わっていた (opQueue に一切 enqueue されない — ローカル
DB からの削除すら起きない実装だったので、UI 上も何も変化しないまま失敗
していたことになる)。

**修正**: `OpQueueKind.archive` (`ArchiveOpPayload`) を新設し、宛先の解決を
「enqueue 時に UI 側で決める」から「`.delete`/`.junk` と同じく replay 時に
`OpQueueProcessor` が決める」方式に変更した。

- **Gmail アカウント (`account.kind == .gmail`)**: 宛先メールボックスの
  解決を一切試みず、ソースメールボックス (例: INBOX) に対して
  `STORE +FLAGS \Deleted` → `EXPUNGE` のみを行う (COPY はしない)。これは
  Gmail の「アーカイブ = INBOX ラベルを外すだけ」という実際の意味論に
  対応する IMAP 操作で、「すべてのメール」には Gmail 側が自動的にメール
  を残し続ける (Spam/Trash に入っていない限り) ため、明示的な COPY は不要。
- **それ以外のアカウント (generic IMAP・iCloud)**: 従来どおり
  `MailboxRole.archive` のメールボックスへ `MOVE`。ローカルに未同期の
  場合は `resolveOrCreateArchiveMailbox` (`Trash`/`Junk` と同じ
  CREATE+再list による自動作成パターン) で解決し、それでも失敗する場合は
  op を pending のまま残す (ユーザーの意図した操作を無言で消さない、
  既存の `.delete`/`.junk` と同じ方針)。

`packages/OtegamiKit/Tests/SyncEngineTests/OpQueueProcessorTests.swift` に
4件のテストを追加: 通常アカウントでの Archive 解決+move、Archive
メールボックス自動作成、自動作成失敗時に pending のまま残ること、Gmail
アカウントでの in-place unlabel (STORE+EXPUNGE のみ、move は一切試みない
こと) を `FakeIMAPSession`/`CallRecorder` で検証済み。

**未検証事項**: 実 Gmail アカウントでの動作確認 (`FakeIMAPSession` による
契約テストのみ)。`PENDING.md` に記録した。

## 修正した実バグ (再掲・参照)

- コールドランチが (サイドバー最上位ではなく) 統合受信トレイ/メッセージ一覧
  から始まる。修正: `apps/Otegami/Sources/OtegamiApp.swift`/`SidebarView.swift`。
  詳細は `docs/verify.md`「実機バグ (続報2)」節。
- 「直前に選択していた行」(統合受信トレイ、開いていたスレッド) だけ再タップ
  してもタップ不能。同上の修正でカバー。

## 深掘りしたが「バグではなかった」項目 (記録価値のある調査)

### オフライン中の既読スワイプが「サーバーに反映されない」ように見えた件

`OtegamiQASweepOfflineUITests` 初版で、オフライン中に一覧の直前フェーズが
開いた (=ローカルで既読化された) メッセージを、続くフェーズでさらに
「既読にする」スワイプすると、`toggleRead` の意図通りの動作 (=すでに既読
なので未読への toggle) が実行され、結果としてサーバー側では未読のまま
になる。`sqlite3` で `otegami.sqlite` を直接見て `message.flagsRaw`/`opQueue`
テーブルの中身を突き合わせ、両方のオフライン操作 (開封時の既読化 opQueue
エントリ、スワイプの取り消し opQueue エントリ) が両方とも正しく enqueue
され、オンライン復帰後どちらも正しく replay されていたことを確認 — バグは
テストシナリオの設計 (同じメッセージに対して衝突する2つの操作を意図せず
積んでいた) 側にあり、アプリのロジックは正しかった。詳細は commit
`e7ed426` のコミットメッセージ、および `.claude/skills/verify/SKILL.md` の
今回追加分を参照。

## 軽微な所見・今後の検討事項 (真バグではない)

- **`.confirmationDialog`/`Alert` のアクションボタンが XCUITest の完全一致
  identifier lookup で over-count する**: `.claude/skills/verify/SKILL.md`
  に記録済み。アプリの表示自体は正しい (実際のスクリーンショットで確認済み)
  — XCUITest 側の `.firstMatch` が必要なだけ。
- **空になった `TextField` の `XCUIElement.value` がプレースホルダーを
  エコーする**: 同上、SKILL.md に記録済み。`composer.sendButton` の
  `Disabled` トレイトなど、依存する UI 信号のほうが信頼できる。
- **dev mailstack の iCloud KVS 実アカウント汚染**: このセッション中、
  `simctl erase` 直後でも実 iCloud 経由で過去の verify 実行分のアカウント
  (test1/test2) が resurrect する現象に何度も遭遇した (M11 で既知、
  `docs/verify.md` に記録済み)。新規に追加した QA スイープ系テストは全て
  「アカウントが既に存在する場合はスキップ」の防御的パターンを踏襲済みで
  実害は無いが、今後このセッションで作られた大量の verify 実行履歴により
  `Dovecot Test1`/`Dovecot Test2` アカウントが今後の `simctl erase` 後も
  居座り続ける可能性がある点は留意 (対処は "本来の権限の外" — ユーザー側で
  iCloud 設定からのリセットが必要)。
- **dev mailstack の Dovecot 認証がこの開発機の高負荷時に単発でタイムアウト
  する**: このセッション中、`accountSetup.testConnectionButton` からの
  接続テストが2回、「認証に失敗しました」で失敗した (dovecot 側ログで
  `auth_request_finished` の `duration` が通常10ms程度のところ1483msに
  伸びていたことを確認 — クライアント側のタイムアウトが先に切れたと見られる)。
  いずれも即座の再実行で再現せず、本セッション中に多数の `xcodebuild`/
  `docker`/`simctl` プロセスを同時多発的に走らせたことによる一過性の
  リソース枯渇と判断 (`docs/verify.md` の M2/M11 節に既出の同種の flake と
  同じ扱い)。アプリ側のリトライ/タイムアウト設定を見直す価値があるかは
  今後の検討課題として残す (実プロバイダに対しては起きにくいと見られる)。
- **境界データ (件名なし・本文空メール) の表示は正常**: `(件名なし)` の
  フォールバック表示、本文が空のメールを開いた際のクラッシュ無し、を
  スクリーンショットで目視確認済み (`OtegamiQASweepScenario2UITests
  .testNoSubjectAndEmptyBodyMessagesDisplayGracefully`)。既存の
  `ThreadRow.subjectText`/`MessageView` のフォールバック実装で十分だった。
- **検索の境界クエリ (0件・1文字・記号 `% _ "`・絵文字) はいずれもクラッシュ
  /ハングせず**、結果またはからっぽ状態のいずれかに正しく収束することを
  確認済み (`OtegamiQASweepScenario2UITests.testBoundarySearchQueries`)。
  SQLite の `LIKE`/FTS5 エスケープ周りで `%`/`_` が特殊文字として素通し
  されている可能性はあるが (`SearchQuery` のエスケープ処理は本調査の対象
  外)、少なくともクラッシュ・無限ローディングには繋がらないことは確認済み。
  `%`/`_` を含む検索が「意図しない広いマッチ」を返していないかは、
  `SearchQuery` の実装を読んだ厳密な検証まではこのセッションでは行って
  いない — 今後 `LIKE` エスケープの単体テストを追加する価値はあるかもしれ
  ない。

## 総回帰で見つかった、この開発機固有の既存の不整合 (QA スイープと無関係)

- **`OtegamiM6TypeSelectionUITests.testAllThreeAccountTypesAreOfferedAndGmailIsDisabledWithoutAClientId`
  がこの開発機では失敗する**: `apps/Otegami/Config/Local.xcconfig` に実の
  `GOOGLE_OAUTH_CLIENT_ID` が設定されているため (この開発機で Gmail OAuth
  の実機能を検証する目的と見られる)、Gmail ボタンは実際には有効になる —
  「Client ID 未設定なら無効化される」というテストの前提とこの開発機の
  ビルド設定が根本的に食い違っている。QA スイープの変更とは無関係な
  pre-existing の環境依存 (このテストは `GOOGLE_OAUTH_CLIENT_ID` が空の
  ビルドでのみ通る設計)。`scripts/verify-ios-m6.sh` の他フェーズ
  (`OtegamiM6ICloudFormUITests`/`OtegamiM6OtherAccountFlowUITests`/
  `OtegamiM6TypeSelectionUITests.testCancelDismissesTheTypeSelectionSheet`)
  は個別実行では正常に green (`set -euo pipefail` により、このテストの
  失敗でスクリプト全体が早期終了していただけ)。対応不要 — このテストを
  「常に green」にするには `GOOGLE_OAUTH_CLIENT_ID` を空にしたビルドで
  別途実行する仕組みが要るが、それは今回のタスクの範囲外と判断した。

- **`OtegamiM9PushSettingsUITests.testEnablingPushOnSimulatorShowsGracefulDegradationMessage`
  が `simctl erase` 直後の初回実行でのみ間欠的に失敗する**: consent alert
  タップ後、`settings.push.errorMessage` が最大40秒待っても現れないことが
  数回に1回発生した。同じシミュレータを erase せず使い回す再実行では毎回
  再現せず (`sidebar.settingsButton` 到達性の別問題は
  `returnToSidebarRootIfNeeded` 追加で修正済み — こちらは別件)。この
  セッション中ずっと `load average` が 264 前後という高負荷状態だったこと
  (`uptime`/`docker stats` で確認済み) と、`simctl erase` 直後の初回起動は
  Keychain access group のプロビジョニングや GRDB 初期化などの一度きりの
  セットアップコストが乗ることを踏まえると、機体負荷起因の一過性遅延と
  判断 (`registerForRemoteNotifications()` 自体は権限プロンプトを出さない
  ため、システムダイアログが割り込んでいる可能性は低い)。タイムアウトを
  20秒→40秒に伸ばした上でなお時々失敗するため、真の意味での確定的な修正
  ではないが、実装コード自体に手を入れる根拠 (実機/低負荷環境での再現)
  はこのセッションでは得られなかった。

- **`OtegamiQASweepUITests.testAddSecondAccountImmediatelyAfterFirst` が
  `simctl erase` 直後の実行で1回、間欠的に失敗**: test1/test2 を間を置かず
  連続追加 → 2回連続の即時リランチ (`restartAppToRecoverTouchDelivery` を
  settle 待ちなしで2回) の直後、`sidebar.list` 自体は存在するのに Cell が
  1つも無い (=`environment.accounts` が空扱い) 状態を10秒以上観測した。
  ただし数秒後に同じシミュレータで手動確認したところ両アカウントとも
  正しく GRDB に存在しており (`sqlite3` で直接確認)、データ消失ではなく
  一時的な表示不整合だった。さらに気になる手がかりとして、その時
  `test1@otegami.test` の `displayName` が本セッションのテストコードが
  一貫して使っている `"Dovecot Test1"` ではなく `"Dovecot Test"` (末尾の
  "1" が無い) になっていた — 本セッションのどのテストコードもこの表記は
  使っていないため、`AccountCloudSyncEngine.reconcile()` が実 iCloud KVS
  経由で本セッションより**前**の (異なる命名規則だった頃の) verify 実行分の
  アカウントレコードと衝突/マージした可能性が高い。同条件で即座に再実行
  したところ再現せず (green)。`docs/verify.md`/本ファイル既出の「この
  開発機は実 iCloud アカウントに紐づいているため `simctl erase` だけでは
  真にゼロアカウントの状態を作れない」問題の、より踏み込んだ一側面
  (古い異名アカウントとの reconcile 競合) と見られる — 実装を追うだけの
  価値はあるが、この開発機固有の実 iCloud データ汚染に依存する再現性の
  低い事象を追いかけるより、根本的には「この開発機のテスト用 Apple ID の
  iCloud データを一度整理する」something がより効果的な対処と考えられる
  ため、深追いはせずここに記録するに留めた。

## 未実施・今後の課題

- スレッド境界を跨ぐ「宛先だけのメール」(本文どころか宛先以外の情報が
  ほぼ無いメール) のような、より極端な境界データフィクスチャは今回追加
  しなかった (件名なし・本文空の2種類のみ追加)。必要なら
  `dev/mailstack/seed/fixtures/19-*.eml` として追加を検討。
- macOS 側は `make mac` のビルド確認のみ (Bug A/B の修正は compact 幅
  (iPhone) のみに影響する設計だが、`make mac` の実際の起動・操作までは
  このセッションで自動検証していない — `docs/verify.md` M10 節の手順に
  倣った手動確認が今後望ましい)。→ **後続の macOS QA スイープセッションで
  対応済み。以下に追記。**

## macOS QA スイープ (M10 以降の大量の状態復元/選択周りの変更を、実際に
## macOS 版を起動・操作して検証したセッション)

上の「未実施」節にあった通り、M10 以降 (状態復元まわりの修正、
`SidebarView`/`MessageListView` の Button 駆動 selection 化、
`ThreadDetailView` の `GeometryReader` 高さ制御など) は iOS compact 幅を
主眼にした変更で、macOS の3ペイン常設レイアウトへの影響は `make mac`
(ビルド確認のみ) に留まっていた。このセッションで初めて実際に
`open -n -a Otegami.app`/`nohup .../Otegami` で起動し、`.claude/skills/verify/
SKILL.md` の手法 (`screencapture` + `sips` クロップ + CGEvent ベースの
`driver.swift`、別プロジェクトで確立した verify 手法を踏襲) で実操作した。

### 確認して問題なかった項目

- 起動直後の3ペインレイアウト (サイドバー/一覧/詳細が同時表示、崩れなし)。
- サイドバー選択: 統合トレイ⇄各 mailbox の切替、**同じ行の再クリック**も
  含めて正常 — iOS で見つかった「直前選択行がタップ不能」系の不具合の
  macOS 版は再現しなかった。`SidebarView.onSelected`/`MessageListView
  .onThreadSelected` はどちらも `RootView.preferredColumn` を押し出すが、
  この値は macOS の常設3ペインでは無視される (docs/verify.md の実機バグ
  続報2節に既出の通り) ため、そもそも影響しうる設計になっていない。
- 一覧→スレッド選択→別スレッド→同じスレッド再選択: 正常。
- ウィンドウリサイズ: 幅を絞ると detail ペイン→sidebar の順に
  `NavigationSplitView` が畳まれ、極端に狭くすると最小幅で頭打ちになる
  (破綻・クラッシュなし)。
- ⌘N (新規作成)・⌘R (返信、選択スレッドの最新メッセージに対して正しく
  prefill)・⌘⇧F (検索フィールドにフォーカス、スコープピッカーも表示)・
  ⌘⌫ (選択スレッドを削除)・⌘]/⌘[ (メールボックス循環、ラップアラウンド
  含め) — いずれも実操作で確認、正常動作。
- ⌘, の Settings シーン: 「アカウント」⇄「情報」タブの切替でコンテンツが
  正しく差し替わる (M10 で修正した `.id(...)` 対応が効いたまま)。
- ツールバー検索フィールド: 日本語クエリでの絞り込み、クリアともに正常。
- QuickLook: 添付 PDF (`請求書.pdf`) をクリックすると正しくダウンロード
  してプレビュー表示。
- HTML メールの外部画像バナー: 「画像を表示」ボタンの表示/クリックでの
  ブロック解除が正常 (ブロック中は代替アイコン表示)。
- アプリ終了 (⌘Q)→再起動: 3ペインレイアウト・統合受信トレイへの選択は
  復元されるが (`SidebarView.observeMailboxes` のデータ選択)、直前に開いて
  いたスレッドは復元されない — `RootView.lastOpenedThreadIdBySelectionKey`
  が意図的にプロセス内メモリのみ (`docs/verify.md` 記載の設計) である
  ことの想定通りの macOS での挙動。クラッシュ・空表示なし。

### 見つけて修正したバグ (2件、macOS 固有コード)

1. **Composer をタイトルバーの赤信号ボタンで閉じると、未保存の下書きが
   確認なしに失われる** (`docs/roadmap.md` に記載されていた既知の制約)。
   `ComposerView` に `WindowCloseInterceptor` (`NSViewRepresentable` +
   `NSWindowDelegate.windowShouldClose(_:)`) を追加し、macOS の titlebar
   close も iOS の「キャンセル」ボタンと同じ `hasUnsavedChanges` チェック/
   保存・破棄確認ダイアログを通るようにした。`allowNextWindowClose` の
   ワンショットフラグで、確認後の `dismiss()` が同じ delegate 経由で再度
   `windowShouldClose` を呼んでも無限ループしないようにしている。
   `apps/Otegami/Sources/Features/Composer/ComposerView.swift`。実操作で
   「キャンセルで編集続行」「破棄で閉じる」「下書き保存で閉じる+下書き
   一覧に追加」の3経路すべて確認済み。
2. **`ComposerLaunchPayload.new` が `static let` で、UUID が使い回されて
   いた**: `Identifiable`/`Hashable` の `id` が全ての「新規作成」呼び出しで
   同一になるため、macOS の `WindowGroup(for:)` がこの値をキーに
   ウィンドウ/状態の同一性を判定する際、直前に破棄したはずの Composer
   セッションの入力内容 (例: To フィールドの文字列) が次の「新規作成」に
   漏れて残るバグを実機操作で発見 (1つ目の Composer に入力→破棄→⌘N で
   新しい Composer を開くと To フィールドに前回の文字列が残っていた)。
   `static let` → `static var` (呼び出しごとに新しい `UUID`) に変更して
   修正、実操作で再確認済み (2回連続で異なる文字列を入力しても混ざらない
   ことを確認)。`apps/Otegami/Sources/Support/ComposerLaunchPayload.swift`。
3. **macOS にはメッセージ一覧の右クリックメニューが無く、既読/未読切替・
   削除ができなかった**: `.swipeActions` は iOS 専用の UI で macOS では
   何もレンダリングされないため、スレッドを開かずに一覧から既読切替・
   削除する手段が macOS に存在しなかった (⌘⌫ はスレッドを開いた後にしか
   使えない)。`MessageListView` の行に `#if os(macOS) .contextMenu { ... }
   #endif` を追加し、既存の `toggleRead(_:)`/`deleteThread(_:)` をそのまま
   再利用 (opQueue 経由の実処理はスワイプアクションと完全に共通)。実操作で
   右クリック→「未読にする」が正しく反映されることを確認。

### 見つけたが修正しなかったバグ (macOS 固有コードの範囲外 — 設計判断が必要)

- **インライン `cid:` 画像が macOS/iOS 共通で解決に失敗する**:
  `16-cid-inline-image.eml` を開くと、本文中の `<img src="cid:otegami-
  logo@otegami.test">` が壊れた画像アイコンのまま表示される。QuickLook
  経由の通常の添付ファイルダウンロードは正常に動作する (`環境.auth`/
  `syncCoordinator.fetchAttachment` 自体は生きている) ため、原因を
  `CIDSchemeHandler`/`CIDURLRewriter` に絞り込んで特定した:
  `CIDURLRewriter.rewrite(html:)` が `cid:otegami-logo@otegami.test` を
  `otegami-cid://otegami-logo@otegami.test` に書き換えるが、**`@` を含む
  Content-ID (RFC 2392 的にごく標準的な形式) を `URL` の `host` として
  読み出すと、`@` が userinfo の区切りと解釈されてしまい `url.host` が
  `"otegami.test"` だけを返す** (`"otegami-logo"` 部分は `url.user` に
  吸収される) ことを `swift` の対話実行で直接確認済み:
  ```
  URL(string: "otegami-cid://otegami-logo@otegami.test")?.host
  // => "otegami.test" (期待値は "otegami-logo@otegami.test")
  ```
  `CIDSchemeHandler.resolve(contentId:)` はこの (誤って短縮された)
  `host` を `contentId` として `attachment` テーブルを検索するため必ず
  `notFound` になり、画像が永遠に解決できない。M8 時点の
  `docs/verify.md`/`docs/roadmap.md` の記載 (「スクリーンショットの
  スクロール位置の問題で実際に描画されたかは未確認」) を踏まえると、
  この不具合は M8 からずっと存在していた可能性が高い — 「一覧・詳細
  どちらでもうまく動く」という前提そのものが、一度も画素レベルで
  確認されないまま残っていたことになる。
  - **この不具合は `CIDURLRewriter.swift`
    (`packages/OtegamiKit/Sources/OtegamiCore/`) と `CIDSchemeHandler.swift`
    (`apps/Otegami/Sources/Features/ThreadDetail/`) という共有コードにあり、
    `#if os(macOS)` の外側 — iOS/macOS 両方に影響する。今回のタスクは
    macOS 固有コードのみが修正対象範囲だったため、あえて直さずここに記録
    する。**
  - 推奨対応: `CIDURLRewriter`/`CIDSchemeHandler` の設計を「`host` に
    生の `contentId` を積む」方式から、`@` を含んでいても壊れない形
    (例: パーセントエンコードしてから `host` に積む、または `host` では
    なく `path`/クエリパラメータに `contentId` を積む形へ変更) に直す
    必要がある。修正後は M8 の cid テストを「実際に画像が描画された
    ピクセルを検証する」形に強化する価値もある (現状は「壊れていないか」
    を目視でしか確認できていない)。
  - **解決済み (後続セッション)**: `CIDURLRewriter.rewrite(html:)` で
    `contentId` を `CharacterSet.urlHostAllowed` でパーセントエンコード
    してから `otegami-cid://` の host 部分に積むよう修正 (commit
    `cf7b8b0`)。この deployment target の `URL.host` は読み出し時に
    パーセントデコードを行う (`otegami-cid://logo%40otegami.test`
    → `host == "logo@otegami.test"`) ことを `swift` の対話実行で確認済み
    のため、`CIDSchemeHandler` 側の変更は不要だった。iOS シミュレータ
    (iPhone 17e) と macOS 実行バイナリの両方で実際に `16-cid-inline-
    image.eml` を開き、オレンジ色の単色ロゴ画像がスクロール後の本文中に
    実際に描画されていることをスクリーンショットで目視確認済み (このタスク
    実行時の `docs/verify.md` 未追記分、スクリーンショットはセッションの
    scratchpad に保存)。回帰テストとして `CIDURLRewriterTests` に `@`
    を含む Content-ID のケースを追加し、`OtegamiM8CIDImageUITests` も
    「画面をスクロールしてから、フィクスチャの単色ロゴ画像のピクセルが
    実際に検出できること」を検証する形に強化した (推奨対応の後半も
    含めて対応済み)。

### その他の所見 (真バグではない/対応不要)

- **`test1@otegami.test` に紐づくアカウントが macOS 側に2つ表示される
  ("Dovecot Test1" と "test" — どちらも `test1@otegami.test`)**:
  「test」アカウントは「資格情報を待っています」状態で mailbox 情報が
  一切無く、iCloud 経由で過去の verify セッションの命名規則違いの
  アカウントレコードが重複同期されたものと見られる (`docs/verify.md`/
  本ファイル既出の「実 iCloud データ汚染で `simctl erase` だけでは
  真にゼロアカウントにならない」問題と同根 — macOS 版は `simctl erase`
  に相当するリセット手段が無く、より頑固に残る)。今回のタスク範囲外の
  開発機汚染であり、アプリのロジック自体に問題は無い。
- **`scripts/verify-macos-qa.sh` の自動化は、共有デスクトップ環境特有の
  外乱に弱い一点がある**: Composer の「保存せずに破棄」ボタンを座標
  クリックで押す自動チェックが、このセッションの開発機では間欠的に
  失敗した。原因を追ったところ、(a) このマシンには他の自動化ツール
  (他の自動化ツールのフローティングターミナルパネルなど、同一 tmux/Claude セッション
  内の並行エージェントを含む) が同じデスクトップ上で同時に動作しており、
  `screencapture` のクロップ範囲に無関係な他アプリのウィンドウが写り込む
  ことを実際に確認 (他ツールのパネル内容がそのままキャプチャに写った)、
  (b) 過去のテスト実行中に `osascript ... tell process "Otegami" to ...
  window 1` (インデックス指定、フロントの window を指す) が、たまたま
  Composer ウィンドウがフロントにあるタイミングで実行されてしまい、
  Composer の永続化ウィンドウフレーム (`NSWindow Frame composer-
  AppWindow-1`) を誤って書き換えていたことも判明 — スクリプト側は
  ウィンドウ名を明示指定する形に修正し、プロセスの完全終了を待ってから
  次を起動するように修正済み。それでも上記 (a) の外乱は防ぎきれないため、
  「保存せずに破棄」の自動アサーションは `warn` (非致命) 扱いにして
  スクリーンショットでの目視確認に委ねている — アプリ側の実装は本節の
  冒頭で述べた通り実操作で複数回、明確に確認済み (問題なし)。

## 「2アカウント連続追加テストの間欠的失敗」の原因確定と修正

上の「深追いはせずここに記録するに留めた」としていた
`OtegamiQASweepUITests.testAddSecondAccountImmediatelyAfterFirst` の間欠的
失敗 (displayName が `"Dovecot Test1"` ではなく `"Dovecot Test"` に化ける、
一時的に `sidebar.list` の Cell が0件になる) を掘り下げ、原因を確定して
修正した。

**原因**: `AccountCloudSyncEngine` (`packages/OtegamiKit/Sources
/AccountCloudSync/AccountCloudSyncEngine.swift`) の `reconcile()`/
`pushLocalChange`/`pushLocalDeletion` はいずれも「`"accounts.v1"` の iCloud
KVS ペイロードを読む → 加工する → 書き戻す」という read-modify-write を
行うが、これが Swift の **actor reentrancy** に対して無防備だった。
`reconcile()` は `loadPayload()` で古い payload を読んだ**あとに**
`await local.allAccountSnapshots()` という本物のサスペンションポイント
(GRDB へのアクセスを経由する) を挟む。`AccountCloudSyncEngine` は普通の
`actor` なので、`reconcile()` がそこで中断している間、同じ actor 宛ての
別の呼び出し (`pushLocalChange`/`pushLocalDeletion`、あるいはもう1つの
`reconcile()`) が割り込んで最後まで実行できてしまう。割り込んだ側が
payload を書き終えたあと `reconcile()` が再開すると、`reconcile()` は
自分が最初に読んだ**古い** payload を元に計算した結果でそのまま上書き
保存してしまい、割り込んだ側の書き込みが消える (lost update)。

具体的にこのテストで踏んでいた経路: `AppEnvironment.init()` がアプリ起動
直後に `Task { await cloudSync.reconcile() }` を fire-and-forget で開始する
一方、test1/test2 の連続追加はそれぞれ `Task { await
pushAccountToCloud(account) }` も fire-and-forget で呼ぶ。この2種類の
呼び出しが同じ actor 上で競合すると、上記のロストアップデートにより
一時的に古い (本セッションより前の verify 実行分の) cloud payload が
"勝って" しまい、`reconcile()` の phase 4 (cloud only のアカウントを
ローカルに insert) がそれを取り込んで、UI 上に一瞬古い displayName の
アカウント行が現れる — これがまさに観測された症状。データそのものは
失われておらず (ローカル DB の真実は保たれたまま)、次の `reconcile()`
呼び出しで自己修復するため「間欠的」に見えていた。

**これはこの開発機の iCloud データ汚染に限った問題ではない**:
同じ Apple ID の別デバイスからの `didChangeExternallyNotification` 経由の
`reconcile()` と、ユーザーが立て続けに2つ目のアカウントを追加する操作が
実際に競合すれば、本番環境でも同じロストアップデートが起こりうる。その
ため実装 (`AccountCloudSyncEngine` 本体) 側を修正する方針とした
(テスト環境限定の回避策には留めなかった)。

**修正**: `reconcile()`/`pushLocalChange`/`pushLocalDeletion` の
read-modify-write 区間全体を、actor 内で自前実装した非同期 mutex
(`acquirePayloadLock()`/`releasePayloadLock()` — `CheckedContinuation` を
使った FIFO キュー方式、ハンドオフの間 `isPayloadLocked` を常に `true`
に保つことで新規到着の呼び出しが待ち行列を追い越せないようにしてある)
で囲み、3つの操作が互いに完全に直列化されるようにした。詳細は
`AccountCloudSyncEngine.swift` の `isPayloadLocked`/`payloadLockWaiters`
まわりのコメントを参照。

**回帰テスト**: `AccountCloudSyncEngineTests
.concurrentPushDuringReconcileDoesNotLoseTheUpdate`
(`packages/OtegamiKit/Tests/AccountCloudSyncTests
/AccountCloudSyncEngineTests.swift`) を新規追加。フェイクの
`local.allAccountSnapshots()` を `AsyncGate` で任意の時点で一時停止できる
ようにし、`reconcile()` を意図的に「payload を読んだ直後」で止めた状態で
`pushLocalChange` を割り込ませ、両方が完了したあとに両方の書き込みが
生き残っていることを assert する。修正前のコードに対して実行すると
確実に (フレークではなく毎回) 失敗することを確認済み — 一時的に修正を
`git stash` で外して実行し、`ids.contains("concurrent-push")` が `false`
になることを確認してから元に戻した。`make test` は本修正後、複数回
連続実行して green (`packages/OtegamiKit` 全211テスト)。

**フレーク率の実測**: `xcrun simctl erase` → boot → build →
`OtegamiQASweepUITests/testAddSecondAccountImmediatelyAfterFirst`
単体実行、という完全にクリーンな状態からの実行を **5 回連続**行い、
**5/5 (100%) で成功**。修正前は同条件で間欠的に失敗していた (このファイル
上の元の記録を参照) — 決定的な再現手順ではなかったため「n回に1回」を
正確な比較対象として出すことはできないが、この修正が投入された actor
reentrancy という根本原因そのものを塞いでいる (単体テストで確定的に
再現・修正確認済み) ことと合わせて、この5/5という実測は十分な傍証と
判断した。

## M9 追補2: 通知許可の未実装バグを修正、`simctl push` の旧ブロッカーは解消——ただし新たなシミュレータ制約を発見

前回のセッション (「M9 追補」節、以下に再掲) で、`xcrun simctl push` が
`UNErrorDomain code=2003 "Source is not authorized"` で常に拒否される
原因を「アプリが `UNUserNotificationCenter.requestAuthorization(options:)`
を一度も呼んでいないこと」と特定していた。これは検証環境固有の問題では
なく**プロダクションの実バグ**だった: `PushTokenCenter.requestToken()`
は `UIApplication.registerForRemoteNotifications()` (APNs デバイス
トークン登録) だけを呼んでおり、`UNUserNotificationCenter` 側の表示許可
(iOS 10 以降、`registerForRemoteNotifications()` とは別 API) を一度も
要求していなかった。実機で本物の APNs 経由の push が届いても、通知
バナー自体が表示されない状態だった。

**修正内容**:
1. `PushTokenCenter.requestToken()` が、デバイストークン登録の前に
   `UNUserNotificationCenter.current().requestAuthorization(options: [.alert,
   .badge, .sound])` を待つようにした。許可判定は
   `NotificationPermissionResolver.resolve(using:)`
   (`packages/OtegamiKit/Sources/PushRelayClient/NotificationPermission.swift`)
   に切り出し、`.authorized`/`.denied`/`.notDetermined` の3状態を正しく
   扱う (`.denied` なら再プロンプトせず即座に停止、`.notDetermined` のみ
   実際にダイアログを出す — 実装は `UNUserNotificationCenter` 側の仕様に
   合わせた設計。詳細はそのファイルのドキュメントコメント参照)。
   `NotificationPermissionResolverTests` (5件) で3状態の分岐を単体
   テスト済み — `PushTokenCenter` 自体は Otegami アプリターゲットに
   ユニットテストターゲットが無いため、`NotificationEnrichment` と同じ
   「純粋ロジックを OtegamiKit 側に切り出してテストする」パターンを踏襲。
2. 拒否時は `AppEnvironment.PushError.notificationPermissionDenied` を
   新設し、`PushNotificationSettingsView` が「通知が許可されていません。
   設定アプリから許可してください。」+「設定アプリを開く」ボタン
   (`UIApplication.openSettingsURLString`) を表示するようにした。
3. `OtegamiPushSimulatedSetupUITests` に
   `grantNotificationPermissionViaPushSettings(in:)`
   (`UITests/DovecotAccountUITestHelpers.swift`) を追加し、`simctl push`
   の前に一度「設定 → プッシュ通知 → 有効にする」を実行して許可
   プロンプトを `allowNotificationPermissionIfNeeded()` で accept する
   ようにした。

**検証結果 (`scripts/verify-ios-push-simulated.sh` を実行)**: 旧
ブロッカーは確認どおり解消した — `xcrun simctl push` はもう
`UNErrorDomain code=2003` で拒否されず、3シナリオとも `push accepted`
で受理された。ログでも `authorizationStatus: Authorized` を確認済み
(`usernotificationsd` の `NotificationsPipeline` ログ)。

**しかし、この開発機の iOS 27 ベータ Simulator では別の制約に突き当たった:
`NotificationService` (UNNotificationServiceExtension) 自体が一切
起動されない。** 3シナリオすべてで、通知バナーが `NotificationService
.didReceive(_:withContentHandler:)` の生成する内容 (最低でも汎用
フォールバックの「新着メールがあります」) にすら書き換わらず、payload の
生の `aps.alert.loc-key` 文字列 "NEW_MAIL" がそのまま表示され続けた
(push 直後の3秒後だけでなく、10秒待ってからの再確認でも同じ)。技術的な
特定:
- `xcrun simctl spawn <udid> log show --predicate 'process ==
  "NotificationService"'` が該当期間について**1件もヒットしない**。
- `launchd_sim` のログを同期間で確認しても、`com.mtkg.otegami
  .NotificationService` の spawn イベント自体が存在しない
  (`WILL_SPAWN`/`xpcproxy_sim spawned`/`service state: running` の
  いずれも無し) — 同じログに `OtegamiUITests-Runner` の spawn は明確に
  記録されているので、ログ収集自体は機能している。
- アプリ側の設定は確認した範囲で正しい: `project.yml` の
  `NotificationService` ターゲットの `NSExtensionPointIdentifier:
  com.apple.usernotifications.service`、App Group/Keychain Access Group
  entitlement、メインアプリの `aps-environment: development`
  entitlement、`.appex` が実際に `Otegami.app/PlugIns/` に埋め込まれて
  いること (`xcrun simctl get_app_container` で確認) — いずれも問題なし。
- クラッシュログ (`~/Library/Logs/DiagnosticReports`、シミュレータの
  `CrashReporter` ディレクトリ) にも `NotificationService` 関連のものは
  無い — 起動して落ちたのではなく、そもそも起動要求自体が発行されて
  いない。

以上から、**`simctl push` が payload をシミュレータに注入すること自体は
成功する (これが旧ブロッカーだった) が、この開発機のこの iOS 27 ベータ
Simulator ランタイムでは `mutable-content` payload に対して
`UNNotificationServiceExtension` を起動する OS 側のパイプライン
(`usernotificationsd`/`launchd_sim`) が機能していない**、という結論に
至った。アプリ側のコード (`PushTokenCenter.swift`/
`NotificationService.swift`/entitlements/`project.yml`) にこれ以上
手を入れる余地は見当たらない — 起動要求そのものが発行されていない以上、
Extension 側のロジックを直しても検証できない。この制約はベータ OS の
既知の不安定要素の一つと見られる (`docs/verify.md`/本ファイルの他の節で
既に記録している「この開発機は Xcode-beta.app + iOS 27.0 ベータ
シミュレータを使っている」という前提の、また別の一面)。安定版 Xcode/iOS
の実機・実 Simulator ランタイムでは再現しない可能性が高いが、この開発機
上ではこれ以上 `simctl push` 経由でのエンリッチメント確認を進める手段が
ない。

**結論**: 通知許可の実装バグ修正そのものは完了・単体テスト済みで
プロダクション上正しい (実機で許可プロンプトが正しく出るようになる)。
`simctl push` の第一のブロッカー (許可未実装) は解消したことをこの
開発機で実証したが、「差出人・件末が書き換わる」ところまでの
エンドツーエンド確認は、この開発機のベータ Simulator では新たに発見
した別の制約により依然として不可能——実機での最終確認
(`.p8` キー要、PENDING.md M9 節) が引き続き唯一の手段として残る。
`NotificationEnrichment` (書き換えロジック自体の単体テスト) と
`NotificationPermissionResolver` (許可判定の単体テスト) でカバーされて
いない範囲は、「OS が Extension を実際に起動し、そこから IMAP に到達
できるか」という、この開発機では検証しようがない部分のみに絞り込めた。

## M9 追補 (旧): `xcrun simctl push` シミュレータ注入テストの現状 (このセッションで解消した旧ブロッカー、参照用に残す)

`.p8` キーなしで `NotificationService` Extension を実プロセスとして検証
する試み (`scripts/verify-ios-push-simulated.sh`) を追加したが、この
開発機では `xcrun simctl push` 自体が `UNErrorDomain code=2003 "Source is
not authorized"` で常に拒否され、通知配信そのものを試すところまで到達
できなかった。原因はアプリが `UNUserNotificationCenter
.requestAuthorization(options:)` を一度も呼んでいないこと (現状は
`registerForRemoteNotifications()` のみ) で、修正には
`Support/PushTokenCenter.swift` への1行の追加が必要 — このファイルは
本タスクで編集を許可された範囲の外なので、このセッションではあえて
加えていない。調査の詳細・再現手順・具体的な修正案は `docs/verify.md`
の「iOS シミュレータ検証 (M9 追補: `simctl push` 注入テスト)」節に記録
した。`NotificationService.enrich(payload:)` の書き換えロジック自体は
`NotificationEnrichment` として `packages/OtegamiKit/Sources
/PushRelayClient/` に切り出し、`NotificationEnrichmentTests` で単体
検証済み — 実 IMAP/GRDB/Keychain を経由するエンドツーエンドの経路だけが
このブロッカーで未検証のまま残っている。
