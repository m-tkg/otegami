# 動作検証 (verify)

人間の手を借りず、シミュレータ/実ビルドに対する自動検証で各マイルストーンの
チェックポイントを確認する方針 (計画書「テスト戦略」参照)。ノウハウは
`.claude/skills/verify/SKILL.md` にも蓄積している。

## 単体テスト

```sh
make test
```

`packages/OtegamiKit` の `swift test`。`OtegamiCoreTests` / `OtegamiStoreTests`
(in-memory GRDB) / `SyncEngineTests` (`FakeIMAPSession` によるシナリオテスト) は
常時実行。`MailTransportMailCoreTests` は `OTEGAMI_TEST_IMAP_HOST` 環境変数が
設定されている場合のみ実行される opt-in の統合テスト。

## iOS シミュレータ検証 (M1)

```sh
scripts/verify-ios-m1.sh
```

実施内容:

1. `make mailstack-up` + `make mailstack-seed` で dev mailstack を用意。
2. 直前のインストールを `simctl uninstall` で削除し、ローカル DB をまっさらにする。
3. `xcodebuild build-for-testing` でアプリ + `OtegamiUITests` をビルド。
4. `OtegamiUITests` (XCUITest) を実行: アカウント追加フォームに Dovecot
   (`localhost:1143`, 平文, `test1@otegami.test`/`test1234`) を入力 →
   「接続テスト」成功を確認 → 保存 → 初期同期後、seed メール4通の日本語件名が
   INBOX 一覧に表示されることを `XCTAssert` で確認。
5. アプリを再起動してオンライン状態のスクリーンショットを撮影。
6. `make mailstack-down` でメールサーバーを止め、アプリを再起動 (オフライン)。
   一覧がローカル DB からそのまま表示され続けることをスクリーンショットで確認。
7. `make mailstack-up` でメールスタックを復元。

スクリーンショットは `SCREENSHOT_DIR` (既定 `/tmp/otegami-verify/`) に
`01-online-inbox.png` / `02-offline-inbox.png` として出力される。最終判定は
人間ではなく、この画像を読み取れる Claude 自身が行う想定 (計画書参照)。

### UI 操作の自動化について

`simctl` だけではテキスト入力やアクセシビリティ ID によるタップ操作ができない
(スクリーンショット/インストール/起動などのライフサイクル操作限定)。そのため
全 UI 要素に `accessibilityIdentifier` を付与し (`Sources/Features/**`
参照)、`apps/Otegami/UITests/` の XCUITest (`OtegamiUITests` スキームターゲット)
で操作する。詳細・ハマりどころは `.claude/skills/verify/SKILL.md` を参照。

## iOS シミュレータ検証 (M2)

```sh
scripts/verify-ios-m2.sh
```

実施内容:

1. `make mailstack-up` + `make mailstack-seed` で dev mailstack を用意
   (`seed.sh` は冪等化済み: 投入前に INBOX を空にするので、繰り返し実行しても
   重複しない)。
2. 直前のインストールを `simctl uninstall` で削除。
3. `xcodebuild build-for-testing` でアプリ + `OtegamiUITests` をビルド。
4. `OtegamiM2VerificationUITests` (XCUITest) を実行: M1 のヘルパー
   (`addDovecotTest1Account`, `UITests/DovecotAccountUITestHelpers.swift`)
   でアカウントを追加 → `restartAppToRecoverTouchDelivery` でアプリを
   再起動 (この simulator/toolchain 固有の既知の不具合の回避策。
   `.claude/skills/verify/SKILL.md` 参照) → HTML 専用 (プレーンテキスト
   パート無し) の日本語メール (`07-html-only-japanese.eml`) を開き、本文の
   日本語テキストが表示されることを確認 → 外部画像入り HTML メール
   (`06-html-external-image.eml`) を開き、「画像を表示」バナーが表示され、
   タップで消えることを確認。
5. オンライン状態のスクリーンショットを撮影。
6. `make mailstack-down` でメールサーバーを止める。
7. `OtegamiM2OfflineVerificationUITests` を実行: アプリを再起動し、
   直前に開いていたメッセージ (`RootView` の "lastOpenedMessage"
   `@AppStorage` 復元) の本文が、タップ操作なしにローカル DB だけから
   再表示されることを確認。
8. オフライン状態のスクリーンショットを撮影。
9. `make mailstack-up` でメールスタックを復元。

スクリーンショットは `SCREENSHOT_DIR` (既定 `/tmp/otegami-verify/`) に
`m2-01-online-message.png` / `m2-02-offline-message.png` として出力される。

### この環境固有の XCUITest タップ問題について

M2 の実装時、現在の開発機の toolchain (Xcode-beta.app + iOS 27.0 beta
シミュレータ) 固有と見られる複数の自動化バグに遭遇した (アプリのバグでは
ない — 標準的な SwiftUI コードで、安定版シミュレータや実機では発生しない
はずのもの)。具体的には account-setup シートの dismiss 後は全要素の
タップが `{-1, -1}` という無効な座標になる、`List(selection:)` がタップで
更新されない、`NavigationSplitView` がコンパクト幅で content→detail に
自動遷移しない、identifier ベースの要素検索が画面に見えている要素を
見つけられない、など。回避策と診断手法の詳細は
`.claude/skills/verify/SKILL.md` の「M2: この simulator/toolchain の
タップ配信バグ」節に記録した。

### メッセージ詳細画面の自動判定について

HTML メッセージは `WKWebView` (`messageDetail.htmlWebView`) で描画される。
WebKit のコンテンツはアクセシビリティツリー上に静的テキストとして
(段落ごと、または本文全体としてグルーピングされて) 現れるため、
`OtegamiM2VerificationUITests` は完全一致ではなく `label CONTAINS` の
`NSPredicate` で `app.staticTexts` を横断検索している。プレーンテキストの
メール (`messageDetail.plainTextBody`, SwiftUI `Text`) にも同じ判定方式を
使っているので、本文がどちらの表示経路を通っても同じアサーションで検証できる。

## macOS ビルド確認

```sh
make mac
```

M1 では macOS 側の UI 検証は必須ではない (計画書参照) が、ビルドが壊れていない
ことは毎回確認する。M2 の HTML 表示 (`HTMLMessageView`) も iOS/macOS 両方の
`#if os(...)` 分岐を実装しているが、自動 UI 検証は iOS シミュレータのみで
macOS 側はビルド確認 (`make mac`) までとしている (計画書のテスト戦略に準拠)。

## 統合テスト (opt-in, dev/mailstack 対象)

```sh
make mailstack-up
OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter MailTransportMailCoreTests
make mailstack-down
```

`packages/OtegamiKit` の `MailTransportMailCoreTests` ターゲット
(`OTEGAMI_TEST_IMAP_HOST` 未設定時はスキップされ、`make test`/CI には影響しない)。
M1/M2 由来の `MailCoreIMAPSessionIntegrationTests` に加え、M3 では
`SyncEngineIntegrationTests` が `AccountSyncer.performIncrementalSync` を実
Dovecot に対して実行する。他クライアントの操作は `DoveadmHelper`
(`docker compose exec dovecot doveadm ...`) でシミュレートする: INBOX を
既知の1通に初期化 → 初期同期 → `doveadm flags add \Seen` でフラグ変更、
`doveadm save` で新着メールを投入 → `performIncrementalSync` がその両方を
拾うことを assert。テスト自身が INBOX を書き換えるため、終了時に
`DoveadmHelper.restoreStandardFixtures()` (`seed.sh` の再実行) で
`MailCoreIMAPSessionIntegrationTests` が前提とする標準 seed 状態に戻す
(実行順に依存しないことを確認済み)。

## iOS シミュレータ検証 (M3)

```sh
scripts/verify-ios-m3.sh
```

差分同期・フラグ同期・オフライン操作キュー・フォアグラウンド IDLE の
チェックポイントを、XCUITest 4 フェーズとホスト側 `doveadm` 操作を交互に
実行して確認する。XCUITest (iOS ターゲット) からは `Foundation.Process`
が使えないため、「他クライアントが何かした」側は必ずラッパースクリプト
(ホストの bash) から `doveadm`/`docker compose exec` で行う。

1. `OtegamiM3SetupUITests` — Dovecot アカウントを追加し、M1 と同じ
   ベースライン (seed 済み4通) が一覧に出ることを確認。
2. (ホスト) `doveadm save` で `08-m3-new-mail.eml`
   (「M3差分同期テスト」) を INBOX に投入 — 他クライアントの新着配信を模す。
3. `OtegamiM3NewMailUITests` — アプリを再起動し、新着件名が
   `waitForExistence(timeout: 30)` のポーリングで一覧に現れることを確認。
   **フォアグラウンド IDLE そのものではなく**、`RootView` の
   `scenePhase == .active` ハンドラが起動直後に必ず1回実行する
   opQueue replay + `performIncrementalSync` を経由させている
   (IDLE が push する先と全く同じコード)。理由: XCUITest は
   `xcodebuild test` の呼び出しごとに別プロセスなので、ホスト側の
   `doveadm` 呼び出しと同一 IMAP 接続を維持したままアプリを生かし続ける
   ことを前提にできない。起動トリガの同期で同じパスを確定的に検証する。
4. `OtegamiM3SwipeActionsUITests/testSwipeMarksMessageRead` (mailstack
   稼働中) — 座標ベースの press-and-drag ( `.swipeLeft()`/`.swipeRight()`
   ではなく、M2 の既知タップ不具合と同じ理由で明示座標を使用) で行のリーディ
   ングスワイプを行い、「既読にする」ボタンをタップ。
5. (ホスト) `doveadm fetch -u ... flags HEADER Subject "..."` を最大10秒
   ポーリングし、`\Seen` がサーバ側に反映されたことを assert (opQueue の
   即時 best-effort replay がネットワーク越しに完了するのを待つ)。
   `doveadm` の検索クエリは `HEADER`/`Subject`/値をシェル上で1つの
   文字列に結合してはいけない (`doveadm` 自身の引数パーサが
   `Unknown argument` で落ち、`grep` 側は単に「\Seen が見つからない」
   として何度もリトライし続けてしまう) — 必ず別々の引数として渡す。
6. (ホスト) `make mailstack-down` でオフラインを再現
   (シミュレータの機内モード切替は不可能なため)。
7. `OtegamiM3SwipeActionsUITests/testSwipeDeletesMessageOffline` —
   トレイリングスワイプで「削除」をタップ。ローカルの楽観的削除 (行が
   即座に消える) のみをこの時点でアサート — replay はまだ起きない。
8. (ホスト) `make mailstack-up` → アプリを再起動 (`scenePhase == .active`
   が opQueue replay を起動) → 数秒待機。
9. (ホスト) `doveadm mailbox status -u ... messages Trash` (`"Trash
   messages=N"` を出力) を最大15秒ポーリングし、`N >= 1` になっている
   ことで削除したメールが Trash に移動していることを assert。

スクリーンショットは `SCREENSHOT_DIR` (既定 `/tmp/otegami-verify/`) に
`m3-01-new-mail-synced.png` / `m3-02-swiped-read.png` /
`m3-03-offline-deleted.png` / `m3-04-replayed-to-trash.png` として出力
される。

### 既知の制約

- フォアグラウンド `IDLE` ループ自体 (サーバの push を待って即座に
  incrementalSync を起こす経路) は、XCUITest からは `Process` 制約により
  ライブ検証できない。`performIncrementalSync`/`OpQueueProcessor.replay`
  という同じコードパスを起動トリガで確定的に検証することで代替している。
  `AccountSyncer.startIdleLoop`/`MailCoreIMAPSession.idle` 自体は
  `SyncEngineTests`/`MailTransportMailCoreTests` の unit/integration
  テストではなく、目視 (`make mailstack-down` した状態で長時間起動した
  ままにし、その後 `doveadm save` → 数秒以内に一覧へ反映されるか) での
  確認が今後望ましい。
- dev/mailstack の Dovecot はデフォルト設定のまま (SPECIAL-USE で
  Trash/Sent/Drafts/Junk を自動的にアドバタイズする) ため、Trash
  role 解決に追加のサーバ設定は不要だった。実運用でこの
  SPECIAL-USE 情報を返さないサーバ (Trash という名前のメールボックス
  すら存在しない) に対しては `OpQueueProcessor` の delete
  op はいつまでも `mailboxNotFound` で保留され続ける — Trash
  自動作成やユーザーへのバナー表示は M4 以降の課題として残る。

## iOS シミュレータ検証 (M4)

```sh
scripts/verify-ios-m4.sh
```

スレッディング・複数アカウント・統合受信トレイのチェックポイントを、
M3 と同様 XCUITest 4 フェーズ + ホスト側 `doveadm` 操作で確認する。

1. `OtegamiM4SetupUITests` — test1 の Dovecot アカウントを追加し、
   `09/10/11-thread-b-*.eml` (References 付き test1↔test2 往復3通) が
   1 行に畳まれ件数バッジ「3」を表示すること、`12/13-subject-fallback-*.eml`
   (References/In-Reply-To 無し・件名 "Re:" 一致のみ) も 1 行に畳まれ
   件数バッジ「2」を表示すること (Threader の 2 経路 — References
   union-find と subject フォールバック — の両方を実機同期で確認) を
   assert する。件数バッジは `messageList.row.<threadId>.countBadge`
   識別子の `CONTAINS` ルックアップで探す (日付表示に数字が混ざるため、
   行ラベル全体への `label CONTAINS "3"` のような素朴な述語は誤検知
   しうる)。
2. `OtegamiM4ThreadDetailUITests` — 3 通スレッドを開き、
   `threadDetail.message.<id>.header` が 3 件存在すること、最新メッセージ
   (test2 からの2通目の返信) の本文だけが初期状態で展開されていること、
   最も古いメッセージの本文はまだ画面上に無いこと、そのヘッダーをタップ
   すると展開されて本文が現れることを確認する。
3. `OtegamiM4SwipeReadUITests` — 02/03 (References 付き2通スレッド)
   の行をリーディングスワイプし「既読にする」をタップ。スレッド一括
   既読化 (`MessageListView.toggleRead`) がスレッド内の**両方**の
   メッセージへ `OpQueue.enqueueSetFlags` することを、ホスト側の
   `doveadm fetch ... flags` を2つの件名それぞれについてポーリングし
   `\Seen` を確認することで検証する。
4. `OtegamiM4UnifiedInboxUITests` — test2 の Dovecot アカウントを追加し
   (`addDovecotTest2Account`)、既定選択の「すべての受信トレイ」に
   test1 のスレッドと test2 自身の受信メールが両方とも表示されることを
   確認する。

スクリーンショットは `SCREENSHOT_DIR` (既定 `/tmp/otegami-verify/`) に
`m4-01-unified-inbox-threads.png` (統合 Inbox、スレッド畳み+バッジ) /
`m4-02-thread-detail.png` (スレッドビュー、`lastOpenedThread`
`@AppStorage` 復元経由でリランチ後に再現) / `m4-03-swiped-read.png`
(スレッド一括既読後) / `m4-04-unified-inbox-two-accounts.png`
(2アカウント統合) として出力される。

### M1/M3 XCUITest への影響 (件名の畳み込み)

M4 でスレッド化した結果、`OtegamiM1VerificationUITests`/
`OtegamiM3SetupUITests` が assert していた「明日の打ち合わせについて」
(02, References の元メッセージ) は、その返信 (03) と1行に畳まれ、
スレッド行には最新メッセージの件名「Re: 明日の打ち合わせについて」
だけが表示されるようになった。両テストとも `明日の打ち合わせについて`
への assert を `Re: 明日の打ち合わせについて` に差し替え済み — これは
バグ修正ではなく、スレッド一覧という新しい表示仕様に合わせた意図的な
変更。

### 既知の制約

- スレッドは口座 (account) 内で閉じる設計 (`thread.accountId`)。同じ
  会話が異なるメールボックス (例: INBOX と Sent) に跨る場合、初期同期の
  `AccountSyncer.performInitialSync` はすべてのメールボックスを処理し
  終えてから `ThreadAssigner.assignAllUnthreaded` を1回走らせて解決する
  設計だが、差分同期側は 1 パス内でメールボックスを日付昇順に処理する
  保証がないため、極端に到着順が入れ替わるケースでは一時的に別スレッド
  になり、後続のブリッジメッセージ到着時にマージされる (自己修復)。
- `ThreadAssigner` の各ルックアップクエリ (References/gmThreadId/subject
  候補) はメッセージ単位で都度発行しており、`assignAllUnthreaded` は
  O(未スレッド化メッセージ数) 回のトランザクション内クエリになる —
  M4 のデータ規模では問題にならないが、10万通規模の性能検証は計画上
  M10 の課題として残されている。

## iOS シミュレータ検証 (M5)

```sh
scripts/verify-ios-m5.sh
```

作成・返信・SMTP送信・Outbox・Sent APPEND のチェックポイントを、M3/M4 と
同様 XCUITest フェーズ + ホスト側 (Mailpit REST API・doveadm) 操作を交互に
実行して確認する。

1. `OtegamiM5SetupUITests` — test1 の Dovecot アカウントを IMAP に加えて
   SMTP フィールド (`localhost:1025`、平文 — dev mailstack の Mailpit)
   も入力し、「SMTP接続テスト」の成功を確認してから保存。既存のシード
   メッセージ一覧が表示されることも確認する。
2. `OtegamiM5ComposeSendUITests` — サイドバーの「作成」ボタンから新規
   メッセージを作成 (`To: recipient@otegami.test`、日本語件名・本文)
   して送信、Composer シートが閉じることを確認。
3. (ホスト) Mailpit REST API (`GET /api/v1/messages`) をポーリングし、
   送信した日本語件名のメールが実際に届いたことを assert。
   (ホスト) `doveadm fetch ... mailbox Sent` で、SMTP 送信成功後の
   ベストエフォート IMAP APPEND により Sent メールボックスにもコピーが
   残っていることを assert。
4. `OtegamiM5ReplyUITests` — シード済みの単一メッセージ「ようこそ
   otegami へ」を開き「返信」をタップ。Composer の To/件名/本文が
   非同期に (原文を GRDB から読んで) プリフィルされるのを
   `XCTNSPredicateExpectation` でポーリングして確認 (件名が
   `SubjectNormalizer` で正規化された上で `Re: ` が一度だけ付与される
   こと、本文が `> ` で引用されること) してから送信。
5. (ホスト) Mailpit REST API (`GET /api/v1/message/{id}/headers`) で、
   送信された返信の `In-Reply-To`/`References` ヘッダが元メッセージ
   (`seed-0001@otegami.test`) を指していることを assert — スレッド
   接続に必要なヘッダが実際に SMTP 経路に乗ったことを確認する
   (ローカル DB の `Threader` ロジック自体は M4 で既に単体/結合テスト
   済みなので、ここでは「送信されたバイト列に正しいヘッダが載るか」
   だけを見ればよい)。
6. (ホスト) `make mailstack-down` でオフラインを再現。
7. `OtegamiM5OfflineComposeUITests` — オフライン状態で新規作成→送信。
   ローカルの enqueue 自体は即座に成功 (Composer シートは閉じる) が、
   `OpQueueProcessor.replay` の冒頭の IMAP `connect()` が失敗するため
   バッチ全体が中断され、`.send` op も `outboxMessage` 行もキューに
   残る — サイドバーの「送信待ち」インジケーター (`sidebar.outbox`) が
   表示されることを確認する。
8. (ホスト) `make mailstack-up` でメールスタックを復元。
9. `OtegamiM5OfflineReplayUITests` — アプリを再起動 (`RootView` の
   `scenePhase == .active` ハンドラが opQueue replay を起動 — M3 の
   フォアグラウンド復帰と同じ経路)。「送信待ち」インジケーターが消える
   までポーリングして確認。
10. (ホスト) Mailpit REST API をポーリングし、オフライン中に作成した
    メッセージが復帰後の replay で最終的に届いたことを assert。

スクリーンショットは `SCREENSHOT_DIR` (既定 `/tmp/otegami-verify/`) に
`m5-01-compose-sent.png` / `m5-02-reply-sent.png` /
`m5-03-offline-queued.png` / `m5-04-offline-replayed.png` として出力
される。

### SMTP 送受信の設計上の注意点 (実装中に発見)

- `MCOSMTPSession.checkAccountOperationWithFrom:` (「SMTP接続テスト」の
  素朴な実装として最初に採用したもの) は内部で `MAIL FROM` +
  `RCPT TO:<bogus>` を送るが、対応する `RSET` を送らない。同一セッション
  上でこの直後に実際の送信 (`sendOperationWithData`) を行うと、2 回目の
  `MAIL FROM` が `RSET`/`EHLO` を挟まない状態で送られ、多くのサーバ
  (dev mailstack の Mailpit で実際に確認済み) から `503 Bad sequence of
  commands` を返される。`OpQueueProcessor.send` は `connect()` の直後に
  同じセッションで送信するため、これは実運用でも起きうる実バグだった。
  `MailCoreSMTPSession.connect(auth:)` は `checkAccountOperation` ではなく
  `session.loginOperation()` (EHLO/AUTH のみ、MAIL/RCPT に一切触れない)
  を使うよう修正済み — 「SMTP接続テスト」ボタンの検証用途にも十分な
  強度 (実際に EHLO+AUTH のラウンドトリップを行う) を保ちつつ、送信前の
  トランザクション状態を汚さない。ワイヤレベルの実挙動は
  `MCOConnectionLogger` (`session.setConnectionLogger(...)`) で直接観測
  して切り分けた — MailCore2 の Swift バインディングはメソッド名が
  ObjC ヘッダの見た目通りには自動変換されない箇所がいくつかあり
  (`sendOperationWithData(messageData:from:recipients:)` のように引数
  ラベルとして温存される、`checkAccountOperation(from:)` は素直に
  変換される、など)、コンパイラのエラーメッセージを頼りに1つずつ確定
  させた。
- MailCore2 の `MCOAddress`/`MCOMessageBuilder` の各種ファクトリ
  イニシャライザ (`MCOAddress(mailbox:)` 等) は Swift 側で failable
  (`MCOAddress?`) として bridge される — ヘッダのコメントには書かれて
  いない実装依存の挙動なので、force-unwrap の妥当性 (空文字列を渡さない
  限り実質的に失敗しない) をコード中にコメントで明記している。
- Mailpit はデフォルトで SMTP 認証を要求しない。`MCOSMTPSession` は
  `username`/`password` が「空文字列」であっても (`nil` でない限り)
  `AUTH` を試みてしまう実装になっているため、`MailCoreSMTPSession
  .connect` は `MailAuth.password` の `username` が空文字列の場合に
  限り `session.username`/`.password` への代入自体をスキップする
  (dev mailstack 向けの意図的な特例。実アカウントの空ユーザー名は想定
  していない)。
- Mailpit・Dovecot は互いに無関係な別サーバであり (実運用の「送信も
  受信も同じプロバイダ」という前提が dev mailstack には無い)、SMTP
  送信だけでは Sent メールボックスへの反映は一切起きない —
  `OpQueueProcessor.send` が SMTP 成功後に明示的に IMAP `APPEND` する
  実装になっているのはこのため。この APPEND はベストエフォート (失敗
  してもメールの再送はしない — 既に送信済みのメールを再送するのは
  APPEND 失敗より遥かに悪い) なので、`m5-01`/`m5-02` 相当の doveadm
  チェックは複数秒のリトライで確認している。
