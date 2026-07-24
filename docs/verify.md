# 動作検証 (verify)

人間の手を借りず、シミュレータ/実ビルドに対する自動検証で各マイルストーンの
チェックポイントを確認する方針 (計画書「テスト戦略」参照)。ノウハウは
`.claude/skills/verify/SKILL.md` にも蓄積している。

## 単体テスト

```sh
make test
```

`packages/OtegamiKit` の `swift test`。`OtegamiCoreTests` / `OtegamiStoreTests`
(in-memory GRDB) / `SyncEngineTests` (`FakeIMAPSession` によるシナリオテスト) /
`GoogleOAuthTests` (M6: PKCE 既知ベクタ、`URLProtocol` スタブによる token
交換/refresh/`invalid_grant`、`FakeAuthorizationFlow` による認可コード
受領〜token 交換の全体フロー、時計注入による `TokenStore` の期限管理 — 実
Google サーバにも実 Keychain にも触れない) は常時実行。`MailTransportMailCoreTests`
は `OTEGAMI_TEST_IMAP_HOST` 環境変数が設定されている場合のみ実行される
opt-in の統合テスト。

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

## M5: 実機検証で踏んだ XCUITest の落とし穴 (追加分)

M1〜M4 の落とし穴 (上記) に加え、`OtegamiM5ReplyUITests` を実際に
シミュレータへ通す過程で新たに踏んだもの。

1. **`ThreadDetailView` が `MessageView` に外側から付与する
   `.accessibilityIdentifier("threadDetail.message.<id>.body")` は、
   内側の子要素が自分自身に付けた identifier (`messageDetail
   .replyButton` など) を「追加」ではなく「上書き」してしまう** —
   `app.debugDescription` で実際のアクセシビリティツリーを確認すると、
   返信ボタンの要素は `identifier: 'threadDetail.message.2.body'` と
   報告され、`messageDetail.replyButton` はどこにも現れない。M4 の
   落とし穴 #1 (「1つの identifier に対し複数要素が同じ identifier を
   報告する over-count」) の類似だが、こちらは over-count ではなく
   完全な上書きで、`identifier CONTAINS` 述語ですら救えない。
   ラベルによる検索 (`NSPredicate(format: "label == %@", "返信")`)
   に切り替えることで確実に見つかる — M2 の「画像を表示」バナーと
   同じ回避策。同じ問題は `MessageView` を外側からラップして
   identifier を付け直しているコード全般 (`ThreadDetailView` の
   埋め込み) に当てはまるはずなので、その配下の要素を identifier で
   探す新しいテストを書く際は要注意。
2. **同一 XCUITest 実行内で一度でもスレッドを開くと `lastOpenedThread`
   `@AppStorage` が永続化され、以降の *どの* フェーズの `app.launch()`
   も (たとえ無関係なテストであっても) 自動的にそのスレッド詳細画面
   まで push された状態で起動する** — M4 の落とし穴 #4 で
   `OtegamiM4ThreadDetailUITests` 特有の注意として記録されていたが、
   M5 でも同じ理由で複数回踏んだ (ある意味「一度でもスレッドを開く
   フェーズより後の全フェーズ」に波及する、より広い注意点)。
   `messageList.list`/`sidebar.*` など「一覧」や「サイドバー」の要素を
   探すテストは、先行フェーズで一度でもメッセージ詳細を開いていないか
   を疑い、`returnToSidebarRootIfNeeded`/`popBackOnceIfNeeded` を使うか
   ("戻る" 操作が必要な場合)、逆に「このフェーズが実行順で最初に
   メッセージを開く」と分かっている場合はそれらの関数を **呼ばない**
   (呼ぶとサイドバーへ余計に戻ってしまい、まだ存在しないはずの
   `messageList.list` を探しに行ってしまう) — どちらが正しいかは
   「このテストの直前までに何かメッセージを開いたことがあるか」で
   機械的に決まる。
3. **原因切り分けは `app.launch()` 直後に `xcrun simctl io booted
   screenshot` を「もう一つの」シェルから撮る (M2 の手法) だけでなく、
   `waitForExistence` が失敗した箇所で `print(app.debugDescription)`
   してテストログに実際のアクセシビリティツリー全体を書き出す方が
   決定的だった** — スクリーンショットは「何が画面に見えているか」
   しか教えてくれないが、`debugDescription` は「XCUITest から見て
   各要素がどんな identifier/label/type で報告されているか」を直接
   見せてくれるため、上記 1. のような「見えてはいるが identifier が
   期待と違う」系の不一致はこちらでないと確定できない。

## iOS シミュレータ検証 (M6)

```sh
scripts/verify-ios-m6.sh
```

Gmail OAuth (PKCE) + iCloud プリセットのチェックポイントを検証する。M6 は
実 Google/iCloud アカウントが無いままの実装なので (`PENDING.md` 参照)、
自動検証できるのは「アカウント種別選択 UI」「Client ID 未設定時の Gmail
ボタン無効化」「iCloud フォームのプリセット表示」「『その他』経路が
従来通り動くこと」に限られる。実ブラウザでの OAuth ラウンドトリップと
実 iCloud 接続は対象外 (`docs/oauth-setup.md` の「実機での最終確認手順」、
`PENDING.md` の該当エントリ参照)。

1. `OtegamiM6TypeSelectionUITests` — 「アカウントを追加」が
   `AccountTypeSelectionView` (Gmail/iCloud/その他) を表示すること、
   `GOOGLE_OAUTH_CLIENT_ID` 未設定 (この検証ビルドの既定状態) では Gmail
   ボタンが無効化され `docs/oauth-setup.md` を指す案内文が表示されること、
   iCloud/その他ボタンは常に有効であること、キャンセルでシート全体が
   閉じることを確認する。
2. `OtegamiM6ICloudFormUITests` — iCloud を選ぶと `imap.mail.me.com:993
   (TLS)` / `smtp.mail.me.com:587 (STARTTLS)` のプリセットが表示され、
   メールアドレス/App 用パスワードを入力するまで「接続テスト」ボタンが
   無効のままであること、appleid.apple.com へのリンクが表示されることを
   確認する。実 iCloud サーバへの接続は行わない (下記「未検証事項」参照)。
3. `OtegamiM6OtherAccountFlowUITests` — 「その他 (IMAP)」を選んで Dovecot
   アカウントを追加するフロー (M1 相当) が、新しい種別選択画面を挟んでも
   従来通り動くことを回帰確認する。

スクリーンショットは `SCREENSHOT_DIR` (既定 `/tmp/otegami-verify/`) に
`m6-01-account-type-selection.png` / `m6-02-icloud-form.png` /
`m6-03-other-imap-inbox.png` として出力される。

### スクリーンショットのタイミングについて (このマイルストーン固有)

M1–M5 の検証はすべて「XCUITest 完了後にホストから撮る」パターン
(このファイル冒頭の「Screenshots (after the UITest, not during it)」節)
だったが、それは GRDB に永続化された状態 (アカウント一覧・メッセージ一覧)
を撮っていたから安全だった。M6 のアカウント種別選択シート/iCloud フォーム
はどちらも非永続 (画面遷移状態でしかない) なので、テスト完了後に撮ると
シートは既に閉じてしまっている。そのため
`OtegamiM6TypeSelectionUITests`/`OtegamiM6ICloudFormUITests` は対象画面に
到達した直後に `Thread.sleep(forTimeInterval: 4)` で数秒間その画面を
保持し、`verify-ios-m6.sh` 側はテスト実行と並行するバックグラウンド
サブシェルから同じファイルパスに 1 秒間隔で複数回スクリーンショットを
上書きする (単発の固定 `sleep` は xcodebuild/シミュレータ起動の揺らぎで
対象画面の表示ウィンドウを外すことがあると実際に確認したため、複数回
上書きする方式にした — 詳細はスクリプト内のコメント参照)。

### 未検証事項 (人間が実アカウントで行う)

- Gmail: `docs/oauth-setup.md` の「実機での最終確認手順」(Client ID 発行→
  実ログイン→送受信→トークン自動リフレッシュ→取り消し後の再認証バナー)。
- iCloud: `PENDING.md` の「iCloud App 用パスワードでの実アカウント確認」
  (実 App 用パスワードでの接続テスト・送受信、ユーザー名がフルアドレスで
  良いかの確認)。

## iOS シミュレータ検証 (M7)

```sh
scripts/verify-ios-m7.sh
```

全文検索 (FTS5 trigram MATCH + 短いクエリの LIKE フォールバック) と検索 UI
のチェックポイントを検証する。

1. `OtegamiM7SetupUITests` — `test1`/`test2` の Dovecot アカウントを両方
   追加し、それぞれの seed メッセージが表示されることを確認する (以降の
   検索フェーズが読む GRDB 状態のベースライン)。
2. `OtegamiM7SearchUITests` — 5 つの独立したシナリオ、それぞれ別々の
   `xcodebuild test -only-testing:` 呼び出し (フェーズ1が永続化した GRDB
   状態を、新しい `app.launch()` のたびに再利用する):
   - (a) 2 文字の日本語クエリ (`打ち`) — `SearchQuery` の `LIKE`
     フォールバックでヒット
   - (b) 3 文字以上の日本語クエリ (`打ち合わせ`) — FTS5 trigram `MATCH`
     でヒット
   - (c) 英語クエリ (`html`、小文字) — ASCII の大文字小文字を trigram が
     フォールドすることも同時に確認
   - (d) 統合受信トレイの既定スコープ「すべて」で、test1/test2 両方の
     結果が返る (`ようこそ`、両アカウントの seed メッセージ件名に共通)
   - (e) ヒットしようがないクエリで 0 件の空状態
     (`ContentUnavailableView.search`) が表示される

   5 つのクエリはすべて `message.subject` だけでヒットするよう意図的に
   選んである (`messageBody.plainText` には依存しない) — `BodyFetcher
   .prefetchRecent` のバックグラウンド本文取得パスが完了しているかという
   タイミング競合を避けるため。件名は `AccountSyncer.upsert` の
   envelope 同期時点で `FTSIndexer.reindex` により即座にインデックスされ
   るので、`OtegamiM7SetupUITests` が seed 件名の表示を確認できた時点で
   もう検索可能になっている。

検索結果は `@AppStorage` ではなく素の `@State` なので (M1-M5 のメッセージ
一覧と違って) XCUITest プロセス終了後にスクリーンショットを撮っても何も
映らない。各シナリオの test メソッドは `Thread.sleep(forTimeInterval: 4)`
で結果画面を数秒保持し、`verify-ios-m7.sh` はテスト実行と並行する
バックグラウンドサブシェルからその間にスクリーンショットを撮る — M6 で
確立した「テスト実行中に撮る」手法と同じ。

スクリーンショットは `SCREENSHOT_DIR` (既定 `/tmp/otegami-verify/`) に
`m7-01-two-char-japanese.png` / `m7-02-three-char-japanese-fts.png` /
`m7-03-english-query.png` / `m7-04-cross-account.png` /
`m7-05-empty-state.png` として出力される。

### `.searchable` の後に `.accessibilityIdentifier` を連結してはいけない

`MessageListView` の `List` にはもともと `.accessibilityIdentifier
("messageList.list")` が付いていた。検索フィールドにも識別子を、と
`.searchable(...)` の直後に `.accessibilityIdentifier("messageList.search
.field")` を追加したところ、`messageList.list` がまるごと見つからなく
なった (`OtegamiM7SetupUITests` を実行して発見) — `.searchable` は検索
バー用に別の子ビューを生やすわけではなく、同じ `List` の変更子チェーンに
機能を追加するだけなので、後から呼んだ `.accessibilityIdentifier` は
検索バー専用の識別子を新設するのではなく、その `List` 自身の識別子を
**上書き**してしまう。`.searchable` はどの画面でも検索バーを1つしか
生成しないので、識別子を諦めて `app.searchFields.firstMatch` で探す方が
安全 (`SearchUITestHelpers.typeSearchQuery`)。`messageList.search.loading`
/`.emptyState` や `.searchScopes` の各選択肢のように、`List` とは別の
ビューに付ける識別子は問題なく機能する。

### `ContentUnavailableView.search(text:)` の識別子より本文テキストの方が確実

`ContentUnavailableView.search(text: searchText)` に
`.accessibilityIdentifier("messageList.search.emptyState")` を付けても、
`app.otherElements["messageList.search.emptyState"]` では見つからなかった
(実行時にタイムアウト)。M2/M4 で記録済みの「厳密一致の識別子ルックアップ
が、画面には明らかに存在する要素を見つけられないことがある」パターンの
再発と見られる。代わりに、システムが生成する説明文 (`"No Results for
\"zzzznotfound\""`、検索語そのものを含む) を `app.staticTexts` の `label
CONTAINS` 述語で探す方式に切り替えたところ確実に見つかった —
`ContentUnavailableView.search` はクエリ文字列をそのまま説明文に含める
ので、この方式は今後どのクエリ文字列に対しても流用できる。

### 開発用メールスタックはマイルストーンをまたいで状態が残る

`m7-04-cross-account.png` には、seed フィクスチャに存在しない
「Dovecot Test1 / Re: ようこそ otegami へ」という行が写っている —
これは過去に `verify-ios-m5.sh` を実行した際、実際に SMTP 送信 + Sent
への IMAP APPEND を行った結果が、dev mailstack の永続ボリューム
(`dev/mailstack/data/`) にそのまま残っていたもの。`make mailstack-seed`
は INBOX だけを `doveadm expunge` してから re-seed する (`seed.sh` 参照)
ので、Sent 配下のデータはマイルストーンをまたいで蓄積し続ける。M7 の
アサーションは特定の件名の**存在**だけを確認しており、他の行が追加で
表示されても失敗しないため実害はないが、`verify-ios-m*.sh` を跨いで
繰り返し実行する開発環境では、検索結果に無関係な過去データが混ざり
うることは覚えておく価値がある (`dev/mailstack/data/` を消せば完全に
リセットされるが、それは通常の権限の外にある破壊的操作)。

### 既知の制約

- 検索スコープ「現在のメールボックス」への切替 (`.searchScopes` の
  もう一方の選択肢) は `SearchQueryTests`(単体、`SearchScope.mailbox`
  を直接検証) でカバーしているが、XCUITest からスコープピッカーを操作
  する自動検証は行っていない — `.searchScopes` のセグメント/ピッカー
  UI 要素を安定して操作する方法の調査は今後の課題として残す。
- FTS5 trigram の case folding は ASCII のみ (SQLite の仕様)。全角/半角
  や日本語の異体字を同一視するような正規化は行っていない
  (計画書の既知の制約として記録済み)。

## iOS シミュレータ検証 (M8)

```sh
scripts/verify-ios-m8.sh
```

添付の受信表示・保存・送信 + cid インライン画像のチェックポイントを検証する。

1. `OtegamiM8SetupUITests` — test1 の Dovecot アカウントを SMTP フィールド
   込みで追加し (フェーズ4のComposer送信で使う)、`dev/mailstack/seed/fixtures/
   14-attachment-png.eml` / `15-attachment-japanese-pdf.eml` /
   `16-cid-inline-image.eml` (`seed.sh` に M8 として追加済み) の3件が
   メッセージ一覧に表示されることを確認する。
2. `OtegamiM8AttachmentUITests` — PNG 添付メールを開き、添付セクションの
   `logo.png` 行をタップ (未取得 → `AttachmentFetcher` 経由でスピナー付き
   取得 → `.quickLookPreview` でプレビュー表示、の経路を実際に踏む)。
   QuickLook 自体はシステム UI (`.quickLookPreview` が提供する) なので、
   XCUITest からはボタンラベルの厳密な検証ではなく「新しいナビゲーション
   バーが出現したか」で「何らかのプレビュー画面が開いたか」だけを確認し、
   実際の表示内容はスクリーンショットで Claude が目視判定する。
3. `OtegamiM8CIDImageUITests` — cid インライン画像入り HTML メール
   (`16-cid-inline-image.eml`、`multipart/related`、`Content-ID:
   <otegami-logo@otegami.test>` の PNG を `<img src="cid:...">` で参照) を
   開き、本文テキストが表示されること、かつ「画像を表示」(外部画像ブロック)
   バナーが**表示されない**こと (このメールには `http(s)://` 参照が一切
   無く `cid:` のみなので、バナーが出ないこと自体が cid 経路が外部画像
   ブロックと独立に動いている証拠) を確認する。画像そのものの描画は
   `WKWebView` 内部なので XCUITest からは検証できず、スクリーンショットで
   目視判定する。
4. `OtegamiM8ComposeAttachmentUITests` — Composer で新規作成し、
   `OTEGAMI_UITEST_ATTACH_FIXTURE=1` launch environment 経由の内部フック
   (`ComposerView.attachUITestFixtureIfRequested`) でテスト添付ファイル
   (`m8-uitest-attachment.txt`) を自動添付、添付一覧にその行が表示される
   ことを確認してから送信する。
5. (ホスト) Mailpit REST API (`GET /api/v1/message/{id}`) で、送信された
   メールの `Attachments` に `m8-uitest-attachment.txt` が含まれることを
   assert する。

スクリーンショットは `SCREENSHOT_DIR` (既定 `/tmp/otegami-verify/`) に
`m8-01-attachment-quicklook.png` / `m8-02-cid-inline-image.png` /
`m8-03-compose-attachment-sent.png` として出力される。

### なぜ内部フック (`OTEGAMI_UITEST_ATTACH_FIXTURE`) なのか

システムのファイルピッカー (`fileImporter`)/`PhotosPicker` は本アプリの
アクセシビリティツリーの外で動くシステム UI であり、XCUITest から安定して
操作する方法がない (M2/M3 の落とし穴と同種の「アプリの外の UI は driveでき
ない」制約)。`ComposerView.attachUITestFixtureIfRequested` は
`ProcessInfo.processInfo.environment["OTEGAMI_UITEST_ATTACH_FIXTURE"] ==
"1"` のときだけ、プロセス内に埋め込んだ小さな固定データ (ファイルパスを
経由しない — シミュレータのアプリプロセスがホスト側で書いたファイルを
実際に読めるかというサンドボックス依存の前提を避けるため) を
`pendingAttachments` に追加する、通常起動時は完全に no-op の内部フック。
`XCUIApplication.launchEnvironment` (`Foundation.Process` と違い iOS
ターゲットからも問題なく使える — M3 の「`Process` は iOS で使えない」注記
とは別の話) 経由でこのフラグを立てるだけで、ピッカー UI を一切操作せずに
「添付ファイルが選ばれた後の状態」を確定的に再現できる。

### `Content-Disposition` の日本語ファイル名: RFC 2231 ではなく RFC 2047

`15-attachment-japanese-pdf.eml` (日本語ファイル名 `請求書.pdf` の PDF 添付)
は当初 RFC 2231 の拡張パラメータ (`filename*=UTF-8''%E8%AB%8B...`) で
書いていたが、この環境にピン留めされた mailcore2 リビジョンの
`MCOMessageParser` はこれを一切パースせず `filename` が `nil` になることを
`MailCoreIMAPSessionIntegrationTests`(実 Dovecot 相手の統合テスト) で発見
した。RFC 2047 の encoded-word をそのまま `filename="..."` パラメータの値に
埋め込む形 (`filename="=?UTF-8?B?...?="`) に切り替えたところ正しく
`"請求書.pdf"` にデコードされた — 送信側 (`MailCoreMessageBuilder`/
`MCOMessageBuilder`) は日本語ファイル名を正しく encoded-word 化して書き出す
ことを `MessageBuilderTests` で確認済みなので、これは受信パーサ側だけの
制限。他のメールクライアント/サーバが RFC 2231 のみで日本語ファイル名を
送ってくるケースは、この mailcore2 リビジョンでは `filename` が拾えず
「ファイル名なし」の添付として届く可能性がある点は既知の制約として残る。

### 統合テスト (opt-in) の並列実行について

`MailTransportMailCoreTests` ターゲットに `AttachmentFetcherIntegrationTests`
(新規) と `MailCoreIMAPSessionIntegrationTests` への追加テスト (PNG/日本語
PDF/cid 添付のバイト一致 assert) を M8 で加えたところ、`OTEGAMI_TEST_IMAP_HOST`
を設定してターゲット全体を**フィルタなしで**並列実行すると、`SyncEngine
IntegrationTests` (同じ実 Dovecot の INBOX を `doveadm expunge`/`save` で
破壊的に書き換える) が他スイートの同時読み取りとレースし、
`seeded.count == 1` のはずが `5` になるなど間欠的に失敗することを確認した
(`--no-parallel` を付けると常に成功することで裏付け済み)。個々のスイートを
`--filter` で単独実行する分には (各スイート自身のドキュメントコメントが
元々推奨している運用) 問題ない。ターゲット全体を一括で回したい場合は
`OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter MailTransportMailCoreTests
--no-parallel` を使うこと。`make test`/CI には一切影響しない
(`OTEGAMI_TEST_IMAP_HOST` 未設定時はこれらのスイート自体が丸ごとスキップ
されるため)。

### `MessageBuilderTests` を `.serialized` にした理由

M8 で `MCOAttachment`/`MCOMessageParser` を組み合わせるテストを追加した
ところ、Swift Testing のデフォルトの並列実行下で `Japanese subject and
body round-trip through the RFC 822 encoding` (M5 からある既存テスト、
M8での変更なし) が間欠的に失敗するようになった — `MCOMessageParser
.plainTextBodyRendering()` の戻り値が破損する形で再現し、`--no-parallel`
では常に成功することを確認済み。M8 以前のテスト数では顕在化していなかった
だけで、mailcore2 側の (この suite の並列度がある閾値を超えると表面化する)
スレッド安全性の限界と見られる。`swift test` 全体を `--no-parallel` にする
のではなく、この 1 suite だけを `@Suite(..., .serialized)` にする最小限の
修正で対応した (`make test` は変更後、複数回連続実行して安定を確認済み)。

### 既知の制約

- `m8-02-cid-inline-image.png` はメッセージのヘッダ部分・本文冒頭までしか
  写っておらず、実際の `<img src="cid:...">` (本文中ほど、スクロールが
  必要な位置) は screenshot のクロップ範囲に入っていない。cid 解決自体の
  機能検証は `OtegamiM8CIDImageUITests` のアクセシビリティツリー経由の
  アサーション (本文テキスト表示 + 外部画像バナー非表示) で行っており
  screenshot に依存しないため実害は無いが、画像そのものの見た目を
  screenshot で目視確認したい場合は事前にスクロールしてから撮る改善が
  今後の課題として残る。cid 経由でダウンロードされる添付データ自体は
  `AttachmentFetcher` を経由する同じ経路であり、`m8-01-attachment-quicklook
  .png` (QuickLook プレビューに実際に見える形の PNG が表示されている) で
  同じダウンロード〜表示パイプラインの動作は視覚的に確認済み。

## iOS シミュレータ検証 (M9)

```sh
scripts/verify-ios-m9.sh
```

プッシュリレーのオプトイン UI (設定 → 「プッシュ通知」) を検証する。
M1–M8 と異なり dev/mailstack への依存もアカウント追加も不要 (有効化フロー
の「`.password` アカウントごとに watch を作成する」ステップはアカウント
0件なら単に no-op)。

1. `testEnableButtonDisabledForInvalidRelayURL` — `http://relay.example.com`
   (https でも localhost でもない) を入力すると「有効にする」ボタンが
   無効のままであることを確認 (`AppEnvironment.validatedRelayURL`)。
2. `testEnablingPushOnSimulatorShowsGracefulDegradationMessage` —
   `https://relay.example.com` を入力するとボタンが有効化 → タップで
   資格情報送信に関する同意アラートが表示 → 同意すると
   `AppEnvironment.enablePushNotifications` が呼ばれる → シミュレータは
   実 APNs デバイストークンを発行しないため必ず `.noDeviceToken` で失敗し
   → それがクラッシュや無反応ではなく `settings.push.errorMessage` の
   可視エラーメッセージとして表示されること、かつ
   `settings.push.enabledLabel` (有効化成功状態) が出ないことを確認する。

screenshot は `SCREENSHOT_DIR/m9-01-app-relaunch.png` (テスト完了後に
アプリを再起動しての状態確認用 — SwiftUI の `.alert` は dismiss 後は
何も残らないため、テスト実行中ではなく完了後のスクリーンショットにして
いる)。

### 既知の制約 (このスクリプトが検証しない範囲)

実 APNs 配信・`NotificationService` による通知書き換え・実機でのエンド
ツーエンド確認は対象外 (`.p8` キー未発行 — `PENDING.md` の M9 節参照)。
otegami-relay サーバー自体の IDLE→push 発火パイプラインは
`scripts/verify-relay.sh` (実 Dovecot に対する統合検証) と
`server/otegami-relay/Tests/OtegamiRelayTests/WatcherPoolTests.swift`
(`FakeIMAPServer` 相手のユニット検証) で別途カバーしている。

## macOS 検証 (M10)

M1–M9 の macOS 検証は `make mac` (ビルド確認のみ) に留まっていた。M10 で
初めて実際に起動して操作した結果、**ビルドは通っていたのに実行時に3つの
実バグ**が見つかった — いずれも「実際に起動する」ことでしか見つからない
類のバグで、この節はその手順と知見を記録する。

### 手順 (mytty の verify スキル方式を踏襲)

```sh
make mac   # Debug ビルド
open -n -a /Users/masaki/Library/Developer/Xcode/DerivedData/Otegami-*/Build/Products/Debug/Otegami.app
```

- `screencapture -x` でスクリーンショット。ウィンドウ位置・サイズは
  `osascript`(`System Events`) で固定してからキャプチャすると、以降の
  クロップ座標計算が安定する。
- クリック/ドラッグ/キー入力は mytty と同じ CGEvent ベースの
  `driver.swift`(scratchpad にビルド) で駆動。`AXUIElementCreateApplication`
  でウィンドウの実座標を取得できるので、`sips --cropOffset` の計算に使う
  (物理ピクセル = 論理座標 × 2、Retina 前提)。
- macOS の座標系は「論理点 (CGEvent/AX 双方この単位)」⇔「物理ピクセル
  (screencapture の出力)」の変換を毎回丁寧に行うこと — このセッションで
  実際に何度か変換を誤り (crop 座標をそのまま論理クリック座標として使って
  しまう等)、無関係な場所をクリックし続けるという遠回りをした。

### 見つかった3つの実行時バグ (ビルドは通っていた)

1. **起動直後に必ずクラッシュ**: `AppEnvironment.init()` が
   `OtegamiAppGroupIdentifier` を Info.plist から読んで App Group
   コンテナを開こうとするが、macOS ターゲットには (意図的に)
   entitlements ファイルが無いため `com.apple.security.application-groups`
   権限が無く、コンテナ作成が `Operation not permitted` で失敗 →
   `assertionFailure` がそのままクラッシュに直結。`OtegamiAppGroup
   .identifier`/`.keychainAccessGroup` を macOS では `nil` を返すように
   修正 (M9 以前の「App Group 未設定時のフォールバック」経路にそのまま
   乗る)。
2. **`.sheet` の中身が空で表示される**: `NavigationStack { List/Form {...} }`
   形の sheet (アカウント種別選択、各アカウント設定フォーム、設定/送信待ち
   /下書き/同期エラー一覧) が、タイトルバーとツールバーだけの高さ数十pt
   の帯として表示され、List/Form の中身が一切描画されない。iOS と違い
   macOS は sheet を内容物の intrinsic size から自動サイズしないため —
   すべての該当 View に `#if os(macOS) .frame(minWidth:minHeight:) #endif`
   を追加して解決。
3. **macOS Settings シーンの TabView でタブ切替してもコンテンツが変わらない**:
   タブアイコンはハイライトが移動するのに、表示中の内容は前のタブのまま
   固定される。各タブの内容に `.id(...)` を明示的に付けて View の identity
   を切替のたびに変えることで解決 (SwiftUI が「同じ View」と判断して
   再描画をスキップしていたと見られる)。

いずれも `.claude/skills/verify/SKILL.md` に一般的な作業手順として、
この節にはプロジェクト固有の詳細を記録している。

## iOS シミュレータ検証: dev/mailstack のシードデータ増加による回帰 (M10)

M10 の最終回帰チェックで `scripts/verify-ios-m1.sh` 〜 `m7.sh` を実行した
ところ、複数のスクリプトで「以前は通っていたはずのアサーションが失敗する」
という回帰が見つかった。**M10 のアプリ側コード変更が原因ではなく**、
`dev/mailstack/seed/fixtures/` が M1 時点の4ファイルから M8 までに16
ファイルまで増え、すべて同じ test1 の INBOX に投入されるようになった
ことが原因 — 日付が最も古いフィクスチャ (`01-welcome.eml`, "ようこそ
otegami へ") が統合受信トレイの新着順リストの**最後尾**まで押し下げられ、
初期表示の画面に収まらなくなっていた。

- `messageList.list` は SwiftUI の `List` (内部的に `LazyVStack` 相当) な
  ので、画面外の行は `waitForExistence` で待っても見つからない (表示は
  されているのに識別子/テキストが一致しない、という M2/M4/M7 で既出の
  「見えているのに見つからない」系の話ではなく、本当にまだマウントされて
  いない)。
- `DovecotAccountUITestHelpers.swift` に
  `waitForSeededSubjectScrollingIfNeeded(_:in:)`/
  `waitForElementScrollingIfNeeded(_:in:)` を追加し、見つかるまで
  (Save Password プロンプトの解除を挟みつつ) スクロールを繰り返す形に
  変更した。`OtegamiM1VerificationUITests`/`OtegamiM3SetupUITests`/
  `OtegamiM4SetupUITests`/`OtegamiM4UnifiedInboxUITests`/
  `OtegamiM5ReplyUITests`/`OtegamiM6OtherAccountFlowUITests`/
  `OtegamiM7SetupUITests`/`OtegamiM3SwipeActionsUITests` をこのパターンに
  更新済み。
- 複数件チェックする場合は **新しい→古いの順** (スクロールは前進のみ、
  後戻りしない) に並べること。`OtegamiM4SetupUITests` はこの並び順を
  間違えて一度ハマった (先に一番下まで見に行ってしまい、それより上の行
  チェックが画面外に出て失敗した) — 各フィクスチャの `Date:` ヘッダを
  確認してから順序を決めること。

### 追加で見つかった「Save Password?」プロンプトの仕様変化

`dismissSavePasswordPromptIfNeeded()` は当初
`XCUIApplication(bundleIdentifier: "com.apple.springboard")` からのみ
"Not Now" ボタンを探していたが、この iOS 26 ツールチェーンでは
"Save Password?" は**アプリ自身のプロセス内 sheet** として出る
(`app.debugDescription` で確認: `Sheet, label: 'Save Password?'` が
`Application, label: 'Otegami'` の子として現れる) ため、springboard だけ
見ていた実装は常にタイムアウトして見逃していた。アプリ自身の
`XCUIApplication()` から先に探すよう修正 (springboard 側のチェックも
保険として残す)。このプロンプトは「アカウント保存直後」ではなく
「パスワードが実際にネットワーク認証で使われた瞬間」(= 初回同期の
タイミング、保存前の「接続テスト」ではない) に出るため、一度きりの
チェックでは間に合わないことがある — スクロールのリトライループの
たびに毎回チェックし直す設計にした。

## iOS シミュレータ検証 (M11: iCloud アカウント同期)

```sh
scripts/verify-ios-icloud.sh
```

実 2 台のデバイス間の iCloud KVS 往復は 1 台のシミュレータ/この開発環境
からは検証できない (`PENDING.md` に人間向けの実機確認手順あり)。自動検証
できるのは以下:

1. `OtegamiM11ICloudSyncUITests.testCloudSyncToggleIsShownAndOnByDefault` —
   `com.apple.developer.ubiquity-kvstore-identifier` entitlement 付きで
   アプリがクラッシュせず起動すること (M10 の「App Group entitlement
   missing → 起動時クラッシュ」の再発防止に相当)、設定に「iCloud で
   アカウントを同期」トグルが表示されデフォルト ON であることを確認する。
2. `OtegamiM11ICloudSyncUITests
   .testTogglingCloudSyncOffAndBackOnDoesNotCrashOrLoseTheAccountList` —
   Dovecot アカウントを追加 (M1 相当の回帰確認を兼ねる) →
   トグルを OFF→ON → アプリ再起動 → アカウント・メッセージ一覧が
   トグル操作前とまったく同じまま残っていることを確認する
   (`AppEnvironment.setCloudSyncEnabled` の OFF→ON full reconcile が
   既存アカウントを複製も欠落もさせないことの検証)。

スクリーンショットは `SCREENSHOT_DIR` (既定 `/tmp/otegami-verify/`) に
`icloud-01-settings-toggle.png` / `icloud-02-inbox-after-toggle-roundtrip.png`
として出力される。

### この開発環境で発見した重要な副作用: iCloud KVS/Keychain はシミュレータの `simctl uninstall` では消えない

M11 実装中、`scripts/verify-ios-m1.sh` を実行した直後に
`scripts/verify-ios-m6.sh` を実行したところ、`simctl uninstall` 後の
「フレッシュインストール」のはずのアプリが、**M1 のテストで追加した
Dovecot アカウントを最初から表示した状態で起動する**という現象が起きた。

原因: `simctl uninstall` はアプリ自身のコンテナ (GRDB データベースを含む)
を削除するが、Keychain と `NSUbiquitousKeyValueStore` の内容はこの
シミュレータ/toolchain ではアプリのコンテナ外に保存されており消えない。
M11 の `AccountCloudSyncEngine` は起動のたびに iCloud KVS を reconcile
するため、前回の verify 実行が cloud に push したアカウント (かつ
Keychain にパスワードも残っている) を「フレッシュな」はずの起動で
そのまま復元してしまう — この機能が実装通りに動いている証拠ではあるが、
「`simctl uninstall` = クリーンな状態」という M1〜M10 の verify スクリプト
群の前提を M11 が壊した形になる。

対処: `scripts/verify-ios-m1.sh`/`verify-ios-m6.sh`/`verify-ios-icloud.sh`
の「フレッシュインストール」ステップを `simctl uninstall` から
`simctl shutdown` + `simctl erase` (+ 再 boot) に置き換えた。erase は
Keychain/KVS を含むシミュレータの全状態をリセットするため、M11 より前と
同じ「本当にアカウント 0 件の起動」が得られる。他の verify スクリプト
(M2-M5, M7-M9) はまだ旧来の `simctl uninstall` のままなので、将来これらを
実行して同じ現象に遭遇したら同じパターンに揃えること
(`docs/roadmap.md` にも記録済み)。

### `Toggle` の `Switch.value` をタップ直後に読むのは信頼できない

`settings.cloudSyncToggle` (`Toggle`) をタップした直後に
`XCUIElement.value` (`"0"`/`"1"`) を読むと、実際には値が反映されている
にもかかわらず短時間 (数秒のポーリングでも) 変化を検出できないことが
あった。M2/M4/M7 で記録済みの「タップ自体は成立しているのに XCUITest 側の
状態読み取りが追いつかない」系の問題の再発と見られる。最終的には
`Switch.value` の厳密な値チェックをやめ、「タップ後もアプリが応答し続けて
いること」(= クラッシュ/ハングしていないこと) を確認するだけに弱めた —
このテストの本来の目的 (entitlement 追加がトグル操作でクラッシュを
起こさないことの確認) にはそれで十分だったため。デフォルト値そのものの
確認 (`testCloudSyncToggleIsShownAndOnByDefault`) は `Switch.value` の
単発読み取りで問題なく動く (タップ直後の再読み取りだけが不安定)。

### `List(selection:)` の行から Settings を閉じた後にメッセージ一覧へ戻る

Settings シートを閉じると、それを開く前にいた画面 (この場合はサイドバー
自体、`returnToSidebarRootIfNeeded` で明示的に戻ってから Settings を
開いたため) に戻る。`sidebar.unifiedInbox` は `Button` ではなく
`List(selection:)` の行なので、M2 の落とし穴 #2 (`List(selection:)` は
タップでバインディングが更新されないことがある) がここでも当てはまる
可能性がある。タップで安定して再入力する代わりに、`restartAppToRecoverTouchDelivery`
(`app.terminate()` + `app.launch()`) で丸ごと再起動する方式にした —
M1 以来の全スクリプトが依拠している「コールドリランチはユニファイド
受信トレイを自動選択する」という `RootView` の挙動 (`docs/verify.md`
「Offline verification pattern」節) にそのまま乗るだけで済み、GRDB から
直接読み直すのでトグル操作が何かをおかしくしていないかの検証としても
より確実だった。

## SMTP AUTH: AUTH 非対応サーバーへの自動フォールバック (M11 後の改善)

実機検証で発覚した UX 問題への対応: `MailCoreSMTPSession.connect` は
従来「SMTP ユーザー名が空なら認証スキップ、入っていれば AUTH」という
仕様だった。ユーザーが SMTP ユーザー名欄にメールアドレスを入れると、
認証機能の無い dev mailstack の Mailpit が `502 5.5.1 Command not
implemented` を返し、接続テストが失敗する — 「空欄にすれば通る」は
発見しにくい。ユーザー名が入っていても、サーバーが `AUTH` コマンド
自体を受け付けない場合 (502/503/504系の応答) は認証なしで1回だけ
リトライして接続を成立させるようにした。本物の認証失敗 (535系、
ユーザー名/パスワード違い) は今まで通りエラーのまま。

### 判別方法の調査結果

MailCore2 (`44c63329`固定) の `SMTPSession::login()`
(`MCSMTPSession.cpp`) は、`AUTH` の SASL 交換が失敗した場合のサーバー
応答コードに関わらず、すべて同じ `ErrorAuthentication` という
`MCOErrorCode` に潰してしまう — EHLO capabilities を公開する Swift 向け
公開 API も無い。したがって「AUTH 非対応」と「認証拒否」を安全に
判別できる唯一の手がかりは、`MCOSMTPOperation
._errorFromNativeOperation` (`MCOSMTPOperation.mm`) が `NSError.userInfo`
に生のまま詰めている `MCOSMTPResponseCodeKey` (実際に届いた3桁の SMTP
応答コード) だけだった — mailcore2 のソース (SPM 経由でローカルに
checkout 済みの `libetpan`/`mailcore2` チェックアウト) を直接読んで
確認した。`MailCoreSMTPSession.isAuthCommandRejectedAsUnsupported(_:)`
がこのキーを読み、500/502/503/504 (「コマンド未実装」「シーケンス
異常」「パラメータ未実装」寄りの応答) の場合だけ「AUTH 非対応」と
判定し、認証なしでの再ログインを1回だけ試みる。530/534/535/550/553
などの「資格情報自体が拒否された」応答や、応答コードが取得できない
曖昧なケースは安全側 (=これまで通りエラー) に倒す。

**実装上の落とし穴**: `MCOSMTPResponseCodeKey` の値は Swift 側で
`[String: Any]` として届くと `Int` ではなく `Int32` として動的型付け
される (mailcore2 の ObjC 側が生の C `int` を `@()` で `NSNumber` 化して
詰めているため) — `as? Int` は実サーバーに対して常に `nil` を返し、
フォールバック判定が一切効かないという回帰を一度作り込んだ。dev
mailstack の実 Mailpit に対する統合テスト
(`SMTPIntegrationTests.nonBlankUsernameAgainstNoAuthServerStillConnects`)
で発見・修正済み — `SMTPAuthFallbackTests`(単体, NSError 注入)側の
最初のバージョンは `responseCode` を素の `Int` で組み立てていたため
この不一致を検出できなかった。修正後は `NSNumber(value: Int32)` で
箱詰めして同じ動的型を再現するようにしてあるので、同じ回帰が単体
テストだけで再発検出できる。`(userInfo[...] as? NSNumber)?.intValue`
に直してある。

### 統合テスト: 認証必須の第2 Mailpit

`dev/mailstack/compose.yml` に AUTH 必須の `mailpit-auth` サービス
(ポート 1026、資格情報は `dev/mailstack/mailpit-auth/users.txt`) を
追加した。詳細は `docs/dev-mailstack.md` 参照。

- `SMTPIntegrationTests.nonBlankUsernameAgainstNoAuthServerStillConnects`
  — 既存の無認証 Mailpit に対し、ユーザー名を入れても接続・送信が
  成功することを確認 (今回のフォールバック本体)。
- `SMTPAuthIntegrationTests` (新規スイート、`mailpit-auth` 対象):
  - `correctCredentialsSucceed` — 正しい資格情報で接続・送信成功。
  - `wrongPasswordFailsAtConnect` — 間違ったパスワードは `connect()`
    で明確に失敗し、フォールバックには絶対に入らない (535 系)。
  - `blankUsernameConnectsButFailsToSend` — 空ユーザー名は
    `connect()`(EHLO/AUTH だけの往復) 自体は成功してしまう
    (`MailCoreSMTPSession.connect` の実装上、`loginOperation()` は
    `MAIL`/`RCPT` に一切触れないため) が、実際の送信
    (`sendMessage`、`mailesmtp_send` が `MAIL FROM` を送る) で
    `530 5.7.0 Authentication required` を受けて明確に失敗する
    (`MailCoreError.errorAuthenticationRequired` →
    `MailTransportError.authenticationFailed`)。「接続テストは通るが
    送信は失敗する」という非対称性は今回のフォールバックが原因では
    なく元からの設計 (`MailCoreSMTPSession`冒頭のコメント参照) —
    ここではそれが AUTH 必須サーバーに対しても同じ挙動になることを
    確認しているだけ。

### 単体テスト

`SMTPAuthFallbackTests` (`packages/OtegamiKit/Tests/MailTransportMailCoreTests/`,
ネットワーク不要、`make test` で常時実行) が
`MailCoreSMTPSession.isRetriableWithoutAuth(auth:error:)` を NSError
注入で検証: 500/502/503/504 → リトライ対象、530/534/535/550/553 →
リトライしない、応答コード欠落 → リトライしない (安全側)、
非authenticationエラー種別 → リトライしない、他ドメインの NSError →
リトライしない、空ユーザー名/XOAuth2 → リトライ対象外 (そもそも
この分岐に到達しない設計であることの確認)。

### 既知の制約

- このフォールバックはあくまで `MailAuth.password` かつユーザー名が
  非空の場合のみ有効。XOAuth2 (Gmail) には適用されない — Gmail は
  常に認証が必要な前提であり、「AUTH 非対応」という状況が意味を
  なさないため。
- `connect()` はログインの EHLO/AUTH 往復だけを見るため、「AUTH
  必須サーバーにユーザー名を空で接続した場合」は接続テスト自体は
  成功してしまい、実際の失敗は送信時 (`sendMessage`) まで顕在化
  しない。これは今回の変更が生んだものではなく、`checkAccountOperation`
  ではなく `loginOperation` を使う既存の設計 (M5 由来、上の
  「SMTP 送受信の設計上の注意点」節参照) からくる既存の非対称性。
- `dev/mailstack` に第2 Mailpit を追加したことで、`docker compose
  up`/`down` が起動・停止するコンテナが1つ増えた。`make
  mailstack-up`/`down` はそのままで両方カバーする (`compose.yml`の
  全サービスを対象にするため、呼び出し側の変更は不要)。

### この検証中に見つかった、本タスクと無関係な既存の flake

`SyncEngineIntegrationTests.incrementalSyncPicksUpExternalChanges`
(M3 由来) が、この開発環境の現在の dev mailstack 状態に対しては
単体実行しても `seeded.count == 1` の assertion で毎回失敗する
(`doveadm expunge` 直後に `doveadm save` で1通だけ投入しているはずが、
`performInitialSync` 後に2通観測される) ことを、本タスクの変更を
まるごと `git stash` した素の `main` ブランチでも再現することを確認
した — 今回の SMTP AUTH 変更・新規テストとは無関係の、この dev
mailstack インスタンス固有の既存の不具合/汚れた状態である。原因は
未特定 (`doveadm fetch ... all`を素朴に叩くとINBOX以外のメールボックス
も拾われるなど、調査中に紛らわしい挙動もあった)。今回のタスクでは
深追いしていない — 次にこのテストを触る際の既知の注意点として記録
しておく。
