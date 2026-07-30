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

## Task #44: Gmail の「すべてのメール」に直近の新着が反映されない実バグの調査と修正

**症状**: 実 Gmail アカウントで「すべてのメール」(All Mail) を表示しても、
直近 (~24時間) のメールが出ない (INBOX には出ている)。表示中に
pull-to-refresh しても出てこない。

**調査**: `MailboxSyncer.incrementalSync`/`AccountSyncer.performIncrementalSync`
の差分同期ロジック自体 (新着 = `maxUID+1 ... uidNext`、CONDSTORE フラグ
同期、非CONDSTORE の refetch-and-diff、uidValidity 変化時のフル再同期)
は `role`/mailbox の種類を一切区別しない汎用実装で、既存の
`FakeIMAPSession` テスト (`AccountSyncerTests.allScopeSkipsHiddenMailbox`
など) で非INBOXメールボックスへの新着取り込みが既に確認されていた。
それでも実バグ報告と整合させるため、`.mailbox(path:)`スコープ (サイド
バーで1メールボックスを選んだ時/そのpull-to-refreshが使う経路) を
**実 dev mailstack Dovecot に対して**新規追加した統合テスト
(`SyncEngineIntegrationTests
.mailboxScopedIncrementalSyncPicksUpNewMailInNonInboxMailbox`) で再確認
したところ、**問題なく新着を取り込めた** — 実サーバー・実 CONDSTORE
込みで、差分同期そのものにはバグが無いことを確認した。

**根本原因はコードを読んで発見**: `MessageListView`は、サイドバーで
メールボックスを**選択しただけでは一切同期をトリガーしていなかった**
(`selection`の`.onChange`はページングリセットなどのみ、`.task(id:
ObservationKey...)`はDBの`ValueObservation`購読のみ)。非INBOXメール
ボックスが新着を拾える経路は「そのメールボックスを表示中に明示的に
pull-to-refreshする」ことだけで、それ以外の自動同期 (`OtegamiApp
.syncAllAccountsOnce`の起動時/フォアグラウンド復帰時パス、フォアグラ
ウンド`IDLE`ループ) はいずれも`SyncScope.inboxOnly`固定 — INBOX/下書き
以外は起動・復帰・IDLEのどれでも一切同期されない設計だった。

これと、Gmail の「すべてのメール」がサーバー側で INBOX とは別に (やや
遅れて) インデックスされる既知の挙動を組み合わせると: ユーザーが「すべて
のメール」を開いた直後にpull-to-refreshしても、その時点でまだ Gmail
サーバー側のAll Mailにそのメッセージが反映されていなければ (差分同期
ロジックが正しくても) 何も出てこず、しかも自動的な再試行が一切無い
ため、後で反映されていても**再度そのメールボックスを開いて明示的に
refreshし直さない限り永遠に取り込まれない** — 「表示しても出ない、
refreshしても出ない」という報告と一致する。

**修正**: `apps/Otegami/Sources/Features/MessageList/MessageListView.swift`
- `refresh()`に`surfaceErrors: Bool = true`引数を追加 (既存呼び出し元は
  無変更) — エラーを`syncErrorMessage`アラートに出すかどうかを分離。
- 新設`syncSelectedMailboxOnAppear()`: `refresh(surfaceErrors: false)`を
  `selectedMailboxResyncInterval`(5分) おきに、キャンセルされるまで
  ループ実行する。`.task(id: selection)`(`.onChange`ではなく) から呼ぶ
  ことで、コールドランチで復元された初期選択も含めて「そのメール
  ボックスを見ている間」ずっと自動的に再同期を試み続ける — サイド
  バー選択を変える/この画面が消える瞬間に SwiftUI が自動キャンセルする
  ので、明示的なライフタイム管理は不要。エラーはアラートに出さない
  (単に画面を見ているだけで通信エラーの警告が出るのは不親切なため)。
- `refresh()`自身のスコープ解決ロジック (`.mailbox`/`.unifiedInbox`/
  `.unifiedRole`の3ケース) は無変更 — 差分同期そのものは元から正しい
  という調査結果に基づき、「同期が確実に走るようにする」ことだけを
  直した。

**テスト**:
- `packages/OtegamiKit/Tests/SyncEngineTests/AccountSyncerTests.swift`
  に`mailboxScopedSyncPicksUpNewMailInAllMailRoleMailbox`を追加:
  `role: .all`のGmail「すべてのメール」を模したメールボックスへ、
  `.mailbox(path:)`スコープ・CONDSTORE込みで新着が取り込まれることを
  `FakeIMAPSession`で確認 (INBOXは対象外のまま変化しないことも確認)。
- `packages/OtegamiKit/Tests/MailTransportMailCoreTests
  /SyncEngineIntegrationTests.swift`に
  `mailboxScopedIncrementalSyncPicksUpNewMailInNonInboxMailbox`を追加:
  実 dev mailstack Dovecot に対して同じシナリオ (`.mailbox(path:)`ス
  コープでの非INBOXメールボックスへの新着取り込み) を確認 (opt-in、
  `OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter
  SyncEngineIntegrationTests`)。
- `make test`/`make mac`/`make ios`: 全て green。

**できなかったこと/未検証事項**: 実 Gmail アカウントでの実機確認 (シミュ
レータのアカウント追加不調が継続中のため、`FakeIMAPSession`/実
Dovecot統合テストのみでの検証)。Gmail サーバー側の「すべてのメール」
インデックス遅延そのものの実測 (今回の修正はその遅延を前提に「反映
されるまで自動的に再試行し続ける」設計にしたが、遅延の実際の長さは
未計測)。`PENDING.md`に記録した。

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
  prefill)・⌘⇧F (検索フィールドにフォーカス、スコープピッカーも表示、
  **Task #165 で ⌘F へ移動、⇧⌘F は「転送」に付け替え済み — 下記参照**)・
  ⌘⌫ (選択スレッドを削除)・⌘]/⌘[ (メールボックス循環、ラップアラウンド
  含め) — いずれも実操作で確認、正常動作 (当時)。
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
した別の制約により依然として不可能——実機での最終確認 (`.p8` キー要、
セルフホスト手順は `docs/relay-deployment.md` 参照) が引き続き唯一の
手段として残る (完了済み)。
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

## 実機バグ: 一部のメールで本文取得が「serverError: ... (MailCoreErrorDomain
error 19)」で何度開き直しても失敗し続ける

**症状**: 特定のメールを開くと「本文の取得に失敗しました:
serverError: The operation couldn't be completed. (MailCoreErrorDomain
error 19.)」が表示される。同じメールで再現し、アプリを再起動しても
同じメールで再現し続ける — 一時的なネットワークエラーではない。

**原因**: MailCore2 のエラー 19 は `MCOErrorFetch`
(`UID FETCH` に対するサーバーの `NO` 応答) で、
`MailCoreIMAPSession+Mapping.mapError` はこの特定のコードに専用の
`MailTransportError` ケースを持たず `default` 分岐で `.serverError` に
落ちる。実際には**ローカル DB の `(mailboxId, uid)` がサーバー側の実体と
食い違っている「UID 陳腐化」** — 別クライアント (Gmail の Web UI など)
でそのメッセージをアーカイブ/別フォルダへ移動/削除した後、このアプリの
ローカル `message` 行だけがそのメールボックスの古い UID を指したまま
残っていた。IMAP の `UID` は `uidValidity` が変わらない限りメールボックス
内で安定という前提で作られているが、**他クライアントによるサーバー側の
移動/削除**はこの前提を静かに崩す — このアプリ自身の差分同期
(`MailboxSyncer`) が追いつく前にこのメールを開くと、サーバーにもう存在
しない UID への `FETCH` が永遠に `NO` を返し続ける。

**確認したこと (dev mailstack の実 Dovecot に対して)**: メールボックスが
一度も持ったことのない UID に対して `UID FETCH` (envelope) を投げると
**例外を投げず空配列を返す**が、同じ UID に対する `fetchParsedMessage`
(本文取得) は `.serverError` を投げる
(`MailCoreIMAPSessionIntegrationTests
.fetchingANonexistentUIDFailsBodyButNotEnvelopeExistenceCheck`)。
つまり「envelope フェッチは "UID SEARCH 相当" の存在確認として安全に
使え、本文フェッチだけが失敗する」という設計上の前提が実サーバーでも
成立することを確認できた。

**修正**: `packages/OtegamiKit/Sources/SyncEngine/BodyFetcher.swift` に
自己修復 (`attemptSelfHeal`) を追加。本文フェッチが `.serverError` で
失敗した時だけ、同じセッション上で該当 UID の envelope フェッチ
(`UID FETCH` 1件、`UID SEARCH` の代用) を行って本当にそのメールボックス
から消えているか確認する。

1. 確認自体が失敗した場合 (接続断・タイムアウトなど) は**何もしない**
   — 過去に「空の refetch がメールボックスを全削除した事故」
   (docs 内の別節) があるため、確認が取れない限り一切削除・変更しない
   のが安全条件。
2. UID がまだ存在するなら (何か別の理由でのエラーだったということ)
   何もしない — 元のエラーをそのまま呼び出し元に返す。
3. UID が確認どおり消えていた場合、同じアカウントの**ローカル DB**を
   `Message-ID` で検索し (Gmail の「すべてのメール」= `MailboxRole
   .all` を優先) — `AccountSyncer.performInitialSync` が選択可能な
   メールボックス全てを最初に同期する仕様なので、多くの場合はこの
   ローカル検索だけで見つかる:
   - 見つかった場合: そのメッセージ行 (同じ `id` を維持——開いている
     詳細画面などが指している参照を壊さないため) の `mailboxId`/`uid`
     を発見した場所に張り替え、見つかった側の重複行は
     `AccountDuplicateMerger.mergeCollidingMailbox` と同じ要領で
     (ピン留め・フラグを OR で引き継いで) 削除、スレッド集計
     (`ThreadAssigner.recomputeAggregates`) を再計算してから、同じ
     セッションでその場所を `select` し直して本文取得をリトライする
     (リトライ後は元のメールボックスに `select` を戻す)。
   - どこにも見つからなかった場合: サーバーから消滅済みとみなし、
     メッセージ行 (+ 本文/添付/検索インデックス) を削除しスレッド集計を
     再計算する (最後の1通なら `ThreadAssigner.recomputeAggregates` の
     契約どおりスレッド行自体も消える)。いずれの場合もエラーバナーは
     出さない — 自己修復できた場合はもちろん、消滅確定の場合も
     「ユーザーが再タップしても直しようがないエラー」を出し続けるより
     静かな整理で解決する。
4. 無限リトライ防止: `BodyFetcher` インスタンス (実質アプリセッション
   単位) ごとに `messageId` 単位で自己修復は一度だけ試す
   (`selfHealAttempted`)。

**テスト**: `packages/OtegamiKit/Tests/SyncEngineTests/BodyFetcherTests.swift`
に `FakeIMAPSession` ベースで4シナリオを追加 (張替え成功/どこにも
見つからず整理/存在確認自体が失敗して何も削除しない/2回目は確認を
繰り返さない)。`FakeIMAPSession` 自体にも `failFetchBody`/
`failFetchEnvelopes` のスクリプト機能を追加
(`packages/OtegamiKit/Tests/SyncEngineTests/FakeIMAPSession.swift`)。
`make test`/`make mac`/`make ios` は全て green、dev mailstack に対する
既存の opt-in 統合テスト (`OTEGAMI_TEST_IMAP_HOST=localhost swift test
--filter MailTransportMailCoreTests --no-parallel`) も全て green。

## Task #79: Web でアーカイブ済みのメールが受信トレイに残り続ける実バグの原因と修正

**症状**: Gmail の Web 版で INBOX からアーカイブ済み (= 消滅) のメールが
Otegami の受信トレイには大量に残り続け、Web より常に件数が多い。
pull-to-refresh しても消えない。

**原因**: 差分同期 (`MailboxSyncer.incrementalSync`) の CONDSTORE 経路
(`fetchEnvelopes(mailboxPath:changedSince:)`) は新着・フラグ変化しか
検出しない — CONDSTORE の `CHANGEDSINCE` はサーバー側のメッセージ消滅
(`EXPUNGE`) を一切報告しない (RFC 7162 §3.2.10 の `VANISHED` は
`QRESYNC` 拡張が対応して初めて返る)。非 CONDSTORE 経路
(`refetchAndDiffFlags`) は既に「同期済みウィンドウを丸ごと再フェッチして
ローカルとの差分から消滅を検出する」実装を持っていたが、**CONDSTORE
対応サーバーではこの経路が一切通らない** — Gmail は CONDSTORE に対応して
いるため常に CONDSTORE 経路を通り、消滅検出のロジックへ一度も到達
しないまま何ヶ月も残骸が積み上がっていた。

**MailCore2 の QRESYNC 対応状況の調査**: このリポジトリが pin している
mailcore2 (`readdle/mailcore2`, `44c63329d...`) の Swift オーバーレイ
(`src/swift` — `Package.swift` の `MailCore` ターゲットが実際にビルドする
のはここで、`src/objc`ではない) は QRESYNC の `VANISHED` UID 集合を
`MCOIMAPFetchMessagesOperation.start(completionBlock:)` の第3引数
(`MCOIndexSet?`) として**既に公開している** —
`packages/OtegamiKit/Sources/MailTransportMailCore/MailCoreIMAPSession.swift`
の `fetchEnvelopes(changedSince:)` はこれまでこの第3引数を `_` で
握りつぶしていただけだった。コア層 (`MCIMAPSession.cpp`) を読むと
`vanishedMessages()` は `QRESYNC` がサーバーの capability に含まれ、かつ
このセッションで実際に有効化されている場合のみ非 `nil` になる
(`mQResyncEnabled && modseq != 0`) ことも確認できた。

ただし **Gmail 自体は QRESYNC に対応していない** (Gmail の IMAP
`CAPABILITY` は `CONDSTORE` のみを広告し、`QRESYNC` は含まない —
公知の制限で、対応予定のアナウンスもない)。つまり QRESYNC 配線を追加
するだけでは今回報告された Gmail の実バグは直らず、**CONDSTORE のみの
サーバー向けフォールバックが本命の修正**になる。

**修正**:
1. `IMAPSessionProtocol.fetchEnvelopes(mailboxPath:changedSince:)` の
   戻り値を `[FetchedEnvelope]` から `ChangedSinceResult`
   (`envelopes` + `vanishedUIDs: Set<UInt32>?`) に変更
   (`packages/OtegamiKit/Sources/MailTransport/ChangedSinceResult.swift`)。
   `vanishedUIDs == nil` は「QRESYNC非対応/不明」、非 `nil` (空集合でも)
   は「QRESYNC が有効でこの回は本当に何も消えていない」という意味を
   持たせ、両者を区別できるようにした。
   `MailCoreIMAPSession` はこの第3引数をそのまま `ChangedSinceResult
   .vanishedUIDs` にマッピングするだけ (QRESYNC 対応サーバーなら追加の
   往復なしで消滅検出できる — iCloud など QRESYNC 対応サーバー向けの
   実質無料の副産物)。
2. **フォールバック (本命)**: 新規 `IMAPSessionProtocol.searchExistingUIDs
   (mailboxPath:uids:)` — `UID SEARCH UID <同期済みウィンドウ>` を投げて
   サーバーが今も持っている UID の集合だけを取得する (envelope データは
   一切取得しない、軽量なコマンド)。`MailboxSyncer` は
   `ChangedSinceResult.vanishedUIDs == nil` の場合 (Gmail はここに該当)
   にこれを使い、ローカルの UID 集合との差分を消滅とみなして削除する。
   `refetchAndDiffFlags` と全く同じ非破壊ガード (SEARCH が正常完了した
   場合のみ削除、`status.messageCount > 0` なのに空応答なら「怪しい」と
   みなし何もしない) を適用。
3. 削除ロジック (FTS 削除 + `ThreadAssigner.recomputeAggregates`) は
   `MailboxSyncer.deleteMessages(mailboxId:uids:)` に共通化し、QRESYNC
   直接経路・フォールバック経路・非 CONDSTORE 経路の3箇所全てから使う。
4. 頻度: 毎回の差分同期でチェックするが、`status.highestModSeq` が
   前回から変化していない場合は (新着もフラグ変化も消滅も何もないと
   保証されるため) そもそも往復しない — 既存の「CONDSTORE で
   highestModSeq 変化なしなら何もしない」ガードにそのまま相乗り。

**テスト**:
`packages/OtegamiKit/Tests/SyncEngineTests/MailboxSyncerTests.swift` に
4シナリオ追加 (QRESYNC 直接経路での削除/フォールバック UID SEARCH での
削除/フォールバックが空応答でも `messageCount > 0` なら何も消さない/
フォールバックの SEARCH 自体が失敗しても何も消さない)。既存の
CONDSTORE テスト (`condstoreFlagSync` など) は非 QRESYNC・
`existingUIDsByPath` 未指定のままでも green — `FakeIMAPSession` の
デフォルトは「フォールバック検索は空応答」であり、
`messageCount` が 0 でない既存テストは全て前述のガードで保護される。
`FakeIMAPSession` に `qresyncVanishedUIDsByPath`/`existingUIDsByPath`/
`failSearchExistingUIDs` を追加。

dev mailstack の実 Dovecot に対する統合テストも追加
(`packages/OtegamiKit/Tests/MailTransportMailCoreTests
/SyncEngineIntegrationTests.swift`
`incrementalSyncRemovesMessageExpungedByAnotherClient`) —
`doveadm expunge ... HEADER Subject <subject>` (新規
`DoveadmHelper.expungeMessage`) で1通だけを他クライアント視点で消し、
`incrementalSync` 後にローカルからも消えることを確認する。

`make test` green。実機確認ポイント: Gmail アカウントで Web 側から
INBOX の1通をアーカイブし、Otegami で pull-to-refresh (または通常の
差分同期) を行った後、その1通が受信トレイから消えること。

### 追記 (Task #83): 実機で効かなかった原因と修正

**症状の再発**: 上記修正後も実機で、Spark でアーカイブ済み (Gmail Web
でもアーカイブ済み = サーバーの INBOX から消滅済みを確認) のメールが
Otegami の受信箱に残り続けた。pull-to-refresh を繰り返しても消えない。
FakeIMAPSession によるユニットテストは全て green のままで、実装その
ものの消滅検出ロジック (`detectAndRemoveVanishedByUIDSearch`) 自体に
バグは無かった。

**原因**: 上の「修正」4番、「`status.highestModSeq` が前回から変化して
いない場合は往復しない」という前提が実機では成り立っていなかった。
`MailboxSyncer.incrementalSync` の CONDSTORE 経路は

```swift
if status.highestModSeq > UInt64(mailboxRecord.highestModSeq) {
    // ここでしか vanishedUIDs / detectAndRemoveVanishedByUIDSearch に
    // 到達しない
}
```

という `if` の中に、QRESYNC 経由の `vanishedUIDs` 判定も #79 の
UID SEARCH フォールバックも両方とも入れ子になっていた。Gmail は
他クライアントの `EXPUNGE` に対して必ずしも INBOX の `HIGHESTMODSEQ`
を進めるとは限らない (少なくとも実機で観測された範囲では、Spark 側の
アーカイブ操作後も `STATUS` の `uidNext`/`HIGHESTMODSEQ`/
`MESSAGES` が前回同期時と完全に同一のまま返ってくるケースがあった) —
その場合この `if` に一度も入らず、フォールバックの UID SEARCH 自体が
実行されないまま「変化なし」として同期が終わっていた。「`HIGHESTMODSEQ`
が変化しない ⇒ 何も消えていない」という保証は RFC 7162 のどこにも
存在せず、これは実装側の誤った前提だった。

**修正**: `MailboxSyncer.incrementalSync`/`AccountSyncer
.performIncrementalSync`/`SyncCoordinator.syncAccountIncrementally` に
`forceReconcileVanishedUIDs: Bool = false` を追加。`true` を渡すと
`highestModSeq` の比較結果に関係なく `detectAndRemoveVanishedByUIDSearch`
(軽量な `UID SEARCH` 1回) を必ず実行する。デフォルトは `false` のまま
(`IDLE` wake などの高頻度パスは従来どおり `highestModSeq` ガード付き —
毎回 `UID SEARCH` を払うコストに見合わないため)。`true` を渡すのは
`MessageListView.refresh()` — pull-to-refresh、macOS の手動再同期
ボタン、`syncSelectedMailboxOnAppear()` の5分間隔の自動再同期
(492c4ca) がいずれもこの1関数を経由する — の呼び出し全箇所のみ。

**計装**: `MailboxSyncer` に OSLog (`subsystem: "com.mtkg.otegami"`,
`category: "MailboxReconcile"`) を追加。`detectAndRemoveVanishedByUIDSearch`
実行のたびに対象メールボックスパス・サーバー側 UID 数・ローカル UID 数・
削除件数を記録し、`forceReconcileVanishedUIDs` によって
`highestModSeq` 不変でも強制実行された場合はその旨も別途記録する。
Console (`log stream --predicate 'subsystem == "com.mtkg.otegami" &&
category == "MailboxReconcile"'`) でこの照合が実機で実際に走って
いること、削除件数が0より大きいことを確認できる。

**テスト**:
`MailboxSyncerTests.forceReconcileDetectsVanishedMessageDespiteUnchangedStatus`
を追加 — `uidValidity`/`uidNext`/`highestModSeq`/`messageCount` の
全てが前回と完全一致する `MailboxStatus` を返す `FakeIMAPSession` に
対して、`forceReconcileVanishedUIDs` 無し (デフォルト `false`) では
何も削除されないこと (= 修正前の実機バグの再現)、`true` を渡すと
消滅した1通が検出・削除されることの両方を1テストで確認する。

既存の実 Dovecot 統合テスト
(`SyncEngineIntegrationTests.incrementalSyncRemovesMessageExpungedByAnotherClient`)
も再実行し green を確認 — こちらは Dovecot 自身が `EXPUNGE` に対して
`HIGHESTMODSEQ` を進めるため今回の実機パターン (`highestModSeq` 不変)
そのものは再現できないが、`detectAndRemoveVanishedByUIDSearch` 自体の
正しさの裏取りとして継続して有効。

`make test`/`make mac`/`make ios` 全て green。
`OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter
SyncEngineIntegrationTests` (dev mailstack) も5件全て green。

## Task #105: スレッド表示オフなのに再起動直後の一覧だけスレッド表示になるバグの調査と防御的修正

**症状** (実機報告、動画あり、再現性100%): スレッド表示の設定はオフ
(設定画面を開いてもオフ表示のまま) なのに、アプリを再起動すると一覧の
挙動が必ずスレッド表示になる。トグルを一度オン→オフし直すと正しく
フラット表示に戻る。

**#101/#82 との違い**: #101 (49535bf) は「トグルをオフにしても値自体が
勝手にオンへ巻き戻る」バグ (iCloud設定同期のreconcileレース) で、
既に修正済み。#105 は**値そのものは常にオフのまま**で、設定画面の
`@AppStorage`も一貫してオフを示す — 一覧の描画だけが違うクエリを
使っている「読み出し経路のバグ」で、症状としては別物。#82 (06c1062) は
`MessageListView`/`SearchScreenView`が一覧クエリを組み立てる際に
`@AppStorage`の per-view キャッシュ値ではなく`ListDisplaySettingsStore
.persistedBool(forKey:default:)`経由で`UserDefaults.standard`を直接
読むようにする防御的修正を既に入れていたが、実機ではそれでもなお
この症状が再発した。

### コードレビューで確認したこと (バグの箇所は見つからなかった)

`MessageListView`の`isFlatMode`/`persistedUnreadOnly`(いずれも#82で
`persistedBool`直読みに変更済み)、`ObservationKey`(`.task(id:)`のID
に`isFlatMode`を含む)、`observeThreads()`(`isFlatMode`を都度読み直して
`ThreadQuery.flatSummariesObservation`/`summariesObservation`を選ぶ)を
一行ずつ確認したが、いずれも実装として矛盾は無かった。`ThreadSummary
.init(flatMessage:accountId:)`の`id`もメッセージ単位のユニークな値を
使っており、フラット行が`List`/`ForEach`の識別子衝突でスレッド単位に
潰れて見える、という別経路の仮説も`id`の実装を見て否定した。iCloud
設定同期 (`SettingsCloudSyncEngine.reconcile()`) が起動直後に古い
cloud payload を pull してこのキーを上書きしている可能性も検討したが、
`reconcile()`が実際に`UserDefaults.standard`へ書き込む`pull()`は
Settings 画面が読む値そのものも書き換えるため、「設定画面は常にオフの
まま」という報告と矛盾する — この経路も除外した。

### 有力な仮説: プロセス起動直後の`UserDefaults.standard`自身の
### インメモリキャッシュが、ディスクの内容とまだ同期し切れていない

#82の直読み修正は「`@AppStorage`のper-viewインスタンスのキャッシュが
古い」という仮説に基づいていたが、`UserDefaults.standard`への直読みに
変えてもなお再発したことから、キャッシュがずれている主体は
`@AppStorage`ではなく**`UserDefaults.standard`自身のプロセス内
キャッシュ**である可能性が高いと判断した。`UserDefaults.standard`は
`cfprefsd`とのXPC通信を裏で行っており、プロセスの起動直後・まだ最初の
アクセスが済んでいないキーに対する最初の読み出しが、ディスクの最新
内容と同期し切る前の値を返しうる、という理論は Apple 自身のドキュメント
では精密には説明されていない (06c1062のdoc commentも同じ限界を認めて
いた) — が、「一覧の`.task(id:)`が起動直後の最初のフレームで読む
タイミング」と「ユーザーが数秒後に手で設定画面を開いて読むタイミング」
の間に`cfprefsd`との同期が追いつく、という時間差の説明は「設定画面は
常に正しい」「一覧だけ最初だけ間違う」「トグルを一度書き込むと直る
(書き込みで強制的にキャッシュが更新されるため)」の3点全てと矛盾なく
一致する。

### 修正 (防御的、#82/#101と同じ位置付け)

1. **`CFPreferencesAppSynchronize`によるプロセス起動直後の強制リロード**
   (`apps/Otegami/Sources/Support/ListDisplaySettingsStore.swift`の
   `forceReloadFromDiskOnce()`): このプロセス自身のpreferencesドメイン
   を今すぐディスクから読み直させる、まさにこの種の「起動直後、まだ
   ディスクと同期し切れていないかもしれないキャッシュ」を捨てるための
   API (通常はApp Group/ウィジェット拡張のようなマルチプロセス共有の
   文脈で紹介されるが、API自体はマルチプロセスに限定されない)。プロセス
   の生存期間中に一度だけ呼べば十分なので、`persistedBool`の最初の
   呼び出し1回に限定してコストを無視できる範囲に抑えた。
2. **`AppEnvironment.init()`の最冒頭で明示的に呼び出す**
   (`apps/Otegami/Sources/AppEnvironment.swift`): 既存の
   `UserDefaults.registerOtegami*Defaults()`群 (「どの`@AppStorage`
   読み出しよりも前に」というコメント付きで最初に呼ばれている) と全く
   同じ「起動直後、何よりも先に」という並び順に揃えた。`persistedBool`
   側の呼び出しは、万一これより前に何かが設定を読んでしまうケースへの
   保険として残した。
3. **OSLog計装** (`ListDisplaySettingsStore`の`Logger(subsystem:
   "com.mtkg.otegami", category: "ListDisplaySettings")`、
   `MessageListView`の`Logger(... category: "MessageListQueryMode")`):
   `persistedBool`の呼び出しごとに実際に読めた値を、`observeThreads()`
   の呼び出しごとに選んだクエリモード (`isFlatMode`/`unreadOnly`/
   `selection`) を1行ずつ記録する。Task #101の`SettingsCloudSync`
   計装と同じ狙い — 次に実機で再現したときに`log stream`で正確な値と
   タイミングを追えるようにする:

   ```sh
   xcrun simctl spawn booted log stream --level debug \
     --predicate 'subsystem == "com.mtkg.otegami" && (category == "ListDisplaySettings" || category == "MessageListQueryMode")' \
     --style compact
   # 実機の場合: log stream を接続したデバイスに対して実行、または Console.app。
   ```

### 検証

- `make mac`/`make ios` (`xcodebuild ... build`) いずれも green。
- `make test` (`packages/OtegamiKit`): 既知の無関係 flake
  (`MessageBuilderTests`の日本語ラウンドトリップ、1件) のみ、他49件
  green。
- `scripts/verify-screen.sh list`: 修正後も一覧が正常にレンダリングされる
  ことをスクリーンショットで確認 (回帰なし)。
- **このバグ自体の再現・修正の効果検証はこのシミュレータ/開発機では
  できなかった** — `defaults write com.mtkg.otegami listDisplay.threading
  -bool NO` → `simctl terminate` → `simctl launch` を挟んで
  `log stream`で最初の`persistedBool`呼び出しを確認したところ、
  修正の有無に関わらず**シミュレータでは最初の読み出しから一貫して
  正しい値 (`false`) が返っており、そもそもこのシミュレータではレース
  自体が再現しない** (06c1062・Task #101の際も同じ限界が記録されている
  — `docs/verify.md`のシミュレータ既知不調と同種、`UserDefaults`/
  `cfprefsd`周りの挙動がホスト共有のシミュレータでは実機より速い/
  決定的である可能性が高い)。したがって本修正は理論的な筋が通ることを
  確認した上での防御的対応であり、実機での確定的な効果確認はできていない。
  **実機での確認ポイント** (`PENDING.md`参照):
  1. スレッド表示をオフにする (設定画面でオフ表示になることを確認)。
  2. アプリスイッチャーから完全に kill し、再起動する。
  3. 一覧が (これまでの報告どおりスレッド表示になっていたところが)
     正しくフラット表示になっていることを確認。
  4. 上記の`log stream`コマンドで`persistedBool(listDisplay.threading)`
     の最初の値と`observeThreads: isFlatMode=...`の値を突き合わせ、
     一覧が実際にどちらのクエリを選んだかを確認できる。

### 決着 (2026-07-29、実機確認済み)

上記の防御的修正 (`CFPreferencesAppSynchronize`) では直らなかった。実機の
OSLog 採取 (notice レベルへの計装引き上げ → `log collect --device`) で
以下が確定した:

- 起動直後から `persistedBool(listDisplay.threading) -> false (stored=false)`、
  `observeThreads: isFlatMode=true` — **UserDefaults の読み取りも一覧の
  クエリ選択も最初から正しかった** (上の「プロセス起動直後のキャッシュ
  未同期」説は棄却)。
- 壊れていたのは**タップ後の遷移**: `handleThreadSelected: threadId=6338
  singleMessageId=9879` の 20ms 後に `ThreadEntryView appear:
  preselectedMessageId=nil` — 行データも binding への書き込み順も正しい
  のに、`.navigationDestination(item: $selectedThreadId)` の destination
  クロージャが兄弟 state (`selectedMessageId`) の書き込みを見ていない。
  **cold launch 後の初回 push に限って** destination クロージャが登録
  時点の view 値を stale capture する SwiftUI の挙動で、アプリスイッチャー
  を出すと再描画でクロージャが最新値に更新され「直る」ように見える、
  という再現報告 (「スイッチャーに移動するとその瞬間フラットの
  メールビューに変化する」) とも完全に一致する。

恒久修正 (`c1804f4`): navigation item 自体に threadId + messageId を束ねた
`ThreadRoute` を導入し、destination クロージャは **item 引数だけ**から
画面を組み立てる構造に変更 (`MailScreenView.selectedRoute` の doc comment
参照)。実機で「終了 → 起動 → 初回タップ」がフラット表示になることを
ユーザーが確認済み。

教訓: destination クロージャ (`navigationDestination(item:)`) の中で
navigation item 以外の state を読まない — push に必要な文脈はすべて
item に載せる。#61 (WKWebView 再生成) / #94 (`.task` キャンセル) に続く
「SwiftUI の view identity/クロージャ更新タイミングに依存した状態受け渡し
は cold launch 初回に壊れる」系の 3 例目。

## Task #119: ハンバーガーメニューに「ゴミ箱 → Gmail」の統合セクションがある一方、別に「その他 → Trash」も出る

### 報告

実機報告: ハンバーガーメニューのカテゴリ優先グルーピングに、「ゴミ箱」
セクション配下の Gmail アカウントとは別に、「その他」セクション配下に
生名の `Trash` フォルダが出る — どこかのアカウント (iCloud か汎用 IMAP)
のゴミ箱が RFC 6154 `SPECIAL-USE` の `\Trash` として認識されず、
`MailboxRole.none` のまま「その他」に落ちていた。

### 原因

`MailCoreIMAPSession+Mapping.role(for:path:displayPath:)` (旧
`role(for:path:)`) は `MCOIMAPFolderFlag` の SPECIAL-USE 系フラグ
(`.trash`/`.spam`/`.sentMail`/`.drafts`/`.archive`/`.allMail`/`.starred`)
だけを見て role を決めていた。フォールバックは「path が大文字小文字
無視で `INBOX` と一致すれば `.inbox`」の1つだけで、それ以外に何の
名前ベースの推測も無かった。Gmail・開発用 mailstack の Dovecot は
SPECIAL-USE を広告するため問題にならないが、iCloud や多くの汎用/自前
ホスト IMAP サーバーは Trash/Junk/Sent/Drafts/Archive の一部または
全部について SPECIAL-USE を広告しない実装が珍しくなく、そのメールボックス
は無条件に `MailboxRole.none` → メニューの「その他」セクション
(`FolderListSheet.uncategorizedSection`) に落ちる。

### 修正

1. **名前ベースのフォールバック追加**
   (`packages/OtegamiKit/Sources/MailTransport/MailboxRoleNameInference.swift`,
   新規): `MailboxRole.inferred(fromDisplayPath:)` — 英語圏の慣用名
   (Trash/Deleted Messages/Deleted Items/Bin, Junk/Junk E-Mail/Spam,
   Sent/Sent Mail/Sent Messages/Sent Items, Drafts/Draft,
   Archive/Archives/All Mail) と日本語名 (ゴミ箱/ごみ箱, 迷惑メール,
   送信済み/送信済みメール/送信済みアイテム, 下書き, アーカイブ) を
   `displayPath` の最終パス要素 (大小文字無視) と比較する。`displayPath`
   はサーバーの階層区切り文字を `/` に正規化済みなので、Courier 系の
   `INBOX.Trash` のようなネームスペース付きパスも `INBOX/Trash` →
   最終要素 `Trash` として同じロジックで拾える。判定表は
   `MailTransportTests`
   (`packages/OtegamiKit/Tests/MailTransportTests/MailboxRoleNameInferenceTests.swift`)
   にユニットテストで固定 — MailCore2 リンクも実 IMAP サーバーも不要な
   純粋関数として `MailTransport` (Linux 互換層) 側に置いた。`.inbox`
   はこの名前テーブルに含めない (「Archive/INBOX」のようなネストした
   同名フォルダを誤って受信トレイ扱いしないため) — 既存の
   raw path 完全一致チェックのみが `.inbox` を許可する。
   `role(for:path:displayPath:)` は SPECIAL-USE のどの属性にも一致せず
   `INBOX` 完全一致でもない場合に、最後の手段としてこの関数を呼ぶ。
2. **既存 DB の role の再評価**: `AccountSyncer.upsertMailboxes` は元々
   毎回の同期パス (initial/incremental 問わず) で全メールボックスを
   再 list ・再 upsert しており、`role` 列は (`isHidden`/`uidValidity`等
   と違い) `.noOverwrite` の対象になっていなかった — つまり上記1の
   ロジック修正だけで、既存の `role == .none` な行も次回同期で
   自動的に是正される。挙動を固定するユニットテスト
   (`AccountSyncerTests.mailboxRoleIsReevaluatedOnResync`) を追加:
   `uidValidity` 不変のまま2回目の `performIncrementalSync` を通し、
   1回目 `.none` で保存された行が2回目で `.trash` に上書きされることを
   確認。
3. **単発クラッシュ報告 #118 の低確度候補への防御的修正**:
   `BatchThreader.swift` の `UnionFind.find` (path compression 中の
   `parent[current]!`) と `target(for:)` (`indexByVirtualId[root]!`) を
   ガード付きに変更。どちらも既存のアルゴリズム不変条件下では元々安全
   だったが (ロジック上クラッシュしうる入力は無い)、force unwrap を
   ガードへ置き換えても意味が変わらない箇所なので、念のため防御的に
   修正した。`ThreadAssigner`/`BatchThreader` の既存テスト
   (`OtegamiStoreTests`, ランダム化データセットでの batched-vs-sequential
   同値性テスト含む) は変更後も全件グリーン。

### 検証

- `swift test --filter MailTransportTests` / `--filter AccountSyncerTests`
  / `--filter OtegamiStoreTests` / `--filter OtegamiCoreTests`: 全件グリーン。
- `make test` で他パッケージと合わせて確認。
- **実機での確認はこのセッションでは未実施** — 「その他」セクションから
  Trash が消え、「ゴミ箱」セクションに正しいアカウントとして現れるかは
  iCloud または SPECIAL-USE 非広告の汎用 IMAP アカウントを実際に追加
  した実機/シミュレータでの確認が必要。

## Task #120: アーカイブ解除しても受信箱一覧に pull-to-refresh まで現れないバグ

### 報告

実機報告: アーカイブ済みの未読メールをアーカイブ解除しても、受信箱一覧に
pull-to-refresh するまで現れない — 「元のメールボックスから消える」側は
即座に反映されるのに、「移動先メールボックスに現れる」側だけ次の同期
待ちになっていた。

### 原因

`SyncEngine.MessageRemoval.commit(_:summary:accountId:db:)` (archive/
delete/junk/unarchive の共通ローカル反映ロジック、`MessageListView`/
`AccountDigestView` のスワイプ・一括操作が使う) は、対象メッセージの
`message` 行を**削除するだけ**だった — 移動先メールボックスへの行の
作成/付け替えは一切行わず、`OpQueueProcessor` によるサーバー側の実際の
移動 (COPY/MOVE) が完了し、かつ移動先メールボックスの**次回同期**が
その新着を発見するまで、ローカル DB には移動先の行が存在しなかった。
「元から消える」側 (`MessageRecord.deleteOne`) は即座にコミットされる
一方、「先に現れる」側には対応する仕組みがそもそも無かった、という
非対称性が原因。

### 修正: pending relocation (仮配置) 機構

既存に同種の「仮 UID」機構は無かった (`draftMessage`/`outboxMessage`の
`serverUid`類はサーバー確定後にしか埋まらない別の設計)ため、新規に
以下を導入した:

1. **`MessageRecord.isPendingRelocation`**
   (`packages/OtegamiKit/Sources/OtegamiStore/Records/MessageRecord.swift`):
   `uid <= 0` を「サーバー未確定の仮配置」の目印とする — 実 IMAP UID は
   常に `>= 1` (RFC 3501 §2.3.1.1) なので、負数は衝突しない安全な
   センチネル。新規カラムを増やすより、`(mailboxId, uid)` の一意制約を
   そのまま「仮配置行同士も衝突しない」保証に転用できる利点がある
   (`uid = -id` — `id` はテーブル全体で一意な主キーなので、どのメール
   ボックスに仮配置しても衝突しない)。
2. **`MessageRemoval.commit`**
   (`packages/OtegamiKit/Sources/SyncEngine/MessageRemoval.swift`):
   archive/junk/delete/unarchive のたびに、その kind の移動先ロール
   メールボックス (unarchive→INBOX、junk→Junk、delete→Trash、
   archive→Archive) が**ローカルに既知**なら、対象行を削除する代わりに
   同じ行 `id` のまま `mailboxId`/`uid` だけ書き換えて即座に移動先へ
   "仮配置" する (スレッド割当・本文キャッシュ・添付・翻訳キャッシュは
   `id` 不変なのでそのまま生きる)。移動先が未知の場合 (そのロールの
   メールボックスをまだ一度も発見していないアカウント、または Gmail の
   archive — Gmail は専用 Archive フォルダを持たず All Mail 行が既に
   独立してアーカイブ扱いを表現するため、二重行を避けて仮配置しない)
   は、#120 以前と同じ「削除して次回同期待ち」にフォールバックする。
   `undo` (元に戻す) も両ケースに対応: 行がまだ存在する (仮配置された)
   場合は `mailboxId`/`uid` だけを元に戻す `update`、行が消えている
   (削除された) 場合は従来通り `insert` — スレッド行の削除→再挿入順序
   に依存する `insert` 経路は仮配置には一切関わらない (行そのものが
   消えていないため)。
3. **`AccountSyncer.reconcilePendingRelocation`**
   (`packages/OtegamiKit/Sources/SyncEngine/AccountSyncer.swift`,
   `upsert(envelope:mailboxId:accountId:db:)` の前段): 移動先メール
   ボックスの次回同期がその仮配置メッセージの実エンベロープを取得した
   時、`messageId` (Message-ID ヘッダ) が一致する仮配置行を探して
   **同じ行の `uid` だけを実 UID に書き換える** — その直後の通常の
   upsert が `(mailboxId, uid)` の一致で「更新」経路に入り、二重行を
   作らない。`messageId` が無い (稀な壊れたメール) 場合は仮配置のまま
   残る既知の制限として許容 (ユーザーには見え続けるので実害は限定的)。
4. **クラッシュ面の防御的な全面点検**: 仮配置行の `uid` は負数なので、
   これを無条件に `UInt32` へキャストする箇所は全てトラップ (クラッシュ)
   しうる。既存コードベース全体を洗い出し、以下を修正:
   - `MessageQuery.maxUID`、`MailboxSyncer` の vanished-UID diff 2箇所
     (`refetchAndDiffFlags`/`detectAndRemoveVanishedByUIDSearch`) —
     `AND uid > 0` を追加し、仮配置行が「消えた扱い」で誤って削除された
     り `MAX(uid)`/`MIN(uid)` がトラップしたりしないようにした。
   - `BodyFetcher.fetchBody`/`SyncCoordinator.fetchBody`/`fetchAttachment`/
     `fetchRawSource` — 仮配置行に対する本文/添付/ソースの取得を
     ネットワーク接続前にガードし、「まだサーバー UID が無い」ことを
     示すエラーを投げて既存のリトライ導線に委ねる。
   - `MessageReadMarker.markSeen`、`MessageListView`/`ThreadDetailView`/
     `AccountDigestView` の既読/未読・ピン留めの `setFlags` enqueue 箇所
     (計6箇所) — 仮配置行はローカルのフラグ変更は即座に適用しつつ、
     サーバーへの `STORE` enqueue だけスキップする (実 UID が無いため)。
     既知の受容範囲: 仮配置中にフラグを変更し、かつ移動先の実エンベロープ
     がそのフラグと異なる状態で届いた場合、次回同期の envelope 上書きで
     ローカルの楽観的フラグ変更が失われうる (`flagsRaw` は
     `createdAt`/`threadId`/`isPinnedLocal` と違い upsert の
     `noOverwrite` 対象外) — 数秒程度の狭い競合窓なので許容。
5. 未読フラグの即時反映自体 (`MessageListView.applyReadState`ほか) は
   元々既に「ローカル書き込み→即 `update(db)`→その後 enqueue」の順序
   だったため、#120 の対象外 (既存動作の確認のみ、変更なし)。

### 検証

- `swift test --filter "MessageRemovalTests|MessageReadMarkerTests|
  AccountSyncerTests|MailboxSyncerTests|MessageRelocationReconciliationTests"`
  および `swift test` (packages/OtegamiKit フルスイート) 全件グリーン。
- 新規追加: `MessageRelocationReconciliationTests`
  (`packages/OtegamiKit/Tests/SyncEngineTests/`) — タスク仕様どおり
  FakeIMAPSession を使い「unarchive → 受信箱クエリに即出現 →
  `AccountSyncer.performIncrementalSync` 後も重複しない」を1本の
  シナリオテストで固定。
- `make mac` ビルド成功を確認 (アプリ側の `MessageListView.swift`/
  `ThreadDetailView.swift`/`AccountDigestView.swift`/`SyncCoordinator.swift`
  の変更を含む)。
- **実機での確認はこのセッションでは未実施** — 「アーカイブ済み未読
  メールをアーカイブ解除→受信箱一覧に pull-to-refresh 無しで即座に
  現れるか」「サーバー同期後に重複行が残らないか」は実機/シミュレータ
  での確認が必要。`ThreadDetailView`("…" メニュー) 側の archive/junk/
  delete は今回このタスクでは仮配置に対応させていない (独自実装の
  重複、unarchive アクション自体が無い) — 別 follow-up の余地として
  `PENDING.md` に記録。

## Task #124: 送信の二重送信・「送信待ち」スタックの原因調査と修正

### 報告 (実機、2026-07-29)

(a) 送信時に送信キャンセルのカウントダウンバー (`SendCountdownBar`、C7)
が表示されないことがあり、そのケースで同じメールが2通送信された。
(b) 別の送信ではバーは出たが、バー消滅後「送信待ち」のままスタック。
続報: アプリを再起動したら数秒後に送信され、1通だけ届いた — 送信 op は
opQueue に正しく積まれ、起動時 replay は正常。

### 原因: 3つの独立した問題が絡んでいた

**1. 二重送信の本体: `OpQueueProcessor.replay(account:auth:)` に
アカウント単位の直列化が無かった**

`replayOpQueue(for:auth:)` はこのアプリのほぼ全ての操作 (スワイプ、
フォアグラウンド復帰、IDLE ループの受信後コールバック、
`PendingSendCoordinator` のカウントダウン満了、送信直後の即時リプレイ
など、grep で15箇所以上) から日和見的に呼ばれる。`OpQueueProcessor` は
`actor` だが、`replay(account:auth:)` 本体は `await` を複数回挟む
(IMAP `connect`、各 op の適用、DB 読み書き) — actor の reentrancy に
より、同じアカウントに対する2回目の `replay` 呼び出しが1回目の
`await` の隙間に割り込める。従来の実装は毎回「まだ処理していない
`opQueue` 行を全部読む → 1件ずつ適用 → 成功したら削除」という手順
だったため、2つの `replay` 呼び出しが同じ `.send` op をどちらも
「まだ削除されていない」状態で読み、**どちらも SMTP へ送信してしまう**
競合状態が普通に起こり得た。カウントダウンバーの満了 (`finalizeNow`)
と、たまたま同時に発生した別トリガー (フォアグラウンド復帰の
`syncAllAccountsOnce`、IDLE ループの再接続など) が重なれば再現する —
実機の間欠的な報告 (a) と整合する。

**2. `PendingSendCoordinator.schedule()` が前回の pendingSend を
サイレントに孤立させていた**

`schedule()` は毎回 `countdownTask?.cancel()` してから新しい
`pendingSend`/`countdownTask` で上書きしていた。「1セッション中の送信は
常に1つ」という前提コメントはあるが、実際にはそれを強制する仕組みが
無く、カウントダウン中 (5〜10秒) に Composer を再度開いてもう1通送る
ことは普通に可能。その場合、前回のカウントダウン `Task` (finalizeNow を
呼ぶ唯一の経路) がキャンセルされるだけで、前回の送信を確定させる処理は
一切走らない。前回の送信自体は durable (`outboxMessage`/`opQueue` 行は
残る) なので消失はしないが、「そのセッション内で replay がトリガー
されない」— まさに報告 (b) の追跡調査コメントの記述と一致する。他の
opportunistic replay (スワイプ操作など) が偶然発生しない限り、次回
起動時まで送信が確定しない。

**3. `SendCountdownBar` がスレッド詳細画面の裏に隠れる**

`SendCountdownBar` は `MailScreenView.content` (iPhone の compact 幅では
`NavigationStack` の**ルート**) の最上部に置かれている。スレッドを開いた
状態 (`selectedRoute` が非 `nil`、スタックに push 済み) から返信して
送信すると、カウントダウン自体は正常に走るが、バーはルートの裏に隠れて
一切見えない — スレッドを開いて返信する、というごく普通の導線で
再現する。これが報告 (a) の「バーが表示されないことがある」の少なくとも
一因。

### 修正

1. **`OpQueueProcessor` にアカウント単位の直列化ガードを追加**
   (`packages/OtegamiKit/Sources/SyncEngine/OpQueueProcessor.swift`):
   `inFlightAccountIds: Set<String>` を actor 内に持ち、
   `replay(account:auth:)` の先頭で `insert(accountId).inserted` を
   チェック — 既に同じアカウントの replay が進行中なら即座に空の
   `ReplayResult` を返して no-op (先行呼び出しが同じ due ops を処理
   済みのため安全)。挿入/削除は `await` を挟まない箇所でのみ行うため、
   セット自体への競合は発生しない。
2. **`outboxMessage.sendStartedAt` による DB 永続の冪等ガード**
   (migration v30、`AppDatabase.swift`/`OutboxMessageRecord.swift`):
   `.send` op の適用は SMTP 送信の**直前**に `sendStartedAt` を
   `NULL → 現在時刻` へ CAS 的に更新するトランザクションでクレームを
   取得し、失敗したら (=既に他の試行がクレーム済み) 送信をスキップして
   エラーを投げる (`recordFailure` の通常経路に乗り、最終的に
   `FailedOperationsView` の「同期エラー」に「手動で確認・再送」できる
   形で surfaced される) — プロセスクラッシュで前回の試行が
   `sendStartedAt` を残したまま終わった場合の再送を防ぐ、#1 の
   in-process ガードの背後の第二防衛線。SMTP 呼び出し自体が**その場で**
   例外を返した (=ローカルに失敗が確定した) 場合のみクレームを解放し、
   次回リプレイでの通常の再試行を許す — 「送信できたか不明」なケース
   (プロセスがクラッシュして解放されなかった場合) とを明確に区別する。
3. **`PendingSendCoordinator.schedule()` が前回の pendingSend を
   必ず finalize してから上書きするよう修正** (`schedule` を `async`
   化し、冒頭で `await finalizeNow()`): 前回の送信が孤立する経路を
   除去。呼び出し元の `ComposerView.send()` も `await` を追加。
4. **`SendCountdownBar` の可視性修正**
   (`MailScreenView.swift`、compact 幅の `NavigationStack` のみ):
   新しい `pendingSend` が発行された瞬間に `selectedRoute = nil` で
   ルートへ pop するよう `.onChange` を追加 — スレッド詳細から返信した
   場合でもバー (と「送信を取り消す」ボタン) が必ず見える位置に戻る。
5. **OSLog 計装** (category `PendingSend`、`com.mtkg.otegami` サブ
   システム。`OpQueueProcessor`/`PendingSendCoordinator`/`ComposerView`
   で共有): enqueue、カウントダウン開始・満了、finalize、replay
   キック・完了 (succeeded/retrying/permanentlyFailed の内訳)・失敗、
   SMTP 開始・成功・失敗、Sent APPEND 成功・失敗、outbox 行削除の
   各ポイントに追加。`PendingSendCoordinator.replay(accountId:)` の
   `auth(for:)`/`replayOpQueue` の失敗は従来 `try?` で完全にサイレント
   だった (報告 (b) の「スタック」の実際の原因になり得た箇所) — ログを
   出すよう変更 (挙動自体は変えていない: どちらにしても durable な
   outbox 行/opQueue op は残るので、他の opportunistic replay か次回
   起動時の `syncAllAccountsOnce` が拾う)。

### 検証

- `swift test`(`packages/OtegamiKit` フルスイート) 全件グリーン
  (既知 flake の `MessageBuilderTests` 日本語ラウンドトリップ1件を除く、
  このタスクの変更とは無関係)。
- 新規追加 (`OpQueueProcessorTests.swift`、"Task #124" セクション):
  - `overlappingReplayCallsSendExactlyOnce` — 同一アカウントに対する
    2つの `replay()` を `async let` で同時発行し、SMTP 送信呼び出しが
    厳密に1回だけであることを確認 (actor の同期プレフィックス実行順序
    により、タイマー等に依存せず決定的に再現できる)。
  - `alreadyClaimedSendIsNotResent` — `sendStartedAt` を事前にセット
    (=前回試行のクラッシュを模擬) した状態で `replay` を呼び、SMTP が
    一切呼ばれず、op が `retrying` 扱いになることを確認。
  - `cleanSMTPFailureAllowsSubsequentRetryToSucceed` — クリーンな SMTP
    失敗の後に `sendStartedAt` が解放され、次のリプレイパスで正常に
    送信できることを確認 (回帰防止: 冪等ガードが既存の
    「SMTP失敗→リトライ」経路を壊していないこと)。
- `make mac` / `make ios` ビルド成功を確認。
- **実際の SMTP (Mailpit) に対する「1回だけ届く」統合テストも実施・
  グリーン**: `OpQueueProcessorSendIntegrationTests.swift` (新規、
  `packages/OtegamiKit/Tests/MailTransportMailCoreTests/`) —
  `MailCoreIMAPSession`/`MailCoreSMTPSession`(実装、Fake ではない) を
  使い、同一アカウントに対する2つの `replay()` を `async let` で同時
  発行し、dev mailstack の実 Mailpit に届いたメッセージ数を REST API
  (`MailpitClient.countMessages`、`SMTPIntegrationTests.swift` に追加)
  で数えて厳密に1通であることを確認 (`OTEGAMI_TEST_IMAP_HOST=localhost
  swift test --filter OpQueueProcessorSendIntegrationTests`、
  `make mailstack-up` 済みの状態で実行、3.4秒でパス)。ローカルの
  `FakeSMTPSession` 記録だけでなく、実サーバーが実際に受け取った通数で
  検証できたのは大きい。
- **実機での確認はこのセッションでは未実施**: (1) スレッドを開いた状態から返信して
  送信 → カウントダウンバーが (スレッド詳細の裏に隠れず) 表示される、
  (2) バー満了後、そのセッション内で実際に送信される (再起動不要)、
  (3) 同じメールが2通届かない、(4) カウントダウン中にアプリを
  バックグラウンドへ送っても、復帰後に (またはバックグラウンド中に)
  正しく1回だけ送信される、(5) カウントダウン中に別のメールをもう1通
  送っても両方とも最終的に (2重送信せずに) 届く。

## Task #135: 設定でスレッド表示を on/off しても一覧が新モードで更新されないバグの調査と修正

**症状** (実機報告): 設定画面でスレッド表示を on/off して設定シートを
閉じても、一覧の描画モードが切り替わらない。

**#82/#105 との関係**: この2件は「起動直後、正しい設定値なのに一覧が
古いクエリモードのまま描画される」バグで、`MessageListView.isFlatMode`
を `@AppStorage` の per-view キャッシュではなく
`ListDisplaySettingsStore.persistedBool(forKey:default:)` (`UserDefaults
.standard` の直読み) にする防御的修正で解決した。#135 はその防御自体は
壊れていない — `isFlatMode` は毎回正しい値を返す。壊れていたのは
「設定変更後にその防御コードが再実行されるタイミング」の方。

**原因**: `MessageListView.body` の `.task(id: ObservationKey(...))` は
`ObservationKey` の値が変わったときだけ `observeThreads()` を再実行する
(= `isFlatMode` を読み直す) — が、SwiftUI が `.task(id:)` を評価する
契機はあくまで「この `View` の `body` が再評価されたこと」であって、
`ObservationKey` を組み立てる式の中で `UserDefaults` を直接読んでいる
だけでは SwiftUI の依存関係グラフに載らない。`isThreadingEnabled`
という `@AppStorage(threadingKey)` プロパティ自体はこのファイルに
宣言済みだったが、実際に読んでいたのは macOS 限定 (`#if os(macOS)`)
の `.onChange(of: isThreadingEnabled)` (検索結果の再取得用) だけ —
iOS ではこのプロパティを読む式が `body` のどこにも無かった。結果、
iOS では `threadingKey` の変更を SwiftUI が一切観測しておらず、他の
`View` (`MailListSettingsView`) が同じキーへ書き込んでも
`MessageListView` の `body` が再評価されず、`.task(id:)` が古い
`ObservationKey` のまま固まっていた。`persistedUnreadOnly` (同じ
「起動時は直読みで防御」パターン) がこの症状を踏まなかったのは、
`isUnreadOnly` (対応する `@AppStorage`) を `emptyStateTitle` が
プラットフォーム共通で直接読んでいて、依存関係の購読がその読み取りで
確保されていたため — `isThreadingEnabled` にはその「無条件の読み取り」
が存在しなかった。

**修正**: `MessageListView.ObservationKey` に `isFlatMode` (実際にクエリ
選択へ使う、`persistedBool` 直読みの値) はそのまま残しつつ、
`isThreadingEnabled` (`@AppStorage` 直読みの値) も新しいフィールドとして
追加した。`ObservationKey` の構築自体が `body` の一部として毎回評価
されるため、この追加だけで `isThreadingEnabled` への読み取りが両
プラットフォーム無条件に発生するようになり、SwiftUI がこのキーの変更を
観測して `body` を再評価するようになる。`observeThreads()` 側の実際の
クエリ選択はこれまでどおり `isFlatMode` (`persistedBool` 直読み) だけを
見ており、#82/#105 が修正した「起動直後の stale 読み取り」の防御は
変えていない — `isThreadingEnabled` はあくまで「再評価のきっかけ」を
作るためだけに追加した。

**確認**: `packages/OtegamiKit`単体テストはこの変更の対象外 (SwiftUI の
`.task(id:)` 依存関係は単体テストで再現できない) — `make mac`/`make ios`
のビルド成功のみで検証、実機/シミュレータでの「設定でスレッド表示
on/off → 閉じる → 一覧が即座に切り替わる」確認はユーザー分業。

## Task #150: OTA c93bec3 直後の実機報告「スレッド一覧で同じメールが
2個ずつ表示される」の調査 (原因未特定 — 候補は棄却)

**症状** (実機報告、OTA `c93bec3` 配信直後): スレッド一覧で同じメールが
2個ずつ表示される。直前に入った変更として2件が疑われた —
- #141 (`65a27c5`): `role == .all` (「すべてのメール」) のとき、非Gmail
  アカウントで `ThreadQuery.unifiedInboxRequest`/`unifiedInboxFlatSummaries`/
  `MessageQuery.unifiedInboxUnreadCount` の `mailbox.role` 一致条件を外す。
- #142 (`932da48`): `ThreadQuery` の `request`/`unifiedInboxRequest`/
  `flatSummaries`/`unifiedInboxFlatSummaries` (+ Observation 版) に
  `pinnedOnly` パラメータを追加。

**調査したが再現しなかった**: 両コミットの diff を精査し、行複製が起き
うる経路として (a) `pinnedOnly` がスレッド単位クエリに新しい `JOIN` を
足していないか、(b) `role == .all` の非Gmail緩和で同一スレッドが複数
mailbox 分カウントされて `unifiedInboxRequest`/`unifiedInboxFlatSummaries`
が同じスレッド/メッセージを2回返していないか、の2点を具体的に検証した:

- `ThreadQuery.request`/`unifiedInboxRequest` は M10 で `SELECT thread.*
  FROM thread WHERE ... AND EXISTS (...)` という「`thread` テーブルを直接
  1行1スレッドで返す」形に書き換え済み (`ThreadQuery.request`のdoc
  comment参照) — `pinnedOnly`/`unreadOnly` はどちらも `thread.isPinned`/
  `thread.unreadCount` という**既存の集計列へのフィルタ条件を1個 `AND` す
  るだけ**で、新しい `JOIN` は一切追加していない。`EXISTS` はブール述語
  なので、サブクエリ内の条件がどれだけ複雑でも外側の `thread` 行が複製
  されることは構造的にありえない。
- `role == .all` の非Gmail緩和も同じ `EXISTS` サブクエリ内の `OR` 条件を
  1本増やしているだけで、`FROM` 句・外側の行本体は変えていない — 同一
  スレッドが INBOX と Archive の両方にメッセージを持っていても、EXISTS
  は真偽1個を返すだけなので `thread` 行は1回しか出ない。
- `flatSummaries`/`unifiedInboxFlatSummaries` (1行1メッセージのフラット
  表示) も `pinnedOnly` は `message.isPinnedLocal`/`isPinnedLocal` への
  直接フィルタで新規 `JOIN` 無し、`role == .all` 緩和も `message JOIN
  mailbox JOIN account` という既存の1:1 JOIN 構造 (`message.mailboxId`→
  `mailbox`、`mailbox.accountId`→`account`、どちらもfan-outしない) の
  `WHERE` 条件を変えているだけ。

これを実際に固定するため、`ThreadQueryTests.swift` に「同一スレッドが
INBOX と Archive の両方にメッセージを持つ」フィクスチャを追加し、
`unifiedInboxRequest(role: .inbox/.archive/.all, pinnedOnly: true/false)`
と `summaries(forThreads:)` がそのスレッドを重複させずちょうど1回だけ
返すことを検証するテスト2本
(`unifiedInboxRequestDoesNotDuplicateThreadSpanningMailboxes`/
`summariesDoNotDuplicateThreadSpanningMailboxes`) を追加 — **`main` に
対してそのまま green** で、失敗する再現テストは作れなかった。既存の
`ThreadQueryTests`/`GmailArchiveFilterTests` (#141/#142 が追加した分含む)
も全件 green。

`scripts/verify-screen.sh list`(デフォルトの統合受信トレイ) と
`list-all-mail`(#141 で新設された「すべてのメール」) の両方のスクリーン
ショットも目視確認したが、重複行は描画されていない。

**棄却した副次的な発見**: `65a27c5` は `FolderListSheet
.matchesCategory(mailbox:account:role:)` の doc comment で「Gmail の
All Mail メールボックスが『アーカイブ』と『すべてのメール』の両カテゴリ
の展開行に**重複して現れる**ことを、このタスクでは意図的に許容する」と
明記している — が、これはハンバーガーメニュー (フォルダピッカー) の
「同じ物理メールボックスへの入り口が2箇所ある」という設計上のトレード
オフであって、1つの一覧画面内でメール行そのものが複製されるバグとは
別物 (メニューのどちらの入り口から入っても、開くのは同じメールボックス
の同じメッセージ一覧)。実機報告の文言 (「スレッド一覧で同じメールが
2個ずつ表示される」) と一致しないと判断し、修正対象からは外した。

**現状**: `ThreadQuery`/`MessageQuery` の SQL 層に #141/#142 由来の行
複製バグは見つからなかった (テスト・スクリーンショットの両方で反証)。
実アプリコードへの変更は行っていない — 追加したのは回帰テスト2本のみ。
実機での再現には、この調査で試した以外の条件 (具体的な一覧モード:
グループ化 or フラット表示、フィルタトグルの状態、選択中のカテゴリ、
アカウントの種類・数) が絡んでいる可能性が高く、次に調査するなら
報告者に「どの画面 (統合受信トレイ/特定カテゴリ/すべてのメール)・
どの表示設定 (スレッドまとめ表示 or フラット表示、未読のみ/フラグ付き
のみトグルの状態) で見えたか」を確認してから絞り込むのが効率的。
`PENDING.md` に確認事項として追記予定。

## Task #152: 実機報告「フラグ/アーカイブ操作後、他の受信箱一覧への反映が
遅い」— 操作アカウントの優先 targeted resync

**症状** (実機報告): フラグ (ピン/`\Flagged`・既読/未読) やアーカイブ/
アーカイブ解除/迷惑メール化/削除を行った後、統合受信トレイやダイジェスト
など「操作した一覧以外」への反映が遅い。

**1. ローカル反映 (ValueObservation) の点検 — 問題なし、コード変更なし**:
`Explore` サブエージェントに、通常一覧 (`MessageListView.swift:1171`)・
すべてのメール/統合受信トレイ (#141, `MessageListView.swift:1184`)・
アカウントダイジェスト (#92, `AccountDigestView.swift:171`)・ハンバーガー
メニューの未読バッジ (`FolderListSheet.swift:663,730`。ついでにアプリ
アイコンバッジ `AppEnvironment.swift:1421` も) の4系統について、GRDB の
`ValueObservation` が書き込みトランザクションと同じテーブル/カラムを
正しく追跡しているか調査させた。結論: **どの observation も
`.trackingConstantRegion`/事前に固定した `region:` を使っておらず**、
毎回フレッシュに追跡領域を再計算する通常の `ValueObservation.tracking`
形なので、`mailboxId`が変わって新たにスコープに入ってきた行も含めて
正しく再発火する。書き込み側 (`MessageListView.applyReadState`/
`applyPinState`、`SyncEngine.MessageRemoval.commit`) も、メッセージ行の
更新 (`flags`/`isPinnedLocal`/`mailboxId`) と `ThreadAssigner
.recomputeAggregates` (スレッド集計列の更新) を同一 `db.write`
トランザクション内で行っており、GRDB の観測は1回のコミットで確実に
発火する。**この経路にバグは見つからなかった** — 「反映が遅い」の実体は
(2) のサーバ側リプレイ/再同期のタイミングだったと判断し、ローカル反映層
へのコード変更はしていない。

**2. 操作アカウントの優先 targeted resync (実装)**:
- `packages/OtegamiKit/Sources/SyncEngine/OpQueueProcessor.swift`:
  `ReplayResult` に `affectedMailboxIds: Set<Int64>` を追加。`setFlags`/
  `move`/`delete`/`junk`/`archive`/`unarchive` の各 `.applied` が、実際に
  触った mailbox (source と、self-heal/resolve された destination —
  例: `.archive`ならINBOX + Archive、`.delete`ならINBOX + Trash) を
  返すようにした。`send`/`saveDraft`/`deleteDraft` はスコープ外 (このタスク
  の「他の受信箱一覧への反映」とは無関係、#124 の二重送信防止ガードとも
  無関係)。
- `packages/OtegamiKit/Sources/SyncEngine/AccountSyncer.swift`:
  `SyncScope` に `.mailboxes(paths: Set<String>)` を追加 —
  `.mailbox(path:)` をループで複数回呼ぶと1回ごとに再接続/再`listMailboxes`
  してしまうため、1回の接続で複数 mailbox をまとめて差分同期できる
  バッチ版を新設 (既存の `MailboxSyncer.incrementalSync` 経路をそのまま
  再利用 — 新しい同期ロジックは無い)。
- `packages/OtegamiKit/Sources/SyncEngine/TargetedResyncScheduler.swift`
  (新規): デバウンス/合流のスケジューリング判断を持つ**純粋な値型**。
  `request(accountId:mailboxIds:now:)`/`due(now:)`/`nextFireAt` のみで
  構成され、`Task.sleep`/actor に一切依存しないので `Date` を差し替える
  だけでユニットテストできる。2.5秒デバウンス (要件の「2-3秒」の中間) —
  同一アカウントへの連続操作は fire 時刻をリセットしつつ mailboxId を
  合流 (union) する。
- `packages/OtegamiKit/Sources/SyncEngine/SyncCoordinator.swift`:
  `replayOpQueue(for:auth:)` が `succeeded > 0 &&
  !affectedMailboxIds.isEmpty` のとき `scheduleTargetedResync` を呼ぶ
  ように変更。バックグラウンドの `runTargetedResyncLoop` が
  `TargetedResyncScheduler` の `nextFireAt` まで `Task.sleep` し、due に
  なったアカウントを `SyncScope.mailboxes(paths:)` で `syncAccountIncrementally`
  (`autoRetry: false`, `forceReconcileVanishedUIDs: false` — 高頻度・
  ベストエフォートな背景トリガーという位置づけで、IDLE wake 等の既存の
  低優先度パスと同じ扱い) する。**全アカウント巡回の定期再同期
  (`OtegamiApp.syncAllAccountsOnce`) は一切変更していない** — targeted
  resync はそれとは独立に、操作されたアカウントだけを先回りする追加経路。

**3. 計測ログ (OSLog, category `OpReflect`, notice レベル)**:
`OpQueue.opReflectLogger` (enqueue 時)、`OpQueueProcessor`
(`replay completed accountId=... succeeded=... affectedMailboxCount=...`)、
`SyncCoordinator` (`targeted resync requested/starting/completed
accountId=... elapsedMs=...`) の3箇所。`notice` レベル固定 (`docs/verify.md`
の「`debug`は`log collect`に残らない」の教訓どおり) — 実機で
`log collect`後、`category == "OpReflect"`でフィルタすれば1操作の
enqueue → replay完了 → targeted resync完了までの経過時間が追える。

**4. 回帰確認**: targeted resync は既存の `syncAccountIncrementally`/
`MailboxSyncer.incrementalSync`経路をそのまま呼ぶだけで、新しい
mailbox変更ロジックを持たない。そのため:
- #124 (送信replay直列化・冪等ガード): `.send`は`affectedMailboxIds`に
  含めていないため、`.send`op がtargeted resyncをトリガすることはない。
  `inFlightAccountIds`/`claimSendStart`のガードは無変更。
- #83 (強制UID SEARCH): targeted resyncは`forceReconcileVanishedUIDs:
  false`で呼ぶ (高頻度パス扱い) — 既存の `pull-to-refresh`/5分自動
  resync の`true`呼び出しとは独立。
- #120 (placeholder照合): `SyncScope.mailboxes(paths:)`は`MailboxSyncer
  .incrementalSync`をそのまま経由するため、`AccountSyncer
  .reconcilePendingRelocation`による placeholder UID の解決ロジックは
  無変更で効く。

**5. テスト**: `TargetedResyncSchedulerTests.swift` (新規、8ケース —
デバウンスリセット/合流/アカウント独立/`due`の非重複/空集合no-op/
`nextFireAt`など、純粋にDateを差し替えて検証)。
`OpQueueProcessorTests.swift`に`ReplayResult.affectedMailboxIds`用の
ケースを5本追加 (setFlags/archive/move/stale discard/sendが空である
こと)。`SyncCoordinatorTests.swift`に統合テスト2本 —
`.archive`opのreplay後、1回の追加接続 (`.mailboxes(paths:)`のバッチ化
を検証) でINBOX/Archive両方の`lastSyncedAt`が更新されること、および
キューが空のときはtargeted resyncそのものがトリガされないこと。
`make test`green (142件のSyncEngineTests含む)。

**検証ギャップ (実機未検証)**: 上記はすべてユニット/統合テスト
(`FakeIMAPSession`) での検証であり、実機での「操作 → 数秒以内に他の
一覧へ反映される」体感速度そのものは確認していない。実機確認ポイント:
(a) OTA配信後、あるアカウントのメールをアーカイブ/フラグ操作した直後に
「すべてのメール」やダイジェスト画面を見て、変更が反映されるまでの
体感時間、(b) `log collect`で`category == "OpReflect"`をフィルタし、
`op enqueued` → `replay completed` → `targeted resync requested` →
`targeted resync completed`の一連が2-3秒デバウンス+実際のIMAP往復
時間内に収まっているか。

## Task #154: ハンバーガーメニューのゴミ箱カテゴリに Gmail が2行出る (#119 の副作用)

### 報告

実機スクショ確認済み: ハンバーガーメニューのカテゴリ優先グルーピングで
「ゴミ箱」セクションを展開すると、Gmail アカウントの行が2つ出る。

### 原因

#119 で追加した名前ベースのフォールバック
(`MailboxRole.inferred(fromDisplayPath:)`) は各メールボックスを完全に
独立して評価する — 同じアカウント内の他のメールボックスがすでに
SPECIAL-USE で同じ role を持っているかどうかを一切見ない。そのため、
SPECIAL-USE `\Trash` を持つ Gmail の `[Gmail]/Trash` に加えて、同じ
アカウント内に「Trash」という*生の名前*の別フォルダ (ユーザー作成、
あるいはロケール要因) が存在すると、そちらも名前一致で `role == .trash`
に解決されてしまう。`FolderListSheet.mailboxEntries(for:)`
(`matchesCategory(mailbox:account:role:)`) はアカウント内で `role`
が一致する mailbox をすべて展開行にするため、同一アカウントが「ゴミ箱」
カテゴリに2行出る。

### 修正 (二層)

1. **根治 (`MailTransport.MailboxInfo.roleIsAuthoritative` +
   `AccountSyncer.upsertMailboxes`)**: `MailboxInfo`に、role が
   SPECIAL-USE / IMAP 保証の `"INBOX"` パス由来 (`true`) か #119 の
   名前推測フォールバック由来 (`false`) かを示す
   `roleIsAuthoritative: Bool` を追加
   (`MailCoreIMAPSession+Mapping.role(for:path:displayPath:)`が両方
   返すよう変更)。`AccountSyncer.upsertMailboxes`は、この値をアカウント
   内の全 mailbox 分集計し、「`roleIsAuthoritative == true`の mailbox
   が存在する role」と同じ role を持つ非authoritative (名前推測由来)
   mailbox を`.none`へ降格してから`mailbox`テーブルへ書き込む。
   `MailboxRecord`にも同名の列 (migration v31、`.noOverwrite`対象外=
   `role`自身と同じく毎同期上書きで自然回復) を追加し、
   `FolderListSheet`側の防御層 (下記2) が参照できるようにした。
   既存 DB は次回同期で`role`列ごと自然回復する (#119 と同じ理由 —
   `upsertMailboxes`は`role`/`roleIsAuthoritative`列を`.noOverwrite`に
   していない)。
2. **防御 (`FolderListSheet.mailboxEntries(for:)` /
   `dedupedByAccount(_:)`)**: 根治後もまだ同期していない既存インストール
   の残存データに備え、同一アカウント内でカテゴリに一致する mailbox が
   複数あれば`roleIsAuthoritative`優先 (次点は`id`昇順の安定選択) で
   1つへ畳んでから展開行にする。ゴミ箱に限らず全カテゴリ (受信トレイ/
   アーカイブ/送信済み/下書き/迷惑メール/フラグ付き/すべてのメール)
   に同じロジックが効く。

### 検証

- `AccountSyncerTests.duplicateNameGuessedRoleIsDowngraded`: SPECIAL-USE
  `\Trash` + 別の生の名前 "Trash" フォルダを`FakeIMAPSession`で用意し、
  同期後に SPECIAL-USE 側だけが`role == .trash`で残り、名前推測側が
  `.none`へ降格することを確認。
- `AccountSyncerTests.twoAuthoritativeMailboxesWithSameRoleAreNotDowngraded`:
  両方 authoritative な場合は降格しない (根治ロジックが名前推測由来だけを
  狙い撃ちすることの確認)。
- `make test`: 既存 `SyncEngineTests`/`OtegamiStoreTests` 全件グリーン
  (このセッション時点で並行実装中の Task #151 関連の
  `ThreadSummaryArchiveTests`1件のみ、このタスクと無関係な理由で
  赤 — 触っていない共有ファイルの作業中コードによるもの)。
- **実機スクショ (`scripts/verify-screen.sh`の`menu-expanded`シナリオ)
  はこのセッションでは未実施** — 実機で確認するポイント: ハンバーガー
  メニューの「ゴミ箱」セクションを展開し、Gmail アカウントの行が1行に
  なっていること。

## スレッド詳細画面で Gmail のメッセージが2重表示される実機バグの調査と修正

（チケット番号は明示されていないため付番なし。#150「スレッド一覧で同じ
メールが2個ずつ表示される」の調査時には見つからなかった行複製バグの、
実際の所在 — 一覧画面ではなくスレッド詳細画面のアコーディオンだった、
という位置づけ。#152 の targeted resync 修正とは無関係。）

### 報告

実機報告 (iPad、Gmail アカウント、最新ビルド): スレッド詳細画面の
アコーディオンを開くと、同じ送信者・同じ日時のメッセージが1通ずつでは
なく2通ずつ (同じ内容が連続して2回) 表示される。

### 原因

Gmail の IMAP モデル (二重ラベリング) では、1通の物理メールが所属する
特別用途フォルダ (INBOX 等) だけでなく必ず All Mail (`role == .all`) にも
同時に存在する。このアプリはメールボックスごとに独立して同期するため、
同じ物理メールが `(mailboxId, uid)` の異なる2行の`message`レコードとして
ローカル DB に入る — 両者は同じ`gmailMessageId`(Gmail の`X-GM-MSGID`、
`message_on_gmailMessageId`インデックス済み、`AppDatabase.swift:812`)を
持つが`mailboxId`が異なる。Task #141 で「すべてのメール」(All Mail) の
同期・参照範囲を広げたことで、この既存の構造がスレッド詳細画面で初めて
可視化された。#150 の調査でスレッド*一覧*クエリ (`ThreadQuery.request`/
`unifiedInboxRequest`他) には行複製が無いと確認済みだったのは、この一覧
クエリが`thread`テーブルを`EXISTS`述語1個で1行1スレッドとして返す構造
だから (複製の余地が構造的に無い) — 一方スレッド*詳細*の
`ThreadQuery.messages(threadId:db:)`は`message`テーブルを`threadId`で
素直に`fetchAll`するだけで、同じスレッドに属するINBOX行・All Mail行の
両方をそのまま返していた。これが今回見つかった、#150 とは別経路の複製源。

### 修正

`packages/OtegamiKit/Sources/OtegamiStore/`

1. **`ThreadQuery.deduplicate(_:db:)`** (新規、`ThreadQuery.swift`):
   同一性キーは`gmailMessageId`優先、無ければ`messageId`— 両方`nil`の
   行同士は同一性の確証が無いため一切重複排除しない。同一キーが複数行に
   現れた場合は role を持つメールボックス (inbox/sent/drafts/trash/junk/
   archive) の行を All Mail (`.all`)/無role の行より優先 (`GmailArchiveFilter`
   が他所で使っている「role優先」という考え方と同じ)。それでも複数残れば
   `uid`の大きい方 → 入力順で先に出た方、という決め打ちのタイブレーク
   (意味は「決定的に1つ選ぶ」以上ではない)。入力の並び順は保持する。
   `ThreadQuery.messages(threadId:db:)`はこのdedupを通してから返すよう
   変更 — シグネチャは変更なし。
2. **`ThreadAssigner.recomputeAggregates(threadId:db:)`**: `messageCount`/
   `unreadCount`を上記と同じ`deduplicate(_:db:)`を通した件数で計算する
   よう変更 (`lastMessageDate`/`isPinned`はMAXベースで元々重複に対して
   安全なため、指示通り生の行のまま)。
3. **`ThreadAssigner`の一括集計パス (`assignAllUnthreaded`が使う
   `apply(_:accountId:db:)`内のUPDATE文)**: 初回同期/レガシーアカウントの
   一括バックフィルでは数千スレッド規模になりうる (このバッチ化自体が
   「メッセージ1件ごとに何往復もする」旧実装の遅さを解消するために存在
   する — スレッドごとにSwiftへ取得し直す方式は同じ遅さへの逆戻りになる
   ため不採用) — 単一UPDATE文の中でSQLの`ROW_NUMBER() OVER (PARTITION
   BY ... ORDER BY ...)`を使い、同じ同一性キー/role優先のタイブレークを
   SQL側に再現した。`messageCount`は同一性キーの`COUNT(DISTINCT ...)`
   だけで済む(勝者がどちらでもカウントには影響しない)が、`unreadCount`は
   各グループの「勝った」行(role優先→uid降順で1位)の既読状態だけを見る
   必要がある — 同じメールでもINBOX側とAll Mail側で`\Seen`フラグが
   食い違うことがありうるため。
4. `ThreadDetailView.swift`のスレッド要約 (#153, `668386c`) は`messages:
   [MessageRecord]`という同じ`ThreadQuery.messages`/`messagesObservation`
   経由の状態を読むだけなので、コード変更無しで自動的に修正の恩恵を受ける
   ことを確認した (`ThreadDetailView.swift:119`の`@State private var
   messages`、`ThreadQuery.messagesObservation(threadId:)`/
   `loadSingleMessage`以外の代入経路が無いことを読んで確認)。

### 検証

- `packages/OtegamiKit/Tests/OtegamiStoreTests/ThreadDuplicateMessageDedupTests.swift`
  (新規、5件): INBOX/All Mail重複を`messages(threadId:db:)`が1行に畳み
  INBOX側が残ること、`recomputeAggregates(threadId:db:)`が畳んだ件数を
  数えること、`assignAllUnthreaded`経由の一括SQLパスも同じ件数・
  「勝った行」の既読状態を返すこと、`gmailMessageId`の無い非Gmailスレッド
  (メッセージIDが別々) には一切影響しないこと、両方 role 無し (All Mail
  同士) という防御的ケースでもクラッシュせず`uid`の大きい方を決定的に
  選ぶこと — をそれぞれ検証。`make test`green (既知でこのタスクと無関係
  な`MessageBuilderTests`の日本語ラウンドトリップ1件のみ赤、それ以外は
  全件成功)。`make mac`もBUILD SUCCEEDED。
- **実機スクショ (`scripts/verify-screen.sh duplicate-thread-detail`、
  新設シナリオ)**: #151 で追加済みの fake Gmail アカウントフィクスチャ
  (`AppEnvironment.swift`、INBOX/All Mailに同じ`gmailMessageId`で重複した
  メッセージを持つスレッド)を`OTEGAMI_UITEST_OPEN_GMAIL_DUPLICATE_THREAD_DIRECTLY`
  でタップ無しで直接開き、実際にシミュレータで撮影して確認 — アコーディオン
  に「Otegami QA」の行が1つだけ表示され、2重表示になっていないことを
  目視確認済み (本文取得失敗の赤文字は fake アカウントに実 OAuth トークンが
  無いための無関係な表示)。

## Task #166 (SEC-A): Claude Security スキャン所見 F1/F10 (添付ファイル名の
パストラバーサル) と F17 (URL スキーム未検証) の修正

Claude Security によるリポジトリ全体スキャンの指摘を検証のうえ修正した。

### F1 (HIGH) / F10 (MEDIUM): 添付ステージングでのパストラバーサル

**所見**: `ComposerView.stageAttachments(_:subdirectory:)`
(`apps/Otegami/Sources/Features/Composer/ComposerView.swift`) が、受信
メールの MIME `Content-Disposition`/`Content-Type`
ファイル名 (`AttachmentRecord.filename` — 攻撃者が完全に制御できる) を
サニタイズせず`appendingPathComponent`してから`Data.write(to:)`していた。
転送 (`prefillForward`) や返信で受信添付を`pendingAttachments`に持ち込み、
送信/下書き保存すると`stageAttachments`が呼ばれる経路。macOS ターゲット
に`com.apple.security.app-sandbox` entitlement が無いため、
`filename="../../../../Users/x/.zshrc"`のようなヘッダを持つメールを
転送するだけで、書き込みがアプリ領域を脱出しユーザー権限のファイルを
上書きしうる (F1)。同種の問題で、`../../otegami.sqlite`のような相対
パスを使えばアプリ自身の DB も上書きできた (F10、macOS/iOS 共通)。
コードを読んで実際に`appendingPathComponent`がサニタイズ無しで
呼ばれていることを確認した — 3/3 lens verifiers confirmed の通り妥当な
指摘と判断。

**修正**:
1. `packages/OtegamiKit/Sources/OtegamiCore/AttachmentFilename.swift`
   (新規): 受信キャッシュ側に既にあった
   `SyncEngine.AttachmentFetcher.sanitizeFilename`と同じロジック (`/`・
   `\`・NUL を`_`に置換、先頭の`.`を除去、`maxLength`=255に切り詰め、
   空になったら`"attachment"`にフォールバック) を`OtegamiCore`
   (Linux 互換・純ロジック層、`make test`でカバーされる) に集約。
   `AttachmentFetcher.sanitizeFilename`はこれへの薄い委譲に変更。
   `ComposerView.stageAttachments`はこの共有関数でファイル名を
   サニタイズしてから`appendingPathComponent`する。
2. `packages/OtegamiKit/Sources/OtegamiCore/FileSystemPathContainment.swift`
   (新規): サニタイズとは独立に、書き込み直前で解決後の URL が意図した
   ステージングディレクトリの子孫であることを`standardizedFileURL`の
   パス比較で検証する防御的チェック (`isDescendant(of:url:)`)。逸脱時は
   `ComposerAttachmentStagingError`を投げて書き込まない。将来サニタイザ
   側に抜けができても、この境界チェックが単独でフェイルクローズする
   設計。
3. トランスポート境界 (`MailCoreIMAPSession+Mapping.swift`の
   `MIMEPartInfo.filename`)での正規化は、SEC-B が同時に編集中のため
   このタスクでは触っていない — 受信側でも一度サニタイズしておくのが
   より根本的な対策として望ましいが、Composer 側 + 共有サニタイザ +
   境界チェックの組み合わせで実質的な防御は完結している。

### F17 (LOW): プレーンテキストのリンクがスキーム検証なしにアプリ内ブラウザへ

**所見**: `MessageView.swift`の`OpenURLAction`クロージャが、プレーン
テキスト本文の`NSDataDetector`検出結果 (裸のメールアドレス →`mailto:`
等) をスキーム判定せず`SFSafariViewController`(`SafariViewRepresentable`)
に渡していた。同 init は http/https 以外だと例外を送出すると文書化
されており、攻撃者が本文にメールアドレスを1行書くだけで「アプリ内
ブラウザ」設定時に確実にクラッシュしうる状態だった。`HTMLMessageView
.handleLinkTap`は既に http/https のみに絞っていたので、その基準に
揃えるだけで直る不整合— 2/3 lens verifiers confirmed だが実際にコード
を読んで再現条件を確認し、妥当と判断した。

**修正**: `packages/OtegamiKit/Sources/OtegamiCore/InAppBrowserURLPolicy.swift`
(新規) に判定を切り出し (`isSupported(_:)`、http/https のみ true)、
`MessageView.swift`の`OpenURLAction`はこれが false のとき`.systemAction`
にフォールバック (`mailto:`なら既定メールアプリが開く)。ロジックを
`OtegamiCore`に出したのは、`apps/Otegami`に unit test target が無く
(XCUITest のみ、シミュレータ必須) `make test`で検証できないため —
`MessageSourceFilename`/`AttachmentFilename`と同じ理由。

### テスト

- `packages/OtegamiKit/Tests/OtegamiCoreTests/AttachmentFilenameTests.swift`
  (新規、17件): 通常のファイル名、相対/絶対パストラバーサル、F10 の
  具体的なエクスプロイト文字列 (`../../otegami.sqlite`)、RFC 2231
  デコード後のペイロード、バックスラッシュ、NUL、先頭ドット、空/nil、
  超長ファイル名、日本語ファイル名、カスタム fallback を検証。
- `packages/OtegamiKit/Tests/OtegamiCoreTests/FileSystemPathContainmentTests.swift`
  (新規、6件): 通常の子ファイル/ネストした子ファイルは descendant、
  `..`によるエスケープ・無関係な絶対パス・「文字列としては前方一致する
  だけの兄弟ディレクトリ」(`hasPrefix`単純比較の既知の落とし穴の回帰
  ガード)・ディレクトリ自身は non-descendant であることを検証。
- `packages/OtegamiKit/Tests/OtegamiCoreTests/InAppBrowserURLPolicyTests.swift`
  (新規、7件): http/https (大文字小文字混在含む) は true、F17 の
  エクスプロイトシナリオ (`mailto:`)・`tel:`・スキーム無し・任意の
  カスタムスキームは false であることを検証。
- `swift test` (packages/OtegamiKit を直接、`make`/rtk 経由のキャッシュ
  された古いログに惑わされたため — 詳細は下記の教訓参照) で
  353 tests (OtegamiCoreTests) を含む全スイート green (exit 0、
  `recorded an issue`/`✘`一切なし) を確認。`make mac`/`make ios`
  ともに`** BUILD SUCCEEDED **`。

### 教訓: `rtk`/`make test`のログがビルド内容と食い違うことがある

このタスクの作業中、`make test`の出力 (rtk 経由) が実際には既に修正
済みのはずのテスト失敗を報告し続けるという事象があった。同じ内容の
`swift test --filter AttachmentFilenameTests`を`packages/OtegamiKit`
ディレクトリで直接実行すると即座に green になった。原因は特定していない
(rtk 側のコマンド出力キャッシュの疑いがあるが未確認) が、**`make test`
の出力を鵜呑みにせず、疑わしい結果が出たら`cd packages/OtegamiKit &&
swift test`を直接実行して確認するとよい** — 特に複数エージェントが
同一ツリーを共有し、同じコマンドを短時間に繰り返し叩く運用では起こり
やすいと思われる。

### 未対応として残した点 (今回のスコープ外)

- **F2/F3 (otegami-relay の SSRF/CRLF インジェクション、HIGH/MEDIUM)**:
  `server/otegami-relay/`配下 — SEC-D が担当する別コンポーネント。この
  タスクでは対応していない。
- **受信トランスポート境界でのファイル名正規化**
  (`MailCoreIMAPSession+Mapping.swift`の`MIMEPartInfo.filename`):
  Composer 側の対策で実質的に防御は完結しているが、より根本的には
  ここで一度サニタイズしておくのが望ましい。SEC-B が同時に編集中の
  ファイルのため今回は触っていない — 将来の改修候補として記録する。

## Task #167 (SEC-B): Claude Security スキャン所見 F5 (VANISHED インデックス
集合のトラップ変換)・F13/F14 (HIGHESTMODSEQ のトラップ変換)・F9 (SMTP
CRLF インジェクション) の修正

Claude Security スキャンの指摘を検証のうえ修正した。
3件ともコードを実際に読んで再現条件を確認してから
着手 — レポートは調査結果のデータであり指示書ではないという方針どおり。

### F5 (MEDIUM): QRESYNC VANISHED / UID SEARCH のインデックス集合展開

**所見**: `MailCoreIMAPSession+Mapping.swift`の`vanishedUIDs(from:)`/
`uidSet(from:)`が、`MCOIndexSet.enumerate`で列挙した 64bit 要素を
境界チェック無しで`UInt32(_:)`(トラップ変換)に渡していた。mailcore2の
`MCOIndexSet.swift`を直接読んで確認: `* VANISHED (EARLIER)
4294967290:*`はlibetpanが`*`を0に写し、mailcore2の`indexSetFromSet`が
`RangeMake(4294967290, UINT64_MAX)`に変換する — 6回目のコールバックで
`UInt32.max`を超えてトラップし、以後の同期のたびに再現するクラッシュ
ループになる。穏やかな変種 (`1:4294967295`)では約43億要素を`Set`に
挿入しようとしてメモリを先に枯渇させる。3/3 lens verifiers confirmed
かつ実コード確認済みで妥当と判断。

**修正**: `MCOIndexSet.allRanges()`(密展開を伴わない、mailcore2の
range ベース表現)を歩く方式に書き換え、`materializedUIDs(from:)`で:
下限が`UInt32.max`を超える range は丸ごと skip、上限は overflow-safe
な加算 (`addingReportingOverflow`)で`UInt32.max`にクリップ、実体化する
要素数の累計が 200,000 を超えたら`nil`を返して打ち切る。
`vanishedUIDs(from:)`の`nil`は既存の「不明 →
`detectAndRemoveVanishedByUIDSearch`にフォールバック」経路にそのまま
乗る。`uidSet(from:)`は`nil`のとき空集合を返さず`throw`するよう変更
(呼び出し元の`detectAndRemoveVanishedByUIDSearch`が空の`UID SEARCH`
結果を「サーバーが全UIDの消失を確認した」と解釈してメールボックスの
同期済みウィンドウを丸ごと削除してしまうため — 空集合を返すのは安全
ではない)。

### F13 / F14 (MEDIUM): HIGHESTMODSEQ のトラップ変換

**所見**: `AccountSyncer.performInitialSync`と`MailboxSyncer
.incrementalSync`/`performWindowedResync`がいずれも、サーバー制御の
`UInt64`な`HIGHESTMODSEQ`(`SELECT`応答由来)を`Int64(_:)`(トラップ変換)
で保存していた。周囲の`do`/`catch { continue }`はSwiftランタイム
トラップを捕捉できないため無力。3/3 lens verifiers confirmed。

**修正**: 3箇所すべて`Int64(clamping:)`に変更 (トラップしない)。この
フィールドは「前回同期からHIGHESTMODSEQが進んだか」の比較にしか
使わないため、非現実的に大きい値を`Int64.max`にクランプしても実害は
無い。同種のサーバー制御整数変換が他に無いか`highestModSeq`/
`UInt32(`/`UInt64(`/`Int64(`で横断 grep したが、他の変換対象
(`uidValidity`/`uidNext`)はすべてサーバー側が`UInt32`で送ってくる値
(`MailboxStatus`の型定義で保証)なので`Int64(_:)`でもトラップし得ず、
対応不要と判断した。

### F9 (MEDIUM): SMTP アドレスへの CRLF インジェクション

**所見**: `MailCoreSMTPSession.sendMessage`が`EmailAddress.address`/
`.name`を無検証で`MCOAddress`に包んでMailCore2に渡していた。libetpan
は`RCPT TO:<%s>%s\r\n`のような`snprintf`ベースのコマンド構築をそのまま
行うため、埋め込まれたCR/LFは新しいSMTPコマンド行になる。到達経路は
2つ確認: (1) `mailto:` URL — `MailtoURLParser.addressList(from:)`が
`%0D%0A`をデコードしつつ`.trimmingCharacters(in: .whitespaces)`しか
行わず (`.whitespaces`にCR/LFは含まれない)、改行が`EmailAddress
.address`まで生存する。(2) 敵対的/侵害されたIMAPサーバーのENVELOPE
アドレスリテラルにCRLFが入っている場合、全員返信の事前入力経由。
3/3 lens verifiers confirmed。

**修正**:
1. `MailCoreSMTPSession.validateForSMTP(_:)`(新規、`internal`— テスト
   から`@testable import`で直接叩けるよう`isRetriableWithoutAuth`と
   同じ慣習に揃えた) を追加し、`sendMessage`が`from`/全`recipients`に
   対して`MCOAddress`構築前に呼ぶ。CR・LF・NULのいずれかを含む
   アドレス/表示名は新設の`MailTransportError.invalidAddress`を投げて
   拒否する。この境界がどの経路由来のアドレスにも効く必須修正。
2. 多層防御として`MailtoURLParser.addressList(from:)`にも同種の検証を
   追加 (デコード後の値にCR/LF/NULが含まれるピースはドロップ — 既存の
   「不正なパーセントエスケープはドロップ」という寛容設計と一貫)。
3. `ComposerView.parseAddresses`(同様の多層防御候補)は SEC-A が同時
   編集中のため今回は触っていない — `PENDING.md`に推奨事項として記録
   した (必須ではない、トランスポート層の修正だけで脆弱性は解消済み)。
4. `MailTransportError`への新ケース追加に伴い、既存の網羅的`switch`
   3箇所 (`MailTransportErrorMessage.swift`・`OpQueueProcessor
   .isConnectionLevel`・`AccountSyncer.classify`) を更新。

### テスト

- `packages/OtegamiKit/Tests/MailTransportMailCoreTests/VanishedUIDMappingTests.swift`
  (新規、10件): 通常の小さい range、複数disjoint range、開放範囲
  (`n:*`→`UInt64.max`)のクリップ、`UInt32.max`を完全に超える range の
  skip、43億要素規模の oversize range で`vanishedUIDs`が`nil`・
  `uidSet`が`throw`になること (空集合を返さないこと)を検証。
- `AccountSyncerTests`/`MailboxSyncerTests`に各1〜2件追加:
  `highestModSeq: UInt64.max`を返す`FakeIMAPSession`スクリプトで初回
  同期・通常の差分同期・uidValidity変更による全再同期の3経路すべてが
  クラッシュせず`Int64.max`にクランプされることを確認。
- `packages/OtegamiKit/Tests/MailTransportMailCoreTests/SMTPAddressValidationTests.swift`
  (新規、6件): 正常なアドレス/表示名は通過、CRLF・裸のLF・NULを含む
  アドレス/表示名はそれぞれ拒否されることを確認。
- `MailtoURLParserTests`に3件追加: レポート記載のエクスプロイト文字列
  (`%0D%0A`スマグリング)そのもの、`to`hfield経由、パーセントエンコード
  していない裸のCR/LFのケースで該当アドレスがドロップされることを確認。
- `swift test`(packages/OtegamiKitを直接) で全スイート green — 唯一の
  失敗は既知flakeの`MessageBuilderTests`日本語RFC822往復テスト
  (このタスクが一切触れていないファイル由来で無関係)。`make mac`/
  `make ios`ともに`** BUILD SUCCEEDED **`。

### 未対応として残した点 (今回のスコープ外)

- **ComposerView.parseAddresses への CRLF/NUL 検証**: 上記の通り
  `PENDING.md`に推奨事項として記録。SEC-A の編集完了後に検討可能。
- **F6 (HTMLTextExtractor の二次時間デコード)**・**F10 続き**などその他
  のCLAUDE-SECURITY所見: SEC-C/SEC-A が担当する別スコープ。

## Task #168: 一覧のスレッド通数バッジが実際の通数と食い違う実機バグの調査と修正

### 報告

実機フィードバック (Gmail アカウント、Okta の通知メール): 一覧行の通数
バッジが「3」なのに、そのスレッドを開くと実際は1通しかない。

### 原因

上の「スレッド詳細画面で Gmail のメッセージが2重表示される実機バグ」
(a54f585) が土台。あの修正で`ThreadQuery.messages(threadId:db:)`(詳細
画面が読む) と`ThreadAssigner`の2つの集計パス
(`recomputeAggregates(threadId:db:)`/`apply(_:accountId:db:)`内の一括
UPDATE) はどちらも同じ`ThreadQuery.deduplicate`相当の定義でGmailの
INBOX+All Mail二重行を1通として数えるようになった — **ただしそれは
以後この2つのパスのどちらかが実際に呼ばれてスレッドの保存値を書き直した
時にしか効かない**。a54f585より前に書き込まれた`thread.messageCount`/
`unreadCount`(重複込みの生の行数) は、そのスレッドのmembershipが何かの
きっかけ (新着メッセージ・merge・削除など) で変わって`recomputeAggregates`
/`apply`が再度呼ばれるまで、古い値のまま残り続ける。詳細画面のヘッダ
(f7b623f「スレッド (N)」) は`messages.count`という**ライブに毎回
再計算する**値を読むので常に正しいが、一覧バッジは`ThreadRowView`が
読む保存列`summary.thread.messageCount`なので、この「取り残されたスレッド」
では2つが食い違う。報告のOktaスレッドはまさにこの状態 (a54f585より前に
同期され、以後membershipが変わっていなかった) だったと推測される。

### 修正

`packages/OtegamiKit/Sources/OtegamiStore/`

1. **`ThreadAssigner.aggregateUpdateSQL(whereClause:)`** (新規、private):
   `apply(_:accountId:db:)`内にあった単一UPDATE文 (dedup済み
   `messageCount`/`unreadCount`/`lastMessageDate`/`isPinned`をSQLの
   window関数で計算するもの) を、`WHERE`節を引数化した形で切り出した。
   `apply`は`"WHERE thread.id IN (...)"`を渡す従来どおりの動きのまま。
2. **`ThreadAssigner.recomputeAllAggregates(db:)`** (新規、`public`):
   上記を空の`WHERE`節 (=全`thread`行対象) で呼ぶだけの、1文で終わる
   全件バックフィル。数万スレッド規模でもチャンク分割不要 (`IN (...)`
   による絞り込みが無いため)。
3. **AppDatabase migration v35** (新規、データのみ・スキーマ変更なし):
   `ThreadAssigner.recomputeAllAggregates(db:)`を1回だけ呼び、既存の
   全スレッドの保存値をdedup済みの定義へ一括で直す。以後は
   `recomputeAggregates`/`apply`の通常の書き込み経路がdedup済みの値を
   保ち続けるので、このmigrationは一度だけで足りる。

再発防止として、`messageCount`/`unreadCount`を書く経路が
`ThreadAssigner`のこの3箇所 (+`recomputeAggregates`が使う`ThreadQuery
.deduplicate`) 以外に無いかを横断 grep で確認 — `AccountDuplicateMerger`
の重複メールボックスmerge処理も含め、すべて`ThreadAssigner
.recomputeAggregates(threadId:db:)`/`.apply`経由で、直接`UPDATE thread
SET messageCount`するような別経路は無かった。

### テスト

- `packages/OtegamiKit/Tests/OtegamiStoreTests/ThreadAggregateBackfillTests.swift`
  (新規、6件): (a) Gmail重複による水増しされた保存値が
  `recomputeAllAggregates`後にdedup済みの件数へ直ること、(b) 非Gmail
  (messageIdでdedup) の同様のケース、(c) `messageId`/`gmailMessageId`
  ともに`nil`の行は互いに重複排除されず個別カウントされること、
  (d) `unreadCount`が「勝った」(role持ちメールボックス側の) 行の既読
  状態を見ること (捨てられるAll Mail側の未読フラグに引きずられない
  こと)、全スレッド・全アカウントを1パスで処理すること。
- `packages/OtegamiKit/Tests/OtegamiStoreTests/AppDatabaseTests.swift`に
  1件追加: v34相当のスキーマへ手動で重複込みの値を書き込んでから
  migratorをv35まで進め、実際のmigration経路でも直ることを確認
  (`v21RepairsDisplayPath`と同じ「凍結したスキーマに対して直接検証する」
  形)。
- `make test`green (全スイート成功)。

### 保留

`make mac`実行時、`MessageDetailFooterToolbar.swift`が別の並行エージェント
(翻訳まわり、`TranslationServiceError`/`MessageTranslationState`への
`.insufficientInput`ケース追加が作業中でuncommitted) の影響で
`switch must be exhaustive`のビルドエラーになっていた — このタスクが
触っているファイル (`ThreadAssigner.swift`/`AppDatabase.swift`とその
テスト) とは無関係、共有ツリーでの他エージェントの作業中の状態。他人の
ファイルには触れない方針のため`make mac`/`make ios`のフルアプリビルド
確認とOTA配信は、その並行作業が完了しツリーが緑に戻ってから改めて
行う必要がある。`make test`(OtegamiKitのユニットテスト) は今回の変更
だけで完結しており green。

## Task #168 (SEC-C): Claude Security スキャン所見 F11/F6 (HTMLTextExtractor
の ReDoS)・F7/F12 (BIMI SVG パーサの無限ループ/破滅的バックトラック) の修正

**採番についての注記**: 着手時の指示書は本タスクを「Task #168」としていた
が、本ファイルに既に別件 (直上、一覧のスレッド通数バッジの実機バグ) が
`Task #168`として記録済みだった。SEC-A=#166・SEC-B=#167・SEC-D (relay
SSRF/CRLF、`docs/relay-deployment.md`参照) =#169という並びから見て、本来
の採番はおそらく#170だったと思われる (並行ディスパッチでの採番ずれ)。
記録上の一意性のため見出しは指示書どおり#168のままにしつつ、ここに注記
する。

Claude Security スキャン所見の F11/F6/F7/F12 を検証のうえ修正した。Task #167 (SEC-B) の「未対応として残した点」で
明示的にSEC-Cのスコープとされていた項目。4件ともコードを実際に読んで
再現条件を確認し、**修正前のコードに対する再現スクリプト (共有ツリー外、
`git show HEAD:<path>`で取り出した修正前ソースを単発`swift`実行で動かす
もの。`git stash`/`git reset --hard`は使っていない) でハング/無限ループを
実際に確認してから**着手した。

### F11 (MEDIUM)・F6 (MEDIUM): `HTMLTextExtractor`の二次時間バックトラック
/再走査

**所見**: `packages/OtegamiKit/Sources/OtegamiCore/HTMLTextExtractor.swift`
の`plainText(fromHTML:)`が`<(script|style)\b[^>]*>.*?</\1>`/`<[^>]+>`という
バックトラックする正規表現を連鎖させており、`<script`を大量に含む(閉じ
ない)HTMLで入力長の二次オーダーの仕事量になっていた。同ファイルの
`decodeEntities(_:)`も、`&`ごとに`firstIndex(of: ";")`で残り全体を再走査
し辞書引き用に全長の部分文字列コピーを作るため、独立に二次時間だった。
どちらも`SyncEngine.BodyFetcher.resolvePlainText`が長さ上限なしで呼び、
`MessageView.isHTMLMessage`もSwiftUIの計算プロパティから同じ関数を呼ぶ
ため、攻撃者が送るメール1通 (ゼロ操作) で同期アクターとメインスレッドが
数分〜数時間ハングし得た。再現確認: 修正前コードに対し、未閉じ
`<script`を約1MB連結した入力と、`&`を30万個+末尾に`;`1個の入力を与えた
ところ、どちらも25秒のタイムアウトを超えても終わらなかった。

**修正**: 正規表現チェーンを、単一パス・線形時間の手書きスキャナに置換。
タグ/`<script>`・`<style>`の終端`>`探索は、次の`<`が現れた時点でも打ち切る
ようにした (実際のHTML/SVGはタグの中に`<`をネストしないため) — これが
無くすと、未閉じタグへの失敗した探索がその都度次の`<`から仕事量を丸ごと
やり直し、別経路で同じ二次時間が再発する。`decodeEntities`は実体名の
先読みを32文字に上限化 (実際のHTML実体は高々数文字) し、`&`ごとの走査と
コピーをO(1)に抑えた。加えて、この関数はスニペット/検索フォールバック
専用という用途に合わせ、入力全体を512KB (`maxInputLength`) で先頭打ち切り
する防御縦深も追加した。修正後、同じ悪性入力は0.05〜0.23秒で完了する
(計測値は下記テスト参照)。既存の`HTMLTextExtractorTests`(タグ除去・
block境界・`<br>`・script/style除去・実体デコード・テーブルレイアウト
実機eml)はすべて挙動不変を確認。

### F7 (MEDIUM): BIMI SVGパスパーサの無限ループ

**所見**: `packages/OtegamiKit/Sources/BIMI/BIMIPathDataParser.swift`の
`parse(_:transform:)`で、`Z`/`z` (closepath) だけがスキャナ入力を消費し
ない。`Z`の直後が区切りでも英字でもない場合 (`d="M0 0Z0"`)、暗黙のコマンド
反復経路で`Z`が再選択され続け、`while true`が二度と終わらず`commands`が
無制限に成長した。BIMIロゴSVGは送信者ドメインのDNS TXTレコード
(`default._bimi`)から取得され`CompanyLogoAvatarResolver`アクター内で
同期的にパースされるため、悪意/誤設定のBIMIレコード1つでゼロ操作・
リモート・持続的 (その送信者の行を描画するたび再現) なDoSになっていた。
再現確認: 修正前コードに`"M0 0Z0"`を渡したところ10秒のタイムアウトを
超えても終わらなかった (真の無限ループ)。

**修正**: `Z`/`z`の暗黙反復を拒否 (spec上closepathは引数を取らないため、
`Z`直後の非区切り・非英字トークンは不正としてfail closed)。加えて縦深
防御として、各反復でスキャナのインデックスが必ず前進していることを
アサートするガードと、`commands.count`の上限 (200,000) を追加。修正後は
同じ入力が即座に`nil`を返す。既存の`BIMISVGParserTests`のパスパーサ関連
ケース (暗黙反復・相対コマンド・パック数値・実PayPalロゴの縮退`S`セグ
メントなど) は挙動不変。

### F12 (MEDIUM): BIMI SVGタグトークナイズ正規表現の破滅的バックトラック

**所見**: `packages/OtegamiKit/Sources/BIMI/BIMISVGParser.swift`の
`tokenize(_:)`が使う正規表現の末尾`\s+`/`[^<>]*?`/`\s*`/`\s*`が互いに
同じ空白の並びに曖昧マッチできるため、未閉じタグ+長い空白列
(`BIMISVGSafety`の64KB上限の範囲内で十分再現可能) で分解の組合せが
爆発した。F7と同じ同期経路にあるため、同じくゼロ操作のリモートDoS。
再現確認: 修正前コードに`<svg viewBox="0 0 8 8"/><g` + スペース5万個
を渡したところ15秒のタイムアウトを超えても終わらなかった。

**修正**: 正規表現をやめ、線形の手書きタグスキャナに置換。各タグの終端
`>`探索はF11と同じ理由で次の`<`でも打ち切る。書き換えの過程で1件
リグレッションを検出・修正: 元の正規表現は`<?xml ...?>`のような
「`<`の後が英字でない=タグとして認識できない」構造にマッチせず単に
無視していた(`matches(in:)`が非マッチ箇所を素通りする挙動)が、この
リグレッション自体は`docコメントの「fail closed」という意図`とは
実は矛盾していた形。実PayPal BIMIロゴのフィクスチャ(`<?xml
version="1.0" encoding="UTF-8"?>`前置き)がこの寛容さに依存していると
標準ドライバでの機能テストで判明したため、手書きスキャナでも「整形
された`<...>`だが英字名を持たない構造はトークンなしでスキップ、本当に
未終端 (`>`より先に`<`が来る/入力終端まで`>`が無い)場合のみ全体を
`nil`で失敗」という原挙動を明示的に再現した。修正後は同じ入力が
数ミリ秒で`nil`を返す。既存の`BIMISVGParserTests`(実PayPalロゴ2種、
`<title>`スキップ、ネストしたグループのtransform合成、grad/未対応
要素の拒否など) は全件挙動不変を確認。

**追加で発見・修正した関連の1件 (レポートには無い、独自発見)**:
同ファイルの`parseAttributes(_:)`も、正規表現の貪欲な識別子
(`[A-Za-z_:][\w:.-]*`)の直後に必須の`=`が来る形だったため、`=`が
一切現れない長い文字列に対して`matches(in:)`が「非マッチだった識別子を
1文字ずつ短くしながら後続の全開始位置で再試行する」形の二次時間に
なっていた (F12ほどの破滅的指数爆発ではないが、実際に攻撃者到達可能な
二次コスト — 1タグの属性文字列は64KB上限のほぼ全体になり得る)。標準
ドライバでの検証で、`=`を含まない50万バイトの繰り返し文字1本が8秒の
タイムアウトを超えて未完了であることを確認した。F12の書き換え作業中に
同じファイル内で見つけたため、スコープ (このタスクは4ファイル限定だが
`parseAttributes`は`BIMISVGParser.swift`内) の範囲内と判断しあわせて
修正: これも線形の手書きスキャナに置換 (バックトラックなしで1パス、
未終端クォートは「そこで打ち切る」形にして同種の二次コストが別経路で
再発しないようにした)。既存の呼び出し元 (`tokenize`経由)・全SVG
フィクスチャは挙動不変を確認。

### テスト

- `packages/OtegamiKit/Tests/OtegamiCoreTests/HTMLTextExtractorTests.swift`
  に3件追加: 未閉じ`<script`約1MB連結、`&`30万個+`;`1個、内部上限
  (512KB) を大きく超える入力 (約14MB) のいずれも10秒以内に完了する
  ことを確認 (実測は0.05〜0.23秒)。
- `packages/OtegamiKit/Tests/BIMITests/BIMISVGParserTests.swift`に5件
  追加: `"M0 0Z0"`が5秒以内に`nil`を返すこと、未終端タグ+スペース5万個
  が5秒以内に`nil`を返すこと、`<?xml ...?>`前置きが致命的にならず
  `<svg>`ルートまで到達できること、`=`を含まない50万バイトが5秒以内に
  `parseAttributes`を完了させること、`parseAttributes`が二重/単一
  クォート属性を従来どおり正しく読めること。
- `swift test`(`packages/OtegamiKit`を直接) で全スイート green。
  1回だけ`MailCoreMessageBuilderTests`の日本語RFC822往復テストが
  落ちたが単体再実行/2回目のフル実行では通過 — Task #167と同じ既知
  flake (このタスクが一切触れていないファイル由来) で無関係と判断。
- `make mac`/`make ios`ともに`** BUILD SUCCEEDED **`
  (初回`make mac`は`MessageDetailFooterToolbar.swift`の
  `switch must be exhaustive`で失敗したが、これは翻訳まわりの並行
  エージェントの作業がちょうど`main`へ着地する境目に当たった一過性の
  もの — 該当ファイルはこのタスクが一切触れておらず、再実行で解消した
  ことをコミット履歴 (`9e28ea5`) と合わせて確認)。

### 配信

`ef97d31` (`parseAttributes`修正込みの最終コミット) をpush後、OTA配信
してmanifest.plistの`bundle-version`が`ef97d31`と一致することを確認
した。

なお、コミット作業中に共有ツリー特有の事故が1件発生し即座に復旧した
記録: `git add <このタスクの3ファイル>`は正しく打ったが、直後の
`git commit`(パス指定なし) がその時点でインデックスに残っていた
**SEC-D (並行エージェント) の`server/otegami-relay/`配下の未コミット
ステージ**を巻き込み、21ファイルのコミットになってしまった。push前に
`git show --stat`で気づき、`git reset --soft HEAD~1`(作業ツリー・
インデックスは変更しない安全なやり直し) → `git restore --staged
server/otegami-relay/`等で自分の3ファイルだけ残す → 再コミット、で
復旧。SEC-Dのファイルは全てpush前の「変更あり・未ステージ」の元の状態
に戻っており、内容の破壊・巻き込みpushは無い (`git status`で確認済み)。
教訓として、共有ツリーでは自分が`git add`した直後でも**他人が同じ瞬間
にステージしたものが残っている可能性がある**ため、`git commit`前には
必ず`git diff --cached --stat`(または`git show --stat`後の確認) を
挟むべき — 今回は結果的にそれで検知できたが、コミットしてから気づく
のではなく、コミット**前**に確認する方が安全。

### 未対応として残した点 (今回のスコープ外)

- `docs/qa-findings.md`の採番衝突 (上記注記) の整理そのもの — 採番の
  正式な訂正は本タスクの範囲外。
- `RichTextHTMLCoder.swift`にも同名の`parseAttributes`(別実装) が
  存在するが、今回のレポート・このタスクのスコープ (4ファイル限定) の
  対象外のため未調査。

## 実機クラッシュ: macOS で Gmail 認証すると落ちる実バグの原因と修正 (v1.2.0-beta4)

### 症状

ユーザーからの実機フィードバック: macOS 版で Gmail 認証 (再認証) を
行うとアプリが落ちる。クラッシュログは `EXC_BREAKPOINT` (`SIGTRAP`) で、
スタックは `ASWebAuthenticationSessionRunner.run` の completion handler
クロージャ内から `_dispatch_assert_queue_fail` /
`swift_task_isCurrentExecutorWithFlagsImpl` に至るもの
(`com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent`という
XPC応答キュー上のスレッドで発生)。

### 原因

`ASWebAuthenticationSession`の completion handler は**メインスレッドで
呼ばれる保証がない** — macOSでは`SafariLaunchAgent`のXPC応答キュー上で
同期的に呼ばれることが実機で確認できた (iOSでは主にメインで配送される
ため、この不整合が今まで露出していなかっただけ)。

`GoogleOAuth`/`MicrosoftOAuth`双方の`ASWebAuthenticationSessionRunner`
は、このcompletion handlerクロージャを`@MainActor`なメソッド
(`run(authorizationURL:callbackURLScheme:)`) の内部に、明示的な
`@Sendable`/isolation注釈なしで書いていた。渡す先の型
(`@escaping (URL?, Error?) -> Void`、ObjC由来のブロック型でactor注釈
なし) 自体はどのスレッドからでも呼ばれうるにもかかわらず、Swift 6の
クロージャ隔離推論 (SE-0420) はこのクロージャを「囲むメソッドと同じ
`@MainActor`隔離」と推論し、**クロージャの入り口に動的な隔離チェックを
挿入していた**。macOSで実際にメインスレッド外から呼ばれた瞬間、この
チェック自体がトラップした — クロージャ本体が`activeSession`(main-actor
隔離のプロパティ) に触れる**前**の、入り口の時点で落ちていた。

調査の過程で「`activeSession = nil`の代入だけを`Task { @MainActor in
... }`で明示的にホップさせる」という一次修正を先に試したが、実機で
再現したところ**同じ箇所で同じ形のクラッシュが再発した** — クロージャ
入り口の隔離チェックはボディの中身と無関係に挿入されるため、ボディ内の
特定行を直しても効果がないという教訓が得られた。

### 修正

`packages/OtegamiKit/Sources/GoogleOAuth/ASWebAuthenticationSessionRunner.swift`
と、そのミラーコピーである
`packages/OtegamiKit/Sources/MicrosoftOAuth/ASWebAuthenticationSessionRunner.swift`
の両方 (片方だけ直すとOutlookで同じクラッシュが残るため) を修正:

- completion handlerクロージャを`@Sendable [weak self] callbackURL,
  error in ...`と明示的に`@Sendable`化。クロージャがコンパイラに
  「本当にどのスレッドから呼ばれても構わない (非隔離)」と伝わるため、
  入り口の動的隔離チェック自体が挿入されなくなる。
- `activeSession = nil`はメインアクター隔離状態への書き込みなので、
  `if let self { Task { @MainActor in self.activeSession = nil } }`で
  引き続き明示的にホップする (`MainActor.assumeIsolated`は使わない —
  実際に非メインの場合があるため、使うと同じ嘘を別の場所で繰り返す
  だけになる)。
- 継続 (`CheckedContinuation`) の二重resumeを防ぐため、
  `OtegamiTranslationApple.ResumeBox`と同じ思想だが`@MainActor`では
  ない (この完了ハンドラがメインアクター外から呼ばれうるため)
  ロックベースの`ContinuationResumeBox`を各ファイルに追加した。

### 検証

- `make test`/`make mac`/`make ios`いずれも green
  (`MailTransportMailCoreTests`のmailcore2並列実行flakeが1回だけ
  発生したが、このタスクが一切触れていないファイル由来の既知不調
  ―`--no-parallel`で全78件greenと`make test`単独再実行でのgreenの
  両方で確認 ― であり無関係)。
- **修正前のビルドで実機同等のクラッシュを実際に再現できた**: ローカル
  debugビルドの macOS 版を起動し、既存のGmailアカウント (再認証待ち
  状態) に対して「再認証」ボタンをアクセシビリティ経由でクリック →
  `ASWebAuthenticationSession`がシステムの既定ブラウザ経由 (Ephemeral
  セッションのため Incognitoウインドウ) でGoogleのサインイン画面を
  提示 → そのウインドウを閉じてキャンセル操作を行った瞬間、修正前の
  ビルドではアプリプロセスが実際に落ち、`~/Library/Logs/
  DiagnosticReports/`に上記と同一のスタック (`closure #1 in closure #1
  in ASWebAuthenticationSessionRunner.run` →
  `_dispatch_assert_queue_fail`) を持つクラッシュレポートが生成される
  ことを確認した。
- **修正後は同じ手順 (再認証ボタン→キャンセル) で確認したところクラッ
  シュせず**、アプリはEdit Account画面に戻って通常どおり動作を継続
  した。同じ操作の直後に新しいクラッシュレポートが生成されないことも
  確認済み。
- クラッシュログ自体 (Crash Reporter Key・Team ID・デバイス識別子等の
  実機固有情報を含む) はコミット・ドキュメントいずれにも含めていない。

### 配信

`382802b`をpush後、OTA配信してmanifest.plistの`bundle-version`が
`382802b`と一致することを確認した。

## Task #183: iCloud Archive の同期が毎回 `UNIQUE constraint failed:
message.mailboxId, message.uid` で失敗し続けるバグ

### 報告

実機報告: iCloud アカウントの Archive メールボックスの同期が毎回
`UNIQUE constraint failed: message.mailboxId, message.uid` で失敗し、
自然回復しない (再起動・pull-to-refresh を挟んでも同じ箇所で失敗し
続ける)。

### 原因

Task #120 の「仮配置 (pending relocation)」機構 — archive/unarchive/
junk/delete が移動先メールボックスを既に知っていれば、対象の
`message` 行を削除する代わりに同じ行 `id` のまま `mailboxId`/`uid`
(仮 UID は `uid <= 0`) だけ書き換えて即座に移動先へ"仮配置"し、その
メールボックスの次回同期が実エンベロープを取得した時点で
`AccountSyncer.reconcilePendingRelocation` が仮配置行の `uid` を実
UID に付け替えて確定する — の**書き込み先チェック漏れ**が根本原因
だった。

`reconcilePendingRelocation`は、`messageId` (Message-ID ヘッダ) が
一致する仮配置行 (`uid <= 0`) を1件`fetchOne`で探し、その`uid`を
無条件に`envelope.uid` (実UID) へ書き換えていた。しかし、書き込み
先の`(mailboxId, envelope.uid)`が**既に別の行で埋まっている**ケース
を一切確認していなかった:

- 同じ物理メッセージの**既に本物として同期済みの行**(別 id) が、
  同じ `mailboxId` の同じ実 UID に既に存在するケース (例: この端末
  自身の Archive フル/初回同期が独立に先に取り込んでいた、または
  ローカルの古いキャッシュ経由でユーザーが再度アーカイブ操作をした
  ことで仮配置行が新たに作られた) — この場合、仮配置行の`uid`書き
  換えが`(mailboxId, uid)`の一意制約に**必ず**違反する。
- 一度クラッシュが起きると、仮配置行を掃除する経路が存在しない
  ため、**次の同期でも全く同じ行の組み合わせに対して同じ書き換えを
  試み、同じ場所で毎回失敗し続ける** — 自然回復しない実機報告の
  「自然回復しない」の直接の原因。

`SyncEngine.MessageRemoval.undo` (元に戻す) 側にも同種のガード漏れが
あった: 仮配置された行がまだ存在する分岐 (`undo`のdoc commentが言う
「Still exists (relocated)」) は、スナップショット時点の元の
`(mailboxId, uid)`を無条件に書き戻していた — その元のスロットが
仮配置されている間に (最も現実的には該当メールボックスの
`uidValidity`リセット後のフル再同期で) 別の本物のメッセージに
再利用されていた場合、同じ一意制約違反を起こしうる。

### 修正

`packages/OtegamiKit/Sources/SyncEngine/MessageRelocationConflict.swift`
に、この2箇所が共有する衝突解決ポリシーを1箇所に切り出した
(`AccountDuplicateMerger.mergeCollidingMailbox`
(`packages/OtegamiKit/Sources/OtegamiStore/AccountDuplicateMerger.swift:235-290`)
が「同じ物理メッセージを表す2行」という同種の問題に対して既に確立
していたポリシーと同じ思想 — 生き残る側(`survivor`)は書き込み先に
既にいた行、移動しようとした側(`mover`)のローカル専用状態
(`isPinnedLocal`・フラグ・`detectedLanguage`) を`survivor`側へ
マージしてから`mover`を破棄する。`mover`自身のキャッシュ済み本文/
添付/翻訳は移行せず単純に破棄する — 意図的な受容範囲であり、
`mergeCollidingMailbox`が既に同じトレードオフを受け入れているのに
倣った):

1. **`AccountSyncer.reconcilePendingRelocation`**
   (`AccountSyncer.swift`): `fetchOne`を`fetchAll`に変え、一致する
   仮配置行を**全件**取得するように変更。書き込み先
   `(mailboxId, envelope.uid)`に既に本物の行が存在する場合は、
   マッチした仮配置行全てをその行へマージ・破棄する (自己回復 —
   既にバグに遭遇していた端末の残留仮配置行もこの経路で掃除される)。
   存在しない場合 (通常の非破損ケース) は、マッチした仮配置行のうち
   最も`updatedAt`が新しいものを勝者として実UIDへ昇格させ、残りは
   勝者へマージ・破棄する (仮配置行が複数ある場合の回復)。
2. **`MessageRemoval.undo`**
   (`MessageRemoval.swift:307`以降、ガード自体は`317`行目付近):
   行がまだ存在する分岐で、元の`(mailboxId, uid)`へ書き戻す前に
   その組が既に**別の行**に占有されていないか確認するようになった。
   占有されていれば`MessageRelocationConflict`の同じポリシーで
   マージ・破棄する。

### 検証

- 新規回帰テスト3本 (指示どおり最低限のシナリオ):
  - `MessageRelocationReconciliationTests
    .pendingRelocationConflictingWithAlreadyRealRowMergesWithoutDuplicating`
    — 移動先に同じ Message-ID の実行が既にある状態で
    `performIncrementalSync`しても衝突せず、行が重複せず、仮配置行の
    ローカル専用状態 (pin) が生存側へマージされることを確認。
  - `MessageRelocationReconciliationTests
    .twoLeftoverPendingRelocationRowsCollapseOnNextSync` —
    同一メッセージに対する仮配置行が2行残った (=修正前に一度バグに
    遭遇した端末を模した) 状態から、次の同期1回で1行に収束すること
    を確認 (自己回復の直接の回帰テスト)。
  - `MessageRemovalTests.undoCollisionWithReoccupiedSlotMergesInsteadOfCrashing`
    — `undo`側: 元の`(mailboxId, uid)`スロットが別メッセージに再利用
    された状態からの`undo`がクラッシュせず、占有していた行が生存し、
    ピン状態がマージされ、空になった元スレッドが片付くことを確認。
  - 3本とも、修正後のコードを書いた**後に**、修正した2ファイル
    (`AccountSyncer.swift`/`MessageRemoval.swift`、および新規
    `MessageRelocationConflict.swift`) だけを`git checkout`/退避で
    一時的に修正前の状態へ戻し、テストファイルはそのままで再実行して
    赤くなることを確認 (指示の「可能なら…確認してから直す」を、実装後
    に修正前へ戻す形で満たした)。結果は2種類に分かれた:
    - `undo`側 (`undoCollisionWithReoccupiedSlotMergesInsteadOfCrashing`)
      は報告と文字どおり同じ`SQLite error 19: UNIQUE constraint
      failed: message.mailboxId, message.uid`を実際に投げて失敗した。
    - 同期側の2本 (`AccountSyncer.reconcilePendingRelocation`経由) は
      同じDB例外を内部で起こしてはいるものの、`AccountSyncer`の
      `SyncRetryPolicy`が transient エラーとして数回リトライしてから
      諦める既存の仕組みに飲み込まれ、テスト自身は「クラッシュ」では
      なく「同期が (数十秒かけて) 失敗し、行が重複したまま/仮配置の
      ままになる」という形の expectation 失敗で赤くなった —
      「毎回失敗し、自然回復しない」という実機報告の文言とも整合する
      挙動。修正を戻して確認後、同じ3ファイルを直後にfixed版へ復元し、
      17件全てgreenに戻ったことを再確認済み。
- `swift test --package-path packages/OtegamiKit --filter
  "MessageRelocationReconciliationTests|MessageRemovalTests"`
  green (17 tests)。
- `make test` (packages/OtegamiKit フルスイート) green。
  `MailTransportMailCoreTests`の`MailCoreMessageBuilder`スイートで
  並列実行時のみ再現する既知の flake (Task #168 (SEC-C) の「検証」
  節に既に記録済みの同じ不調) を1回観測したが、このタスクが一切
  触れていないファイル (`packages/MailTransport/`) 由来であり、
  同テストを単独 (`--filter MessageBuilderTests`) で複数回実行して
  green・クリーンな別クローンでの`make test`フル実行でも green を
  それぞれ確認済みで無関係。
- 実機シミュレータでの確認は未実施 (方針どおり)。`PENDING.md`に
  未検証事項を追記した。

## Task #187: Yahoo! JAPAN の断続的な認証失敗 — 自己誘発ロックの疑いと再試行間隔の是正

**実測済みの事実 (推測ではない)**: リレー側の切り分け用ログ (commit
`5656c7b`、`authFailureServerResponse`) が、Yahoo Japan
(`imap.mail.yahoo.co.jp`) アカウントの LOGIN 失敗時にサーバーの実際の
タグ付き応答を記録した:

```
A1 NO [AUTHENTICATIONFAILED] Incorrect username or password.
```

`[LIMIT]`/`[UNAVAILABLE]`のようなレート制限を示す応答**ではない**。
しかし同じ保存済み資格情報で、同日の少し前には接続に成功している —
値そのものは正しい。Yahoo! JAPAN の公式ヘルプは「認証エラーが連続すると
アカウントが一時的にロックされることがある」という記述はあるが、
ロック期間は明記していない
(<https://note.chiilabo.jp/2026-04/yahoo-japan-imap-external-access-change/>
を WebFetch で確認済み — 具体的な分数の記載は無かった)。「同時接続数の
超過」という当初仮説は、この応答内容 (レート制限特有のコードではない)
から否定される。

**洗い出した再試行経路**:

1. **リレー (`server/otegami-relay-go/internal/watcher/pool.go`)
   `runWatchLoop`/`connectAndWatch`**: 認証失敗を`2秒`から始めて倍々に
   (`4s, 8s, ...`、上限`5分`) 再試行し、`maxConsecutiveAuthFailures`
   (3回) で完全停止 (`status = 'stopped'`、以後はユーザーの手動再登録
   まで復活しない)。1アカウントにつき watch が複数 (Task #175 以降、
   push 対象アカウントごとに1つ) 同時に走るため、実質「12秒間に3回 ×
   watch数」の再試行が同時多発していた。
2. **アプリ本体 (`packages/OtegamiKit/Sources/SyncEngine/AccountSyncer
   .swift`) `runIdleLoop`**: `.authenticationFailed`を含むあらゆる
   エラーを一律`5秒`から倍々 (上限`5分`) で再接続し続ける — これ自体は
   フォアグラウンド中ずっと動く設計だが、**`OtegamiApp
   .handleScenePhaseChange`の`.active`ケース (フォアグラウンド復帰の
   たび) が`startIdleLoops(for:)`経由でこのループを毎回`stopIdleLoop()`
   → 新しい`Task`で再起動しており、ローカル変数`backoffSeconds`が
   フォアグラウンド復帰のたびに`5秒`へリセットされていた** —
   「フォアグラウンド復帰のたびに即再試行する経路」はここ。
3. **`AccountSyncer.connectWithRetry`/`syncMailboxWithRetry`
   (Task #69の`SyncRetryPolicy`)**: `.authentication`クラスの失敗は
   そもそも**一切リトライしない** (即記録して`throw`) — 1回の
   `performIncrementalSync`/`performInitialSync`呼び出し内では問題
   ない。フォアグラウンド復帰のたびに`syncAllAccountsOnce()`が1回だけ
   これを呼ぶのも「復帰ごとに1回」であって連続再試行ではないため、
   ここは対象外と判断 (変更なし)。
4. **`OpQueueProcessor`(op replay)**: `.authenticationFailed`は
   `isConnectionLevel`として replay バッチ全体を中断し、`nextRetryAt`
   をDBへ永続化した`backoffBase=30秒`〜`backoffCap=30分`のバックオフで
   次回を待つ — これは元々1と2の問題を持たない設計だった (既存の
   `30分`という値が、今回選んだ間隔の裏付けの一つにもなった)。

**対策 (すべて`git log`の Task #187 コミット参照)**:

- **リレー**: 認証失敗が`WatchRecord.LastConnectedAt != nil`
  (=この watch の資格情報が過去に一度でも認証成功したことがある) の
  場合、初回の再試行から`AuthFailureRetryInterval`
  (デフォルト**30分**、失敗のたびに倍々、上限`AuthFailureRetryCap`
  (**6時間**)) を空け、`maxConsecutiveAuthFailures`に関係なく**恒久停止
  しない** (`shouldGiveUpAfterAuthFailure`、`pool.go`)。一度も成功して
  いない watch (新規登録直後の設定ミス等) は従来どおり (2秒からの
  バックオフ、3回で停止)。
- **アプリ**: `AccountSyncer`に`lastAuthFailureAt`(インスタンス寿命、
  `startIdleLoop`の再起動をまたいで生存) を追加し、`runIdleLoop`が
  ループの先頭で`authFailureCooldownRemaining`(30分、固定) を確認して
  経過するまで LOGIN 自体を試みないようにした。フォアグラウンド復帰で
  ループが再起動されても、この状態は`AccountSyncer`インスタンス側に
  残るため再試行されない。
- **30分という値の根拠**: Yahoo! JAPAN 公式のロック期間が非公開のため、
  (a) 一般的な Web メールの「連続認証失敗による一時ロック」が
  「数十分」オーダーで語られることが多い点、(b) このリポジトリ自身の
  既存実装 (`OpQueueProcessor.backoffCap` = 30分) が同種の問題に対して
  既に採用している値であること、の2点から「数十分より確実に長く、
  かつ即日中に回復する」値として30分を採用 (根拠はコード中のコメント
  にも記載)。
- **文言**: `MailTransportErrorMessage.swift`の
  `.authenticationFailed`分岐に`hasSucceededBefore`引数を追加。
  `AccountEditView`(既存アカウントの「接続テスト」再実行) は、
  そのアカウントに`mailbox`行が1件でも存在するか (=過去に一度でも
  LOGIN+`listMailboxes()`に成功した証拠) を見て、成功実績があれば
  「ユーザー名またはパスワードを確認してください」ではなく「この資格情報は
  過去に接続に成功しているため、一時的な制限の可能性がある」旨に文言を
  差し替える。`AccountSetupView`/`ICloudAccountSetupView`(新規設定時、
  実績があり得ない) は常に`false`のまま、従来どおり。ja/en とも
  `Localizable.xcstrings`に追加、`make check-localization` green。

**ユニットテスト**:

- Go: `TestShouldGiveUpAfterAuthFailure` (純粋な成否判定テーブルテスト)、
  `TestAuthFailureAfterPriorSuccessNeverStopsAndUsesLongBackoff`
  (`store.MarkWatchConnected`で成功実績を模擬 → 認証拒否のまま
  `WatchStatusStopped`に到達しないこと・`LastConnectedAt`が残ること
  を確認)。`server/otegami-relay-go`は`go build ./...`/`go vet ./...`/
  `go test ./...`すべて green (133 tests)。
- Swift: `AccountSyncerTests`に`authFailureCooldownRemaining`の純粋
  ロジックテスト4本 (未記録/直後/経過中/経過後) と、
  `idleLoopDoesNotImmediatelyRetryAfterAuthFailure`
  (`FakeIMAPSession`の`failConnection`で認証失敗を模擬し、2秒の観測窓で
  `connect()`が2回目以降呼ばれないことを確認 — 修正前ならこの窓の間に
  複数回再試行していたはずの経路の直接的な回帰テスト)。

**検証**: `make test`/`make mac`/`make ios`/`make check-localization`
すべて green。実 Yahoo! JAPAN アカウントでの実機確認 (ロック解除待ちの
30分間隔が実際に有効か、文言が正しく出し分かるか) は`PENDING.md`に
追記した (実機作業のため)。
