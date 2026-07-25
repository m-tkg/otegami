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

## iOS シミュレータ検証 (M9 追補: `simctl push` 注入テスト)

```sh
scripts/verify-ios-push-simulated.sh
```

`.p8` キーなし・実機なしでも、`xcrun simctl push <udid> <bundleid>
payload.json` でシミュレータに直接ペイロードを注入できる。これを使い、実
APNs を経由せずに `NotificationService` Extension (`apps/Otegami
/NotificationService/NotificationService.swift`) を実プロセスとして起動させ、
「OS 配信 → Extension 起動 → App Group 経由の GRDB 読み取り → 共有
Keychain 読み取り → 実 IMAP ラウンドトリップ → 通知内容の書き換え」という
経路をエンドツーエンドで検証する (PENDING.md の M9 節に残っていた
「`xcrun simctl push` によるペイロード注入テスト・・・本セッションでは未実施」
の後続)。

1. `OtegamiPushSimulatedSetupUITests` — test1 の Dovecot アカウントを追加し、
   seed 済みメッセージが表示されることを確認してからアプリを `terminate()`
   する (`NotificationService` は本体アプリのプロセスとは独立して起動する
   ことを確認する意図で、あえてキルした状態から注入する)。
2. (ホスト) `xcrun simctl listapps` の JSON 変換 (`plutil -convert json`)
   から、インストール済みアプリの実際の bundle id と App Group コンテナの
   パスを**動的に**解決する — この開発機の `apps/Otegami/Config
   /Local.xcconfig` は `OTEGAMI_BUNDLE_ID` を `com.mtkg.otegami` (ハイフン
   無し) に上書きしており、他の `verify-ios-m*.sh` が使う固定デフォルト
   (`com.m-tkg.otegami`) とは実際に食い違う。`CFBundleDisplayName ==
   "Otegami"` でフィルタする必要があった点に注意 — `GroupContainers` を持つ
   かどうかだけで絞ると Reminders など App Group を使う標準アプリを誤って
   拾ってしまう (実際にこの開発機で `com.apple.reminders` を誤検出して
   確認済み)。
3. (ホスト) App Group コンテナ内の `otegami/otegami.sqlite`
   (`OtegamiStore.AppDatabase` のパス規約) を `sqlite3` で直接読み、
   `test1@otegami.test` の `AccountRecord.id` を取得する。
4. (ホスト) `doveadm save` で `dev/mailstack/seed/fixtures
   /08-m3-new-mail.eml` (`From: Aiko <aiko@otegami.test>`, `Subject: M3差分
   同期テスト` — M3 で使っている既存フィクスチャを転用) を INBOX に投入し、
   `doveadm mailbox status ... uidnext INBOX` で投入後の IMAP UIDNEXT を
   取得する — `server/otegami-relay/.../WatcherPool.swift` が実際に
   `PushNotificationPayload.uidNext` として送る値と同じもの。
5. ペイロードは実リレー (`APNsSender.swift`) が組み立てる形と同一
   (`mutable-content: 1`、`loc-key: NEW_MAIL`、`accountId`/`uidNext` を
   `aps` の外側に平置き — 件名/本文は一切含めない、というプランの
   プライバシー設計をそのまま反映) を 3 パターン用意する想定:
   - シナリオ1 (正常系): 実在の `accountId` + 投入直後の `uidNext` →
     通知の差出人/件名が "Aiko" / "M3差分同期テスト" に書き換わることを
     期待。
   - シナリオ2 (異常系): `make mailstack-down` で IMAP を到達不能にした
     状態で同じ `accountId` に注入 → `NotificationService.enrich(payload:)`
     の IMAP `connect()` が失敗し、汎用文言 ("新着メールがあります") の
     フォールバックのまま `serviceExtensionTimeWillExpire()` の ~30 秒
     予算内に配信されることを期待。
   - シナリオ3 (異常系): 存在しない `accountId` (ダミー UUID) を注入 →
     `lookupAccount` が `nil` を返し、IMAP に触れることすらなく即座に
     同じ汎用フォールバックになることを期待。
   各シナリオ後、`xcrun simctl io ... screenshot` で通知バナーを撮影し、
   `OtegamiPushSimulatedNotificationReadUITests` (`com.apple.springboard`
   に `XCUIApplication(bundleIdentifier:)` でアタッチし、通知センターを
   下スワイプで開いて "Otegami" を含む通知のラベル文字列を読み取り、
   xcodebuild のログに `PUSH-VERIFY-NOTIFICATION-LABEL: ...` として出力
   する) で実際に配信された文字列を機械的にも確認する試み。

### 追記 (後続セッション): 通知許可バグを修正、旧ブロッカーは解消。新たな Simulator 制約を発見

以下の「現状のブロッカー」節はこのセッション時点の記録として残すが、
後続セッションで `PushTokenCenter.requestToken()` に
`UNUserNotificationCenter.requestAuthorization(options:)` を追加する
修正を実装し (`docs/qa-findings.md`「M9 追補2」節に詳細)、
`OtegamiPushSimulatedSetupUITests` にも許可プロンプトを accept する
ステップ (`grantNotificationPermissionViaPushSettings`) を追加した。
`scripts/verify-ios-push-simulated.sh` を再実行した結果、**この
「Source is not authorized」ブロッカー自体は解消を確認した**
(3シナリオとも `simctl push` が受理された)。

ただし、その先で**この開発機の iOS 27 ベータ Simulator ランタイム固有と
見られる別の制約**に突き当たった: `NotificationService`
(`UNNotificationServiceExtension`) 自体が `launchd_sim` から一切
spawn されず、通知内容が (汎用フォールバックにすら) 書き換わらない。
アプリ側の設定 (`NSExtensionPointIdentifier`/entitlements/`.appex` の
埋め込み) は確認した範囲で正しく、Extension 起動要求そのものが OS 側
から発行されていないことをログ (`log show`/`launchd_sim` ジョブログ)
で確認済み。技術的な詳細・再現手順・確認したログの抜粋は
`docs/qa-findings.md`「M9 追補2」節を参照。結果として、「差出人/件名の
書き換え」までのシミュレータ上でのエンドツーエンド確認は、この開発機
では依然として不可能なまま残っている — 実機での最終確認
(PENDING.md M9 節) が引き続き唯一の手段。

### 現状のブロッカー (この開発機で確認済み、本セッションでは未解消) [解消済み — 上の追記参照]

この開発機・この iOS 26/27 ベータ toolchain では、`aps.alert` を含む
ペイロード (`mutable-content` 配信には `alert` か `sound` が必須 — `alert`
無しの `content-available` のみのペイロードは `UNErrorDomain code=1401
"Notification has no user visible content"` で別途拒否されることを確認
済み) に対する `xcrun simctl push` が**常に**次のエラーで失敗する:

```
UNErrorDomain code=2003: "Repository could not save notification.
Source is not authorized."
```

原因を切り分けた結果、**アプリが `UNUserNotificationCenter.current()
.requestAuthorization(options:)` を一度も呼んでいない**ことに行き着いた。
`Support/PushTokenCenter.swift` の `requestToken()` は
`UIApplication.shared.registerForRemoteNotifications()` (APNs デバイス
トークン登録) だけを呼んでおり、これは iOS 10 以降
`UNUserNotificationCenter` 側の通知許可 (バナー/サウンド/バッジの表示許可)
とは別の API なので、`registerForRemoteNotifications()` だけでは許可
ダイアログは一切出ない。以下の2通りで確認済み:

- `OtegamiM9PushSettingsUITests` の有効化フロー
  (`registerForRemoteNotifications()` を実際に呼ぶ) を先に実行してから
  同じインストール状態に対して `simctl push` してみても、同じエラーで
  拒否される。
- 設定 → Apps → Otegami の詳細画面には Siri/検索/モバイルデータ通信は
  出るが、**「通知」の項目自体が無い** — この iOS の設定アプリは
  `usernoted` に一度も登録されていないアプリには通知トグルを一切表示
  しない模様 (`xcrun simctl privacy --help` にも通知許可を付与する
  service は存在しない。`App-prefs:` deep link もこの iOS では無効化
  されており使えない)。

修正には `PushTokenCenter.requestToken()` に
`UNUserNotificationCenter.current().requestAuthorization(options: [.alert,
.sound, .badge])` を追加し (`registerForRemoteNotifications()` と並行して
呼ぶ)、それに伴うシステム許可ダイアログを XCUITest 側で accept する処理
(`dismissSavePasswordPromptIfNeeded` と同種の springboard "許可" タップ)
を足す必要がある。**この一行は `Support/PushTokenCenter.swift` — 今回の
タスクで編集を許可された範囲の外 — への変更が要るため、このセッションでは
あえて加えていない。** 対応方針は決まっているので、範囲を広げて良ければ
次のセッションで数分の作業。

現状 `scripts/verify-ios-push-simulated.sh` は、アカウント追加・
`accountId`/`uidNext` の解決・ペイロード構築までは実行して確認し (bundle
id 誤検出バグも含め、実際に動かして直した)、最初の `simctl push` で
上記の原因を名指しした診断メッセージを出して明示的に失敗するようにして
ある — 生の `UNErrorDomain` ダンプだけを残して黙って止まるより、次に
このスクリプトを触る人(自分自身を含む)が原因調査からやり直さずに済む
ようにするため。

このブロッカーとは独立に、`NotificationService.enrich(payload:)` の
「差出人/件名をどう書き換えるか」というロジック自体
(`title(senderName:senderAddress:)`/`body(subject:)`) は
`packages/OtegamiKit/Sources/PushRelayClient/NotificationEnrichment.swift`
に切り出し、`NotificationEnrichmentTests` (`swift test` で毎回実行される
`make test` に含まれる) で単体検証済み — 名前が空文字列/`nil` の場合の
アドレスへのフォールバック、件名が空文字列/`nil` の場合に汎用フォール
バックを上書きしないこと、を確認している。`NotificationService.swift`
自体は `OtegamiAppGroup.swift` の既存の前例 (Extension 側は project.yml の
依存関係の都合で別ターゲットの型を直接 import できないため、同一内容の
コピーを持つ) に倣い、同じロジックのミラーコピーを private に持つ形にした。

## macOS 検証 (M10)

M1–M9 の macOS 検証は `make mac` (ビルド確認のみ) に留まっていた。M10 で
初めて実際に起動して操作した結果、**ビルドは通っていたのに実行時に3つの
実バグ**が見つかった — いずれも「実際に起動する」ことでしか見つからない
類のバグで、この節はその手順と知見を記録する。

### 手順 (別プロジェクトで確立した macOS GUI 自動操作手法を踏襲)

```sh
make mac   # Debug ビルド
open -n -a ~/Library/Developer/Xcode/DerivedData/Otegami-*/Build/Products/Debug/Otegami.app
```

- `screencapture -x` でスクリーンショット。ウィンドウ位置・サイズは
  `osascript`(`System Events`) で固定してからキャプチャすると、以降の
  クロップ座標計算が安定する。
- クリック/ドラッグ/キー入力は別プロジェクトで確立した手法と同じ CGEvent ベースの
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

## 実機バグ: 初期同期は成功しているのにメッセージ一覧が空のまま

実機 (iPhone, iOS 26/27) でアカウント登録直後、統合受信トレイ・アカウント
直下の INBOX のどちらも「メッセージがありません 再同期を試してください」
のまま — にもかかわらず Dovecot 側ログでは UID FETCH が完了しており、
以降の再同期も INBOX を SELECT して「新着なし」と正しく判断していた
(= `mailbox.uidNext` は DB に永続化されている) というユーザー報告への対応。

### 調査で切り分けたこと

- **iCloud KVS reconcile (M11) の DELETE→INSERT 仮説は棄却**:
  `AccountCloudSyncEngine.reconcile()`/`CloudAccountDirectory.updateFromCloud`
  を読むと、既存アカウントとの last-writer-wins 上書きは `AccountRecord`
  の各カラムに対する `UPDATE` のみで `id` には触れず、`mailbox`/`message`
  の外部キーが指す `accountId` はどのパスでも変化しない。`insertFromCloud`
  はローカルに存在しない `accountId` の場合にしか発火しない。ローカル→
  cloud への push (`pushLocalChange`) 直後に自分自身の書き込みが
  `didChangeExternallyNotification` としてエコーバックされても、
  再度の `reconcile()` は同じ `accountId` を突き合わせて no-op か
  `UPDATE` になるだけで、`mailbox`/`message` のカスケード削除は
  発生し得ない。
- **XCUITest でユーザーの手順 (SMTP ユーザー名欄に値を入力した状態での
  SMTP接続テスト含む) をシミュレータ上で忠実に再現したが再現しなかった**
  — dev mailstack 相手の初期同期後、メッセージは正常に一覧表示された。
- 実機 (`xcrun devicectl`、`<あなたの iPhone>`) が本セッション中つながって
  いたため、`devicectl device copy from --domain-type
  appGroupDataContainer` でアプリの共有コンテナ (`AppDatabase.makeShared`
  が DB を置く場所) を覗こうとしたが、`otegami.sqlite` は App Group
  コンテナの**ルート直下**に置かれており (`Library`/`Documents`/`tmp`
  以外)、`devicectl` の remote file サービスの許可範囲外で直接は読めな
  かった (`Access restricted: ... is outside the allowed container
  directories (Library, Documents, tmp)` — ファイルが存在しないのでは
  なく、アクセスが制限されているというエラー)。
- 代わりに、実機に対して `xcodebuild test` (`platform=iOS,id=<UDID>`)
  で診断用 XCUITest を実行し、`app.debugDescription` でサイドバーの
  現在状態をダンプしたところ、**既存のアカウントは統合受信トレイ/
  INBOX ともに「27」件のメッセージを正しく表示していた** —
  この時点では症状が再現しなかった (ユーザー報告後、何らかの理由で
  自己修復していたか、直前の `build-for-testing` によるアプリ再起動
  が回復のトリガーになった可能性がある)。

### 有力な根本原因: 複数メールボックスを回すループの途中失敗が
`ThreadAssigner` を握りつぶす

`AccountSyncer.performInitialSync`/`performIncrementalSync` はどちらも
「同期対象の全メールボックスを1つのループで処理し、ループを抜けた後に
1回だけ `ThreadAssigner.assignAllUnthreaded` を呼ぶ」という構造だった。
このアプリの dev mailstack アカウントは INBOX 以外に Drafts/Junk/Sent/
Trash も持つ (SPECIAL-USE 経由で自動アドバタイズされる) ため、初期同期は
5つのメールボックスを順番に SELECT/FETCH する。**ループ内の *どれか1つ*
のメールボックスで `select`/`fetchEnvelopes`/書き込みが例外を投げると、
関数全体がそこで中断し、`ThreadAssigner.assignAllUnthreaded` に到達しない
まま return (実際には throw) してしまう。** この呼び出しは
`AccountSetupView.saveAccount`/`AppEnvironment` のどちらからも
`Task { try? await ... }` という fire-and-forget + `try?` 経由なので、
失敗はユーザーに一切通知されない。

結果: **ループの中で先に処理された INBOX の envelope は正常に DB へ
upsert 済み (`mailbox.uidNext` もその時点で永続化済み) なのに、
`message.threadId` が最後まで `nil` のまま残る** — `ThreadQuery`
(`request(mailboxId:)`/`unifiedInboxRequest(accountIds:)`) はどちらも
`EXISTS (... message.threadId = thread.id ...)` で `thread` 側から
`message` を辿るため、`threadId` が `nil` のメッセージは統合受信トレイ・
アカウント個別 INBOX のどちらからも一生見えない。一方 INBOX 自身の
`mailbox.uidNext` は正しく更新済みなので、次回以降の差分同期は
SELECT だけで「新着なし」と正しく判断し続ける — ユーザーの報告と
完全に一致する。

dev mailstack はシミュレータからは `localhost`、実機からは Mac の LAN IP
(`<Mac の LAN IP>`) 経由の Wi-Fi 越しで到達するため、後者の方が
タイムアウト/瞬断が起きやすく、この経路依存のバグがシミュレータでは
再現せず実機だけで踏まれたと考えるのが最も辻褄が合う (ループの後半
(Junk/Sent/Trash 側) のどこかで一過性のエラーが起き、それ以降
`performIncrementalSync` 側の同じ構造の「1つでも失敗すると
`ThreadAssigner` に届かない」バグにより、次の起動時 foreground sync
でも自己修復されない状態が何度かの再起動をまたいで続いた、という説明が
成り立つ)。

### 修正

`AccountSyncer.performInitialSync`/`performIncrementalSync` の
メールボックスループ本体を `do`/`catch` で包み、1つのメールボックスの
失敗を `continue` で握りつぶして次のメールボックスに進むよう変更した
(`packages/OtegamiKit/Sources/SyncEngine/AccountSyncer.swift`)。これにより
ループを抜けた後の `ThreadAssigner.assignAllUnthreaded` は、途中で
何が失敗していても必ず実行される — 一部のメールボックスが同期できな
かった場合でも、成功した分は必ずスレッド化されて一覧に現れる。

回帰テスト: `AccountSyncerTests
.laterMailboxFailureDoesNotBlockEarlierMailboxThreading`
(`packages/OtegamiKit/Tests/SyncEngineTests/AccountSyncerTests.swift`) —
`FakeIMAPSession.Script` で INBOX の `statusByPath` だけを用意し (Junk を
意図的に省略、`FakeIMAPSession.status(_:)` が未知パスに対して自然に
`mailboxNotFound` を投げる既存の挙動を利用)、`performInitialSync` が
例外を投げずに完了すること・INBOX のメッセージがちゃんとスレッド化
(`message.threadId != nil`、`ThreadQuery.request(mailboxId:)` が1件返す)
されていることを assert する。修正前のコードに対して実行すると
このテストは `performInitialSync` が `mailboxNotFound` を投げて失敗する
ことを確認済み。

### 実機で残る確認事項

- このセッションで実機の既存アカウントは既に (原因不明のタイミングで)
  自己修復しており、`AccountSyncer` の修正を実機でリアルタイムに再現
  →修正確認するところまではできていない。ユーザー側で改めて
  「その他」アカウント追加 → 実機の Wi-Fi 経由での初期同期、を試し、
  今回のビルドで空一覧が発生しないことを確認してほしい。
  発生した場合は `dev/mailstack` の Dovecot ログ (`docker compose logs
  dovecot`) にどのメールボックスの SELECT/FETCH 付近でエラー/切断が
  起きているかが残っているはずなので、それが次の手がかりになる。
- 今回の修正は「一部メールボックスの失敗を握りつぶして継続する」
  もので、失敗そのものをユーザーに可視化する変更ではない
  (`AccountSetupView.saveAccount`/`AppEnvironment` 側の `try?` は
  そのまま)。今後、部分的な同期失敗を `AccountsSettingsView` などで
  可視化するかどうかは別課題として残る。
  - **解決済み (後続セッション)**: `AccountSyncer` の per-mailbox
    `catch` に `MailboxRecord.lastSyncError`/`lastSyncErrorAt` への
    記録を追加し (成功時は自動クリア)、`MailboxSyncFailuresView` (M10
    の `FailedOperationsView` と同じ流儀) をサイドバーのバナーから開ける
    ようにした。`FakeIMAPSession` によるユニットテストに加え、実
    Dovecot 相手の `SyncEngineIntegrationTests
    .mailboxSyncFailureRecordsAgainstRealServerAndClearsOnRecovery`
    (`\Noselect` な中間メールボックスを使い、LIST には出るが SELECT が
    失敗する状態を再現) で確認済み。

## 実機バグ (続報): 006983a の後も、メッセージ一覧が起動ごとに出たり出なかったりする

`006983a`(上記節)の後、実機で「DB には正しくスレッド化されたメッセージが
入っているのに、アプリを起動すると一覧が出る場合と出ない場合がある」という
再発報告への追加調査。

### 却下した仮説: 統合受信トレイ observation の accountIds 固定キャプチャ

有力視されていた仮説 ——`MessageListView` が `environment.accounts` の
非同期ロード完了前に `ThreadQuery.unifiedInboxRequest(accountIds:)` の
observation を空 `accountIds` で張り付けてしまい、後からアカウントが届いても
再構築されない —— は、実際のコード (`apps/Otegami/Sources/Features/MessageList/
MessageListView.swift`) を読むと成立しない:

```swift
.task(id: ObservationKey(selection: selection, accountIds: environment.accounts.map(\.id), pageLimit: pageLimit)) {
    await observeThreads()
}
```

`ObservationKey` は `selection`/`accountIds`/`pageLimit` の3つ組で、
`environment.accounts` (`@Observable`) が変化するたびにこのキーも変わり、
SwiftUI が `.task(id:)` を確実にキャンセル→再起動する。さらに
`SidebarView.observeMailboxes(accountId:)` が「`selection == nil` の時だけ
`.unifiedInbox` を初期選択する」設計になっており、`selection` が
non-nil になった時点で `environment.accounts` は既にそのアカウントを
含んでいることが構造的に保証される(`RootView` の `content` は
`selection != nil` の時しか `MessageListView` を生成しない)。つまり
`MessageListView` が初めて観測を始める瞬間、`accountIds` が空になることは
起こり得ない。

シミュレータでの実証: 既に2アカウント・27件相当のスレッド化済みメッセージが
ローカル DB (かつ iCloud KVS にも) 揃っている状態から、`app.terminate()`/
`app.launch()` を20回連続で行い、毎回 `messageList.list` の1行目が
6秒以内に現れることを確認 (0/20 で失敗)。この観測配線そのものは壊れていない。

### 発見した実際のバグ: 非 CONDSTORE 差分同期の「消えたUID判定」がフェイルオープンでマスデリートする

`packages/OtegamiKit/Sources/SyncEngine/MailboxSyncer.swift` の
`refetchAndDiffFlags(mailboxId:mailboxPath:accountId:session:)`
(`CONDSTORE` 非対応サーバー向けの差分同期パス — 新着 + フラグ変更 +
サーバー側削除検知を1回の全ウィンドウ再取得で兼ねる) は、

```swift
let refetched = try await session.fetchEnvelopes(
    mailboxPath: mailboxPath,
    uids: UIDRange(lowerBound: UInt32(minUID), upperBound: nil),
    batchSize: AccountSyncer.fetchBatchSize
)
...
let serverUIDs = Set(refetched.map { Int64($0.uid) })
let deletedUIDs = Set(localUIDs).subtracting(serverUIDs)
```

という形で「再取得した範囲に含まれていないローカル UID = サーバー側で
expunge された」と判定し、該当 `message`/`thread` をまるごと削除する。
この判定は `fetchEnvelopes` が**例外を投げずに空(または不完全)な結果を
返した場合**にフェイルオープンする——ネットワーク接続が完全に切れた場合は
`MailCoreIMAPSession.fetchEnvelopesBatch` がバッチ単位で確実に `throw` する
(`AccountSyncer.performIncrementalSync` 側の per-mailbox `do`/`catch` が
そのメールボックスをまるごとスキップして安全に倒れる)ので大丈夫だが、
「サーバー往復自体は成功したが結果が空/一部欠落」という、真の expunge とは
見分けがつかない失敗モード (不安定な実機 Wi-Fi 経由の接続で libetpan/
MailCore2 側が起こしうる) には無防備だった。この経路を踏むと、まだサーバー
に実在するメッセージ・スレッドがまるごとローカルから削除される。

これは「同じ DB 状態で起動ごとに UI の見え方が変わる」というより、
「起動のたびに `RootView.syncAllAccountsOnce()` が呼ぶ
`syncAccountIncrementally` (既定 `.inboxOnly`) がこの経路を踏むたびに、
ネットワーク状態次第で **DB の中身そのものが非決定的に壊れうる**」という話
——ただし全滅した直後の**次の**起動では、ローカルの最大 UID が失われたことで
「UID 1 からの新着」として扱われ、次のインクリメンタル同期が成功すれば
自然に復元されうる(自己修復)。この「消える→(ネットワークが持ち直せば)
次の起動で復元される→また消えうる」というサイクルが、ユーザー報告の
「アプリを起動すると一覧が出る場合と出ない場合がある」に一致する。

dev mailstack の Dovecot は標準で CONDSTORE をサポートするため、この経路は
通常の verify スクリプトでは踏まれない(シミュレータでの20回連続コールド
ローンチ試験がクリーンだったのはこのため)。CONDSTORE 非対応の実プロバイダ、
または実機 Wi-Fi 越しの接続が不安定な場面でのみ顕在化する——前節の
「実機のみ・シミュレータでは未再現」というパターンと整合する。

### 修正

`refetchAndDiffFlags` に `status`(この差分同期パス自身が直前に取得した
`SELECT` の結果)を渡し、「再取得結果が空なのに、サーバーの `STATUS` は
このメールボックスにまだメッセージがあると言っている」という矛盾した
組み合わせのときは削除処理そのものをスキップするガードを追加した:

```swift
guard !(refetched.isEmpty && status.messageCount > 0) else { return 0 }
```

`AccountSyncer` の per-mailbox `do`/`catch` (前節の修正) と同じ「疑わしい
ときは何もしない」方針——例外を投げる代わりに `deletedMessages == 0` を
返して黙って次回に賭ける、既存の非破壊的フォールバックと同じ思想。

回帰テスト: `MailboxSyncerTests
.nonCondstoreFlagSyncDoesNotMassDeleteOnEmptyRefetch`
(`packages/OtegamiKit/Tests/SyncEngineTests/MailboxSyncerTests.swift`) ——
既存の3通スレッド化済みメッセージがある状態で、`FakeIMAPSession` の
非 CONDSTORE 差分同期スクリプトが空の `envelopesByPath`(かつ
`statusByPath.messageCount == 3`)を返すシナリオを再現し、
`deletedMessages == 0`・3通とも `message`/`threadId` が残ることを assert。
修正前のコードに対して実行すると `deletedMessages == 3`・
`ThreadQuery` 経由でも0件になる(= まさに「データはあるのに一覧が空」の
逆——データそのものが消える)ことを確認済み。

### テスト結果

- `swift test`(`packages/OtegamiKit`、フィルタなし全体)/ `make test`:
  green。
- `make mac` / `make ios`: build succeeded。
- `scripts/verify-ios-m1.sh`(`BUNDLE_ID=com.mtkg.otegami` —
  `Config/Local.xcconfig` がこの開発機では `OTEGAMI_BUNDLE_ID` を上書き
  している): 回帰実行、green(seed 4通が INBOX に表示、オフライン
  再起動でもローカル DB からそのまま表示され続けることを確認)。

### 実機で残る確認事項

- この修正は「再取得結果が完全に空」という最悪ケース(全滅)だけを防ぐ
  もの。一部の UID だけが欠落した不完全な再取得(真の部分 expunge との
  区別がつかない)まではカバーしていない——`VANISHED`(QRESYNC)による
  サーバー明示の削除通知を使う、または `serverUIDs.count` と
  `status.messageCount` の整合性をより厳密にチェックするなど、更なる
  堅牢化の余地が残る。
- dev mailstack の Dovecot は CONDSTORE 対応のため、このセッションでは
  `refetchAndDiffFlags` 経路自体を実機のような不安定な接続で再現・確認
  できていない(unit test でのみ検証)。ユーザー側で、CONDSTORE 非対応
  ないし不安定な実プロバイダに対して実機で再度確認してほしい——
  改善後も再発する場合は、その時点の Dovecot/実サーバーのログと
  `MailCoreIMAPSession` の `MCOConnectionLogger` 出力(前々節「SMTP AUTH」
  の調査で使ったのと同じ手法)が次の手がかりになる。
- 調査の過程で、`simctl erase` 直後の初回コールドローンチ時に、サイドバー
  が「アカウントがありません」空状態にもツールバー付きの通常表示にも
  20秒以上到達しない(XCUITest の `waitForExistence` が両方ともタイムアウト
  する)という別の現象を1回観測した。この開発機では `NSUbiquitousKeyValueStore`
  が(シミュレータ内蔵ではなく)実 iCloud 経由で永続化されており、
  `simctl erase` 後もこのマシンの Apple ID に紐づいた過去の verify
  実行分のアカウントが `AccountCloudSyncEngine.reconcile()` 経由で
  再度差し込まれる(=真の「ゼロアカウント状態」を `simctl erase` だけでは
  作れないケースがある)ことを確認したが、20秒という数字がスクリーンショット
  等で裏付けた「本当に固まっている」ことの証拠ではなく、2アカウント×5
  メールボックスの初回同期という重い処理と XCUITest 自体のオーバーヘッドが
  重なっただけの可能性も残るため、今回は深追いせず記録のみに留めた。次に
  この現象に遭遇したら、`xcrun simctl io booted screenshot` をポーリング中の
  シェルから並行して撮る (M6/M7 節の手法) ことで「本当に空白のまま固まって
  いるのか、単に遅いだけなのか」を切り分けられるはずである。

## 実機バグ: kill→起動直後にスレッド詳細へ勝手に遷移し、レイアウトが崩壊する

ユーザー報告 (iPhone 17 Pro, iOS 26): アプリを kill → 起動すると、

1. 何もタップしていないのにスレッド詳細画面 (`ThreadDetailView`) へ勝手に
   遷移する。
2. その詳細画面のレイアウトが崩壊する — 画面上 2/3 が空白、メッセージ行が
   画面最下部に押し付けられ、展開メッセージの本文が下端で見切れる。
3. 戻ってメッセージ一覧に戻ると、一番上のスレッド行だけタップが効かない。
4. さらにサイドバー → (アカウント個別の) INBOX をタップすると一覧に何も
   出ない。

4 つとも見た目は別々の症状だが、調査の結果 **2 つの根本原因** に帰着した
(3・4 は 1 と同じ `List(selection:)` 不安定性の別の現れ)。シミュレータ
(`simctl erase` 直後の真っさらな状態、iPhone 17 Pro Max) で全て再現し、
修正後は同じ手順で再現しなくなったことを XCUITest
(`OtegamiColdLaunchAndSidebarSelectionUITests`) で確認した。

### 原因1 (症状 1・2): 復元機能が `List(selection:)` の不安定さと組み合わさり、
コールドランチのたびに壊れた状態から始まる

`RootView` は M2/M4 で「最後に開いていたスレッドを `@AppStorage` に憶えて
おき、次の起動でも再現する」設計だった (`scripts/verify-ios-m2.sh`/
`verify-ios-m4.sh` の元々の検証項目そのもの)。まず素朴に「起動後最初の
1回だけ復元をスキップする」ガード (`hasSkippedInitialRestoration` という
one-shot フラグ) を試したが、実機バグは直らなかった —
`OtegamiColdLaunchAndSidebarSelectionUITests` で `simctl erase` 直後の
クリーンな状態から再現するテストを書き、以下を突き止めた:

- `SidebarView` は M4 以降唯一 `List(selection: $selection)` を使い続けて
  いた箇所だった (`MessageListView` は `List(selection:)` がこの環境の
  シミュレータ/実機トールチェーンで不安定という理由で、既に M2 の時点で
  行ごとの `Button` 直書きに切り替えていた — `.claude/skills/verify/
  SKILL.md` の M2 節「pitfall #2」)。
- アカウント/メールボックス一覧が非同期にロードされてくる間、
  `SidebarView.observeMailboxes(accountId:)` が `selection == nil` の
  たびに `selection = .unifiedInbox` を再代入するが、`List(selection:)`
  自体が `selection` を `nil` に巻き戻すことがある — 1回だけではなく、
  起動直後の短い間に複数回。`RootView` 側の `.task(id: selection) {
  restoreLastOpenedThreadIfNeeded() }` は `selection` が変わるたびに
  再実行されるため、"最初の1回だけスキップ" では 2 回目以降の巻き戻し→
  再設定サイクルで復元が発火してしまう — これが「skip の1回目は正しく
  スキップしたのに、後続の巻き戻しでやっぱり復元される」という, 実機で
  ユーザーが見た挙動そのものだった。

修正: `@AppStorage` によるプロセスをまたいだ永続化そのものをやめ、
プレーンな `@State`(プロセス内メモリのみ、`[String: Int64]`)に置き換えた
(`OtegamiApp.swift`, `lastOpenedThreadIdBySelectionKey`)。コールドランチは
常にこの辞書が空の状態から始まるため、`selection` がどれだけ起動直後に
振動しても "復元元になるデータがそもそも存在しない" — 呼び出し回数を数える
ヒューリスティックではなく構造的に不可能にした。同一セッション内で
サイドバーの選択を行き来する分の「前回開いていたスレッドを覚えておく」
利便性自体は維持している。

症状 2 (レイアウト崩壊) は症状 1 の直接の結果ではなく、`ThreadDetailView`
自体の独立したバグだった: `HTMLMessageView`/`MessageView` の `content` は
`.frame(maxWidth: .infinity, maxHeight: .infinity)` で「親が提案する高さを
埋める」設計 (M2 時点、`detail:` カラムに直接収まっていた頃は正しかった)
だが、M4 で `ThreadDetailView` 自身の `ScrollView`/`LazyVStack` の中に
`MessageView` をネストするようになった結果、`ScrollView` はスクロール軸に
沿って `nil` (無制限) の高さしか提案しない。`WKWebView` には意味のある
intrinsic content size がなく (このビュー自身のコメント通り、内部で
スクロールさせる設計を選んだ理由)、無制限提案の下ではほぼ 0 に潰れる。
以前あった `.frame(minHeight: 240)` は「MessageView 全体に最低 240pt」
しか保証せず、ヘッダがその大半を食うため HTML 本文にはほんの数十 pt しか
残らない — 本文が数行で見切れる原因。かつスレッド全体の実高さが画面より
大幅に短くなり、`.defaultScrollAnchor(.bottom)` と組み合わさって上部に
大きな空白が生まれる (実機でユーザーが見た「上 2/3 が真っ黒」)。

修正: `ThreadDetailView` を `GeometryReader` で包み、展開中の行の高さを
コンテナ自身の実測サイズから直接計算するようにした
(`expandedMessageHeight(in:)`、`max(360, containerSize.height - 160)`)。
`WKWebView` に具体的で十分な高さ予算を渡すことで内部スクロールが正しく
機能し、スレッド全体の実高さも画面をほぼ埋めるようになるため、上部の
空白も自然に解消する。

### 原因2 (症状 3・4): `SidebarView` の `List(selection:)` はタップ後も
不安定 — livelock で `MessageListView` の初回フェッチが永遠に完了しない

原因1の調査で使った一時的なデバッグカウンタ (`MessageListView` に
`observeThreads()` の呼び出し回数・yield 回数・エラーを表示する
`navigationTitle` を仕込んだもの) で、サイドバーのメールボックス行を
タップした後の状態を直接観察したところ:

```
calls=1 yields=0 err=nil
```

90 秒待っても変化しない。`ThreadQuery.request(mailboxId:)` が生成する
SQL をアプリ外から `sqlite3` CLI で直接実行すると即座に正しい結果 (10
スレッド) が返り、アプリの GRDB `DatabasePool` を並行してポーリングしても
`message`/`thread` テーブルの中身は終始一定 — データ層・SQL は無罪。
`observeThreads()` の中で `ThreadQuery.summariesObservation(...)` を
呼ぶ*前*に素の `dbWriter.read { ... }` を1回追加したところ、その
一発読み込み自体が `CancellationError()` を投げていた: つまり
`observeThreads()` を実行している `Task` (`MessageListView`'s
`.task(id: ObservationKey(...))`) が、初回の DB アクセスすら終わらない
うちに毎回キャンセルされていた。

原因1と同じ `List(selection:)` の不安定性がここでも起きている:
サイドバーの行をタップして `selection` が変わると `RootView` の
`content:` クロージャは `if let selection { MessageListView(...) } else {
ContentUnavailableView(...) }` なので、`selection` が (タップ後の巻き
戻しで) 一瞬 `nil` に振動するたびに `MessageListView` そのものが
アンマウント→リマウントされる。新しくマウントされたインスタンスは
`@State` がまっさらなので `.task(id:)` が新たに1回だけ発火するが、それも
また `selection` の次の巻き戻しでアンマウントされる — この
アンマウント→リマウントのサイクルが収束しない限り、`observeThreads()` は
一度も最初のデータベース読み込みを完了できない (livelock)。90 秒待っても
直らなかったのはこのため — 「遅い」のではなく「終わらない」。

修正: `SidebarView` の `List(selection: $selection)` を廃止し、
`MessageListView` が既に採用していたのと同じパターン (行ごとの `Button`
で `selection` を直接更新) に変更した。選択中の行のハイライトは
`.listRowBackground(selection == ... ? Color.accentColor.opacity(0.15) :
nil)` で手動再現している。修正後、同じシナリオで
`observeThreads()` は 1 秒程度で正常に完了するようになった
(`RESOLVED_AFTER=1.08` — 修正前は 90 秒待っても `CancellationError` の
まま)。

### テスト結果

- `swift test` (`packages/OtegamiKit`、フィルタなし全体) / `make test`:
  green (15 tests, 1 suite — 変更した Swift アプリ側コードは
  `apps/Otegami` にあり `OtegamiKit` の単体テスト対象外だが、回帰確認の
  ため実行)。
- `make mac` / `make ios` / `make ios-device`: build succeeded。
- `OtegamiColdLaunchAndSidebarSelectionUITests` (新規、両テストとも
  green): `simctl erase` 直後のクリーンな状態から、アカウント登録 →
  インライン画像つき HTML メールのスレッドを開く → kill → 起動、で
  (a) 一覧から始まる (`threadDetail.scrollView` が存在しない)、
  (b) 一覧の一番上の行がタップで開く、(c) 展開メッセージのヘッダが画面
  上半分に収まる (レイアウト崩壊していない) ことを確認。もう1つのテスト
  では、サイドバーの (統合受信トレイではなく) アカウント個別 INBOX 行を
  タップして一覧が実際にそのメールボックスのスレッドで埋まることを確認。
- `scripts/verify-ios-m1.sh`: green (regression, `BUNDLE_ID=com.mtkg.otegami`
  — この開発機では `Config/Local.xcconfig` が `OTEGAMI_BUNDLE_ID` を
  上書きしている)。
- `scripts/verify-ios-m4.sh`: 4 フェーズ全て green
  (regression)。このスクリプトと `verify-ios-m2.sh` はどちらも
  `xcrun simctl uninstall` (アプリコンテナのみ削除) でクリーンな状態を
  作っていたが、M11 で判明した「iCloud KVS/Keychain はコンテナ外なので
  uninstall では消えない」問題によりこのセッション中に実際に
  `OtegamiM4SetupUITests`/`OtegamiM2VerificationUITests` が「空アカウント
  状態を期待したのにアカウントが復活していた」で落ちた — `verify-ios-m1.sh`
  が既に採用していた `simctl shutdown` + `simctl erase` に両スクリプトとも
  揃えた。また `OtegamiM4ThreadDetailUITests`/`OtegamiM4SwipeReadUITests`
  が対象のスレッド行をスクロールなしの `waitForExistence` だけで探して
  いたため、`dev/mailstack/seed/fixtures/` が M2-M8 で増えた影響で行が
  画面外に出て見つからない/タップしても反応しない失敗も出た —
  `waitForElementScrollingIfNeeded` を使うよう修正 (`OtegamiM4SwipeReadUITests`
  はさらに、スクロール直後に行が画面端に来て `swipeRight()` が反応しない
  という `OtegamiM3SwipeActionsUITests` 既知のパターンにも遭遇したため、
  同じ「もう一段スクロールして端から離す」対処を追加)。いずれも本タスクの
  コード修正 (原因1・2) 自体とは無関係な、この開発機特有の環境要因/
  蓄積したシード件数に起因する事前からの脆さで、`popBackOnceIfNeeded`
  呼び出しが (復元廃止により) 意味が変わった (「detail→content の1段
  ポップ」ではなく「content→sidebar への1段ポップ」に変わり、呼ぶと
  1段行き過ぎるようになった) 箇所も合わせて `OtegamiM4SwipeReadUITests`/
  `OtegamiM4UnifiedInboxUITests`/`OtegamiM8CIDImageUITests` から取り除いた。
- `scripts/verify-ios-m2.sh`: green (regression — 上記と同じ `simctl erase`
  対応に加え、オフライン確認テスト自体を「コールドランチでの復元」から
  「一覧をタップして開く」に書き換えた。1回だけ Dovecot 認証がタイム
  アウトして失敗したが、`docker compose restart dovecot` 後の再実行で
  再現せず — 本タスクの変更と無関係な dev mailstack 側の一過性の問題と
  判断)。

### 実機で残る確認事項

- このセッション中、実機 (`<あなたの iPhone>`, UDID
  `<device-udid>`) は当初 `devicectl` から
  `connected` だったが、作業の途中で `unavailable` になった (USB/ネット
  ワーク接続が物理的に切れた模様で、こちらからは再接続できない)。
  `make ios-device` によるビルド・署名は成功しており、`dist` 相当の
  `.app` は用意できているが、`devicectl device install app` での実機への
  インストールはできていない。ユーザー側で実機を再接続した後、
  `xcodebuild -project apps/Otegami/Otegami.xcodeproj -scheme Otegami
  -destination 'platform=iOS,id=<device-udid>'
  build` (または Xcode から直接) でインストールし、以下を確認してほしい:
  1. アカウント登録済みの状態でスレッドを開き、アプリを kill → 再起動
     して、一覧から始まること (詳細へ勝手に遷移しないこと)。
  2. HTML メール (特にインライン画像つきのもの) のスレッド詳細を開いた
     ときに、画面上部に大きな空白ができず、本文が正しく表示されること。
  3. 一覧の一番上の行を含め、どの行もタップで開けること。
  4. サイドバーでアカウント個別の INBOX やその他のメールボックスに
     切り替えたときに、一覧がそのメールボックスの内容で埋まること
     (空のままにならないこと)。
- `SidebarView` の選択行ハイライトは `List(selection:)` のネイティブな
  見た目を手動の `.listRowBackground` で近似したもの — macOS
  (`List(selection:)` がキーボード操作や見た目の面でより重要な環境) で
  違和感がないか、実際の見た目を確認してほしい (`make mac` でのビルド・
  起動は成功しているが、このセッションでは自動検証していない)。

## 実機バグ (続報2): コールドランチが統合受信トレイから始まる/「直前の行」だけタップ不能

上の節の修正後、実機からさらに2件のバグ報告があり、シミュレータ
(`simctl erase` 直後、iPhone 17 Pro Max、compact 幅) で両方とも再現・修正した。
探索的 QA スイープ (`OtegamiQASweepUITests`) の一環として見つかったもので、
どちらも `RootView` の `preferredCompactColumn` の駆動方法に起因する、根っこは
同じ問題の2つの現れだった。

### バグ A: コールドランチがサイドバー最上位ではなく統合受信トレイから始まる

上の節の修正で「kill 直後に勝手にスレッド詳細へ遷移する」症状は直ったが、
まだ1段深い画面 (`messageList.list`) から起動するようになっていた —
`SidebarView.observeMailboxes(accountId:)` はアカウントのメールボックスが
初めてロードされた瞬間に `selection = .unifiedInbox` を直接代入する
(M4 由来の「アカウントがあれば即座に一覧が使える」設計) が、`RootView` 側の
`onChange(of: selection)` は `newValue == nil ? .sidebar : .content` という
判定で `selection` が `nil` から非 `nil` になるたび無条件に
`preferredColumn` を `.content` へ押し出していた。この2つが組み合わさると、
既存アカウントがある状態でのアプリ起動は**必ず**サイドバー最上位を素通り
してメッセージ一覧まで進んでしまう — ユーザーがどの画面から始めたいか
選ぶ余地が構造的に無かった。

### バグ B: 「直前に選択していた行」だけタップ不能

- 統合受信トレイを開く → 戻る → 「すべての受信トレイ」行を再タップ →
  一覧に遷移しない。
- スレッドを開く → 戻る → 同じ行を再タップ → 詳細に遷移しない。

`selection`/`selectedThreadId` の値は戻る操作をしても変わっていない
(同じ行を再タップしているだけなので当然同じ値) ため、`RootView` の
`onChange(of: selection)`/`onChange(of: selectedThreadId)` はそもそも
発火しない — 値の変化を検知して `preferredColumn` を押し出す設計だった
ため、「値は同じだが画面上の列は戻っている」という状態を検知する手段が
無かった。

### 修正

「データとしての選択が変わったか」と「ユーザーが実際にタップしたか」を
分離した。`SidebarView`/`MessageListView` の行 `Button` に、選択値の代入と
は別に `onSelected`/`onThreadSelected` コールバックを追加し、`RootView` は
このコールバック経由で**タップのたびに無条件で** `preferredColumn` を
押し出す (値が変化したかどうかのチェックを介さない)。バックグラウンドの
自動選択 (`observeMailboxes` の `selection = .unifiedInbox`) はデータの
代入のみ行い、この特別なコールバックを一切呼ばないため、コールドランチでは
サイドバー最上位に留まる (`RootView.onChange(of: selection)` は
`selection == nil` に戻す/場合分けする用途のみに縮小)。

macOS/iPad の常設3ペインレイアウトでは `preferredCompactColumn` 自体が
無視される (columns が横並びで常に全部見えているため) ので、この変更は
iPhone などの compact 幅の挙動にしか影響しない。

既存の XCUITest 群 (M1–M11、`OtegamiColdLaunchAndSidebarSelectionUITests`
の既存2ケース含む) はどれもこの「起動直後に一覧までノータップで行ける」
挙動を前提にしていた (このバグそのものを検証する意図では書かれていない)
ため、新しい起動時引数 `-uiTestsAutoAdvanceToContent` を追加し、旧来の
「アカウントが揃った瞬間に `preferredColumn` を `.content` へ押し出す」
挙動をこのフラグ付きの起動でだけ復元するようにした。`OtegamiApp
.uiTestsShouldAutoAdvanceToContent` が起動時引数を見て分岐する。
`DovecotAccountUITestHelpers.restartAppToRecoverTouchDelivery(_:
legacyAutoAdvanceToContent:)` の第2引数 (既定 `true`) がこのフラグを
自動付与し、`scripts/verify-ios-*.sh` の `screenshot`/`screenshotForeground`
(ホスト側 `xcrun simctl launch` — XCUITest 経由ではないのでタップできない)
にも同じ引数を追加した。実際にこのナビゲーション挙動そのものを検証する
`OtegamiColdLaunchAndSidebarSelectionUITests`/`OtegamiQASweepUITests` は
このフラグを一切使わず、常に本物のタップで遷移する。

**この修正作業中に踏んだ XCUITest 特有の落とし穴**: `XCUIApplication
.launchArguments` は同一インスタンスの `.launch()` 呼び出しをまたいで
**持ち越される** — 1回の `.launch()` にしか効かないという直感に反する。
`ensureDovecotTest1AccountExists` ヘルパーがアカウント新規作成のために
`restartAppToRecoverTouchDelivery(app)` (既定でフラグ付与) を呼んだ後、
同じ `app` インスタンスに対してテスト本体が素の `app.terminate();
app.launch()` を呼んでも、以前 `+=` で追加したフラグが残ったままになり、
「本物のコールドランチ」のつもりが実は毎回フラグ付き起動になっていた —
`simctl erase` 直後でアカウントがまだ無く、このヘルパーの分岐が実際に
実行された場合にのみ再現する (アカウントが既に存在する2回目以降の実行では
分岐がスキップされるため問題が表面化しない) ため、最初は間欠的な失敗に
見えた。`ensureDovecotTest1AccountExists` の最後で明示的に
`app.launchArguments.removeAll { $0 == "-uiTestsAutoAdvanceToContent" }`
して除去することで解決した。

### テスト結果

- `swift test` (`packages/OtegamiKit`) は今回コード変更対象外 (`apps/Otegami`
  配下のみ変更) だが回帰確認のため実行、green。
- `make mac` / `make ios`: build succeeded。
- `OtegamiColdLaunchAndSidebarSelectionUITests` (新規3ケース追加、既存2
  ケースを新しい遷移挙動に合わせて更新、計5ケース): `simctl erase` 直後の
  クリーンな状態から green (Dovecot 認証がこの開発機の負荷で1回だけ
  タイムアウトしたが、再実行で再現せず — 本修正と無関係)。
- `OtegamiQASweepUITests` (新規、探索的シナリオ7本): green
  (`testRapidSidebarMailboxSwitching` はテスト自身の設計ミス — compact 幅
  では push で画面が切り替わった後、以前キャッシュしたサイドバー行の
  座標解決が失敗する — を1度発見・修正、`testAddSecondAccountImmediatelyAfterFirst`
  も上と同じ Dovecot 認証タイムアウトを1回踏んだが再実行で再現せず)。

## macOS QA スイープ: 実際に起動・操作しての検証 (M10 以降の変更の macOS 影響確認)

M10 macOS 検証以降、iOS compact 幅を主眼にした大量の修正 (状態復元まわり、
`SidebarView`/`MessageListView` の `List(selection:)` → Button 駆動化、
`ThreadDetailView` の `GeometryReader` 高さ制御) が入ったが、macOS 側は
`make mac`(ビルド確認のみ) に留まっていた。このセッションで初めて
`.claude/skills/verify/SKILL.md`(M10 節) の手法 — `open -n -a`/`nohup` で
起動、`screencapture -x` + `sips --cropOffset` でスクリーンショット、
別プロジェクトで確立した verify 手法に倣った CGEvent ベースの `driver.swift` (scratchpad
にビルド) でクリック/キー入力を駆動 — を使って実操作した。

### 手順の要点 (次回の参考用)

```sh
make mac
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/Otegami-*/Build/Products/Debug/Otegami.app | head -1)
nohup "$APP/Contents/MacOS/Otegami" > /tmp/otegami-verify/mac-stdout.log 2>&1 &
# driver windows <pid> で AXUIElement 経由のウィンドウ座標一覧
# driver click/key/type で CGEvent 合成
# screencapture -x → sips -c <H> <W> --cropOffset <Y*2> <X*2> (retina は物理ピクセルなので論理座標を2倍)
```

- ウィンドウ位置は `osascript`(`System Events`) で固定してから座標計算する
  のは M10 節と同じだが、**`window 1`(インデックス指定) は使わないこと** —
  Composer など複数ウィンドウが同時に存在しうる状態で `window 1` を使うと
  「その時点でフロントの window」を指してしまい、意図しないウィンドウの
  位置/サイズを書き換えてしまう (実際に踏んだ: Composer がフロントの
  タイミングで `tell process "Otegami" to set size of window 1 to {1200,
  800}` を実行してしまい、Composer の永続化ウィンドウフレーム
  (`~/Library/Preferences/com.mtkg.otegami.plist` の `NSWindow Frame
  composer-AppWindow-1`) がメインウィンドウと同じ 1200x800 に書き換わって
  以降のすべての Composer 起動がその壊れたフレームを継承し続けた)。
  `tell process "Otegami" to set size of window "すべての受信トレイ" to
  {...}` のようにウィンドウ名を明示すること。
- Composer ウィンドウは `.defaultSize(560, 520)` だが、起動位置は環境依存
  (前回終了位置の復元など) で必ずしも固定ではない — ボタン座標はウィンドウ
  原点からの相対オフセットとして計算し、`driver windows <pid>` で毎回
  実際の原点を読み直すこと。固定座標を仮定すると、上記のフレーム破損
  以外の理由でも簡単にずれる。
- **このセッションの開発機は、同じデスクトップ上で他の自動化ツール
  (他のターミナルパネル、同一セッション内の並行
  エージェントの操作) が同時に動いていることがあり、`screencapture` の
  クロップ範囲に無関係な他アプリのウィンドウが写り込むことを実際に
  確認した** (他ツールのターミナル内容がそのままキャプチャに写った回が
  あった)。座標ベースのクリック自動化はこの手の外乱に弱いため、
  重要な操作 (特に確認ダイアログのボタンクリック) は失敗を非致命な
  `warn` として扱い、スクリーンショットでの目視確認と併用するのが
  現実的 (`scripts/verify-macos-qa.sh` のコメント参照)。

### 見つけて修正したバグ (macOS 固有コード)

1. **Composer をタイトルバーの赤信号ボタンで閉じると、未保存の内容が
   確認なしに失われる** (`docs/roadmap.md` 記載の既知の制約だった) —
   `ComposerView.swift` に `WindowCloseInterceptor`(`NSViewRepresentable`
   + `NSWindowDelegate.windowShouldClose(_:)`) を追加し、titlebar close
   も iOS の「キャンセル」ボタンと同じ保存/破棄確認を通るようにした。
2. **`ComposerLaunchPayload.new` が `static let` で UUID を使い回しており、
   macOS の `WindowGroup(for:)` の同一性判定に使われる結果、直前に破棄
   した Composer の入力内容が次の「新規作成」に漏れて残っていた** —
   `static var`(呼び出しごとに新しい `UUID`) に変更。
3. **macOS にはメッセージ一覧の右クリックメニューが無く、`.swipeActions`
   (iOS 専用、macOS では何もレンダリングしない) 頼みだった既読切替/削除が
   一覧から一切できなかった** — `MessageListView` に `#if os(macOS)
   .contextMenu` を追加し、既存の `toggleRead(_:)`/`deleteThread(_:)` を
   再利用。

3件とも実操作 (クリック→スクリーンショット→目視) で修正前の再現と修正後の
解消を確認済み。詳細・コード上のコメントは各ファイル参照。

### 見つけたが直さなかったバグ (macOS 固有コードの範囲外)

インライン `cid:` 画像 (`16-cid-inline-image.eml`) が macOS で解決に失敗し、
壊れた画像アイコンのまま表示される件を発見・原因特定まで行ったが、原因は
`CIDURLRewriter`/`CIDSchemeHandler` という iOS/macOS 共有コード側にあり
(`otegami-cid://<contentId>` の `contentId` に `@` を含む Content-ID を
そのまま `host` として使うと `URL` パーサが `@` を userinfo 区切りと解釈
して `host` が壊れる — `URL(string: "otegami-cid://otegami-logo@otegami
.test")?.host` が `"otegami.test"` になることを確認済み)、今回のタスクの
「macOS 固有コードのみ」というスコープの外だったため修正していない。
詳細な原因・再現手順・推奨対応は `docs/qa-findings.md` に記録した。

## 添付ファイル名: RFC 2231 (`filename*=`) フォールバックの追加

`docs/roadmap.md` に記録されていた既知の制約 (M8 節参照: ピン留めした
mailcore2 リビジョンは RFC 2231 拡張パラメータ (`filename*=UTF-8''...`、
および `filename*0*=`/`filename*1*=` の continuation 形式) のみでファイル名を
送ってくるメールから `filename` を拾えない) に対応した。

- デコーダ本体 (`RFC2231FilenameDecoder`, `packages/OtegamiKit/Sources/
  OtegamiCore/RFC2231FilenameDecoder.swift`) は純粋関数として実装し、
  `OtegamiCoreTests/RFC2231FilenameDecoderTests.swift` で UTF-8/ISO-2022-JP
  charset、continuation あり/なし (パーセントエンコードされたセグメントが
  マルチバイト文字の途中で分割されるケース含む — バイト列レベルで連結して
  から charset デコードする必要があり、セグメントごとに独立デコードすると
  壊れる)、パーセントエンコードされていない末尾セグメント、RFC 2047
  encoded-word との併用 (このデコーダは `filename*` パラメータが無い
  ヘッダには一切手を出さないことを確認)、壊れた入力 (charset 不明、
  パーセントエンコードの途中切れ、不正な16進数) を網羅している。
- 実際にフォールバックを発火させる側 (`MailCoreIMAPSession.fetchBody` +
  `MailCoreIMAPSession+Mapping.applyRFC2231FilenameFallback`) は、
  `bodyContent(from:)` が返したパートのうち `isAttachment == true` かつ
  `filename == nil` のものが1つでもある場合に**限り**、
  `fetchMessageBody(partId: nil)` でメッセージ全体の生バイト列を追加で
  1回フェッチして `RFC2231FilenameDecoder.extendedFilenames(inRawMessage:)`
  でスキャンし、位置合わせ (`filename` が無いパートの出現順序と、
  RFC 2231 形式の `Content-Disposition` ヘッダの出現順序が一致する前提 —
  デコーダが RFC 2231 形式のヘッダしか拾わない設計なので、mailcore2 が
  既に正しく解決したパートとは競合しない) で `filename` を埋め戻す。
  余分なフェッチは添付が無い/ファイル名が既に解決済みの通常ケースでは
  一切発生しない (roadmap の指摘どおり)。
- テスト用フィクスチャ `19-attachment-rfc2231-japanese.eml`
  (`dev/mailstack/seed/fixtures/`) を追加: `filename*0*=`/`filename*1*=`
  の continuation 形式のみでエンコードした日本語ファイル名
  (`領収書.pdf`、意図的にマルチバイト文字の途中でセグメントを分割) の
  PDF添付。RFC 2047 は一切使っていない点が既存の
  `15-attachment-japanese-pdf.eml` (RFC 2047 encoded-word) との違い。
  `seed.sh` に追加済み。
- 実 Dovecot に対する統合テスト
  (`MailCoreIMAPSessionIntegrationTests.fetchesRFC2231OnlyFilenamePDFAttachmentData`)
  で、`fetchBody` が実際に `filename == "領収書.pdf"` を返すこと (マルチ
  バイト文字またぎの continuation を含む実際のワイヤ経由で正しくデコード
  されること) と、`fetchMessageBody(partId:)` で添付本体のバイト列も
  問題なく取得できることを確認済み
  (`OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter
  MailCoreIMAPSessionIntegrationTests`)。

## アカウント編集 UI

```sh
scripts/verify-ios-account-edit.sh
```

`docs/roadmap.md` に記録されていた「アカウント編集 UI」(パスワード変更・
サーバー設定の修正・表示名変更ができず、変更したければ削除して再追加する
しかなかった) に対応した。`AccountsSettingsView` の各アカウント行がタップ
可能になり (`AccountEditView`)、メールアドレスと種類 (generic/gmail/icloud)
以外のフィールドを編集できる。保存時は `AccountRecord.updatedAt` を更新し
`AppEnvironment.pushAccountToCloud` で iCloud にも反映する (`docs/icloud-sync.md`)。

M3-M5 と異なり、このマイルストーンの検証シナリオ (パスワードを間違ったもの
に変更 → 同期失敗が見える → 正しいパスワードに戻す → 同期が復活) はホスト側
の `doveadm`/`Process` 操作が一切不要 (dev mailstack 自体を操作するのではな
く、アプリが持つ資格情報を書き換えるだけで再現できる) なので、
`OtegamiAccountEditUITests` は 3 フェーズとも純粋な XCUITest
(`-only-testing:` で個別実行、`xcodebuild test-without-building`) で完結する:

1. `testAddAccountAndRenameDisplayName` — `test1` の Dovecot アカウントを
   追加し、設定画面でその行をタップして編集画面を開く (`NavigationLink` によるプッシュ — 後述の実装メモ参照)。メールアドレス・
   種類が (`LabeledContent`、編集不可) 表示されること、フォームが既存値で
   プリフィルされていることを確認したうえで、追加フォームと共有している
   接続テストヘルパー (`AccountConnectionTesting.swift` の
   `testIMAPConnection`/`testSMTPConnection` — `AccountSetupView`/
   `ICloudAccountSetupView`/`AccountEditView` の3フォームがすべて同じ実装を
   呼ぶ) 経由で「接続テスト」が成功することを確認。表示名を変更して保存し、
   アカウント一覧に新しい表示名が反映されることを確認する。
2. `testSavingWrongPasswordSurfacesASyncError` — 同じアカウントの編集
   画面でパスワードだけをわざと間違ったものに変更して保存する。**追加
   フォームと異なり、アカウント編集の保存は「接続テスト」の成功を条件に
   していない** (`AccountEditView` のドキュメントコメント参照) — 保存自体
   は常に成功し、その後の同期試行が失敗として可視化されることを検証する
   のがこのフェーズの本題。保存後、リランチ不要でそのまま
   `settings.account.<id>.syncErrorBanner` (identifier の `CONTAINS` 検索
   — id は UUID なので厳密一致はそもそも書けない) が最大30秒のポーリングで
   出現することを確認する。リランチが要らない理由:
   `AppEnvironment.updateAccount` が保存時に
   `SyncCoordinator.invalidateSyncer(for:)` でキャッシュ済み
   `AccountSyncer` を破棄し、`OtegamiApp` が既に持っていた
   `.onChange(of: environment.accounts)`(新規アカウント追加用に M3 から
   存在する仕組み) がアカウント一覧の変化を検知して同じプロセス内で
   IDLE ループを新しい (間違った) パスワードで張り直すため。
3. `testFixingThePasswordRecoversSync` — 再度編集画面を開き、正しい
   パスワード (`test1234`) に戻して保存。`syncErrorBanner` が最大30秒の
   ポーリングで消える (`waitForNonExistence`) ことを確認する。

いずれの画面も (M6 のアカウント種別選択シートと同様) GRDB に永続化されない
純粋なナビゲーション状態なので、`verify-ios-account-edit.sh` は各フェーズの
`xcodebuild test` 実行と並行するバックグラウンドサブシェルで対象画面を
1秒おきに上書き撮影する。M6/M7 の「固定時間 sleep 後に1回だけ撮る」方式
ではなく (フェーズ1つあたりの所要時間がアカウント追加・初期同期・接続テスト
を含むため実行のたびに大きくばらつく)、`run_test` が返るまでバック
グラウンドループを回し続け、返った瞬間に `kill` してその時点の最後の
フレーム (テストメソッド末尾の `Thread.sleep(forTimeInterval: 4)` の間に
撮られたもの) をそのまま残す方式にしている。

スクリーンショットは `SCREENSHOT_DIR` (既定 `/tmp/otegami-verify/`) に
`account-edit-01-renamed.png` (表示名変更後のアカウント一覧) /
`account-edit-02-sync-error.png` (誤ったパスワード保存後の同期失敗バナー) /
`account-edit-03-recovered.png` (正しいパスワードに戻した後、バナーが消えた
状態) として出力される。

### アカウント編集の実装メモ

- **`SyncCoordinator.syncer(for:)` はアカウント id ごとに `AccountSyncer` を
  キャッシュし、一度作られた後は呼び出し側が渡す `AccountRecord` 引数を
  無視する** — 編集 UI 実装前はこれが問題にならなかった (アカウントの
  host/port/資格情報は作成後不変だったため) が、編集を許可すると「保存した
  のに古い host/port/パスワードを使い続ける」バグになる。
  `SyncCoordinator.invalidateSyncer(for:)` (キャッシュを破棄し、既存の
  IDLE ループを止める) を追加し、`AppEnvironment.updateAccount` が保存の
  たびに呼ぶことで解決した。`packages/OtegamiKit/Tests/SyncEngineTests/
  SyncCoordinatorTests.swift` に、invalidate しない場合は本当に古い host が
  使われ続けること・invalidate すれば次の同期から新しい host が使われる
  ことを対比させる単体テストがある。
- **接続レベル (認証失敗など、`session.connect()` 自体の失敗) の同期エラーは
  従来どこにも可視化されていなかった** — `MailboxRecord.lastSyncError`
  (M8 前後で追加済み) は `connect()` が成功したあと、個別メールボックスの
  同期が失敗した場合にしか記録されない。`AccountRecord.lastSyncError`/
  `lastSyncErrorAt` (migration v13) を追加し、`AccountSyncer` の
  `connect()` 呼び出し (`performInitialSync`/`performIncrementalSync`/
  `IDLE` ループの再接続) をすべてこの記録・クリアを行う共通ヘルパー経由に
  した。`AccountSyncerTests` に、接続失敗が記録されること・次の接続成功で
  クリアされることを確認する単体テストを追加した。
- **`AccountCloudSyncEngine.reconcile()`/`CloudAccountSnapshot.apply(to:)`
  は編集 UI 実装前から編集後の全フィールド (host/port/security/SMTP
  ユーザー名など) を正しく反映できる実装になっていた** — 既存の
  last-writer-wins テストを見る限り、これは (M11 の設計時点で) 意図的に
  実装済みだった模様。編集シナリオに特化した単体テスト
  (`reconcileAppliesAnEditedAccountFromANewerCloudSnapshotOnAnotherDevice`/
  `reconcileKeepsANewerLocalEditRatherThanAnOlderCloudCopy`,
  `AccountCloudSyncEngineTests.swift`) を追加で書いたが、いずれも既存実装
  への変更なしに green だった。
- **macOS でもアカウント編集画面を Settings シーン経由で開けることを
  `make mac` の実操作 (screencapture) で確認済み** — `AccountsListContent`
  (macOS の「アカウント」タブが直接埋め込んでいる、M10 の doc comment 参照)
  が iOS の設定画面と共通なので、追加のプラットフォーム分岐は不要だった。

### 実装中に踏んだ XCUITest の落とし穴 (この機能固有)

このセッションで実際に `OtegamiAccountEditUITests` を通す過程で3つ踏んだ
(いずれも実装のバグではなく、この simulator/toolchain での XCUITest の
振る舞いに起因するもの — `.claude/skills/verify/SKILL.md` の既存の落とし穴
リストと同種):

1. **`AccountEditView` を当初 `.sheet(item:)` で (`AccountSetupView` などと
   同様に) 提示したところ、行タップ自体は成功する (ログ上も正しい行の
   Button を検出・タップしている) のに、編集画面の識別子が
   `waitForExistence(timeout: 10)` を10回リトライしても一切現れなかった**
   — `AccountsListContent` は既に `AccountsSettingsView` 自身のシートの
   *中* にいるため、そこからもう1段 `.sheet` を開くのは「シートの中から
   さらにシートを開く」という、このアプリではまだ誰も自動検証していない
   ネスト深度だった (`SidebarView` の6つの `.sheet` はすべて同じ階層に
   並んでいるだけで、シートの中からさらにシートを開く例ではない)。
   `app.debugDescription` で実際のアクセシビリティツリーを確認したところ
   `settings.sheet` 自体は存在するのに、そこからのタップ後に画面遷移が
   一切起きていないことを確認 — 原因の特定までは至らなかったが、代わりに
   「設定画面のリストから `NavigationLink` で同じ `NavigationStack` に
   プッシュする」形 (`プッシュ通知`/`このアプリについて` の行と同じ、
   `OtegamiM9PushSettingsUITests` で実証済みの経路) に設計変更したところ
   問題なく動作した。**ネストしたシート提示はこのアプリでは避け、可能な
   限り既存の `NavigationStack` へのプッシュを使うこと。**
2. **`AccountEditView` の識別子 (`accountEdit.screen`) を `Form` に直接
   付けたところ、`app.otherElements["accountEdit.screen"]` では一切
   見つからなかった** — 上記1の原因調査で取得した
   `app.debugDescription` から、実際の要素種別が `CollectionView` である
   ことが判明 (iOS の `Form`/`List` は `UICollectionView` としてブリッジ
   される)。`AccountSetupView` の `.sheet` ルート識別子
   (`accountSetup.sheet`) が `.otherElements` で見つかるのは、それが
   `Form` ではなく1段上の `NavigationStack` 自体に付いているため —
   `NavigationStack` でラップせず `Form` に直接識別子を付けると要素種別が
   変わる、という組み合わせがこの落とし穴の本体。`app.collectionViews[...]`
   に変えたら即座に解決した。
3. **フォーム下部の「接続テスト」ボタンが `waitForExistence` に一切
   引っかからなかった** — M4 の `LazyVStack` の落とし穴と同種:
   `Form` (`UICollectionView`) は画面外の行をアクセシビリティツリーに
   マウントしない。`messageList.list` 用の
   `DovecotAccountUITestHelpers.waitForElementScrollingIfNeeded` は
   識別子がハードコードされているため使えず、同種のスクロールヘルパーを
   `accountEdit.screen` 用に自作したが、**最初に書いた
   `coordinate(...).press(forDuration:thenDragTo:)` (`messageList.list`
   のスクロールで実績のある手法) はこの `Form` に対しては何回試しても
   画面を一切動かさなかった** (10回・約2分リトライしても要素が現れない)。
   `.swipeUp()` (組み込みのジェスチャー) に変えたところ確実にスクロール
   した。M3 の落とし穴 (`.swipeActions` は組み込みの `.swipeLeft()`/
   `.swipeRight()` では動くが手組みドラッグでは動かない) の逆パターンが
   ここでも成立する形で再現した — **「あるビュー種別でどちらのジェス
   チャー手法が効くか」は種別ごとに実際に試すまで分からない**、という
   教訓が両方向で裏付けられた。

### スクリーンショットのタイミングについて (既知の制約)

`account-edit-03-recovered.png` は `run_test` が返った瞬間にバック
グラウンドの撮影ループを `kill` する方式 (前述) のため、フェーズ3の
テストメソッド自身の `Thread.sleep(forTimeInterval: 4)` の間に撮った
はずの最後のフレームが、実際にはテストランナーの `Tear Down` (アプリ
終了) が先に走った後のホーム画面になってしまうことがある — このセッション
で実際に1回確認した (アプリが確実に正しい状態に到達したことはテストの
アサーション自体が保証しているので実害はないが、目視用のスクリーンショット
としては不正確になる)。再現したときは、同じ画面へ遷移して
`Thread.sleep` で止まるだけの使い捨てテストメソッドを一時的に追加し、
同じシミュレータ (状態は保持されたまま) に対して単体で再実行して撮り
直すのが手っ取り早い。恒久的な修正 (例えばテストの最終フレームの直前で
確実に撮る仕組み) は今後の課題として残る。

## Drafts の IMAP 同期

```sh
scripts/verify-ios-drafts-sync.sh
```

`docs/roadmap.md` に記録されていた「Drafts の IMAP 同期」「下書きの添付
ファイル」に対応した。設計の要点 (詳細は `DraftMessageRecord`/
`OpQueueProcessor` の doc comment参照):

- **アップロード/置換は APPEND-first, delete-second**: `OpQueueKind
  .saveDraft` の replay は、新しい版をまず `APPEND` し、成功した後にだけ
  古い版を best-effort で `\Deleted` + `EXPUNGE` する。逆順 (先に削除) だと
  APPEND 失敗時に下書きが跡形もなく消える — このアプリの「曖昧な場合は
  消さずに両方残す」方針に反するため、意図的にこの順序にした。
- **サーバ由来の下書きは開いただけでは何も消費しない**:
  `DraftMessageRecord` はローカルで作成/編集された下書きの「アップロード
  待ち・置換待ち」状態だけを表す。他クライアントが書いた下書き
  (`DraftQuery.unifiedRequest` が `message`/`mailbox` テーブルから直接
  拾う `.server` 行) は、ローカル行に一切ミラーしない — 開いて何も編集
  せず閉じれば、サーバー側の実体には一切触れない。ローカル下書き
  (`ComposerLaunchPayload.draft`) の「開いた時点で行を消費する」既存
  M10 挙動とは意図的に非対称。
- **送信完了時の下書き削除もベストエフォート**: `outboxMessage` に
  `draftServerMailboxId`/`draftServerUid`/`draftServerUidValidity` を
  追加し、`.send` replay が SMTP 送信成功後に best-effort でその下書きを
  削除する。
- **Drafts メールボックスの自動作成**: 既存の Trash 自動作成
  (`resolveOrCreateTrashMailbox`) と同じパターンで
  `resolveOrCreateDraftsMailbox` を追加。
- **既知の制限 (統合テストで発見)**: `OpQueueProcessor` の自動作成
  ロジックは「ローカル DB にまだ mailbox 行が無い」ことだけを「サーバに
  存在しない」の代理指標にしている。実運用では account 追加時に必ず
  `AccountSyncer.performInitialSync` が一度走ってから
  `OpQueueProcessor` の出番が来るので問題にならないが、
  `DraftsSyncIntegrationTests` を書く過程で「一度も同期していない
  アカウントに対していきなり `.saveDraft` を replay する」という非現実的な
  テストを書いたところ、dev mailstack の Dovecot が最初から `SPECIAL-USE`
  で `Drafts` を持っているため `CREATE` が「既に存在する」エラーで失敗し、
  下書きの保存が永久にリトライし続けるケースを実際に踏んだ (Trash 側にも
  同じ潜在的な形が既にある)。テスト側を「まず `performInitialSync` する」
  という現実的な手順に直したことで解消したが、コード側の恒久対策
  (CREATE 前に一度 `listMailboxes()` する等) は行っていない — 発生条件が
  非現実的 (同期が一度も走っていないアカウントへの操作) なため優先度は
  低いと判断した。

### 単体テスト (`FakeIMAPSession`)

`OpQueueProcessorTests.swift` に Drafts 専用のセクションを追加 (計8件):
新規保存の APPEND + serverUid 記録、置換時の `\Deleted`+`EXPUNGE`、
`serverUidValidity` が古い場合は置換をスキップ (新規 APPEND 自体は継続)、
行が既に無い場合の stale discard、添付ファイルの同梱、Drafts メールボックス
自動作成の自己修復、`deleteDraft` op の `\Deleted`+`EXPUNGE`、
`uidValidity` 不一致での discard、送信成功後の下書き削除。
`MailboxSyncerTests.swift` に `.inboxOnly` スコープが Drafts メールボックス
も差分同期することを確認するテストを追加。`OtegamiStoreTests
/DraftQueryTests.swift` (新規) で `DraftQuery.unifiedRequest` のマージ/
重複排除ロジック (ローカル行がサーバ側の同一 UID を「占有」している場合に
サーバ由来行を除外する) を検証。`make test` はこれらを含めて green。

### 統合テスト (opt-in, dev/mailstack の実 Dovecot + Mailpit)

```sh
make mailstack-up
OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter DraftsSyncIntegrationTests
make mailstack-down
```

`DraftsSyncIntegrationTests.swift` (新規, `MailTransportMailCoreTests`
ターゲット) — 実 Dovecot に対して `OpQueueProcessor`/`AccountSyncer` を
直接動かす (UI 層は経由しない) 5件、すべて green:

1. ローカル下書きの保存が実際に Dovecot の Drafts へ `\Draft` フラグ付きで
   `APPEND` されること (`doveadm fetch ... flags`)。
2. 編集して再保存すると、Drafts 内のメッセージ数が常に 1 のまま (置換、
   重複しない) であること (`doveadm mailbox status ... messages`)。
3. 下書きから再開して送信すると、Mailpit に実際に届き、かつ Drafts の
   コピーが削除されること。
4. `deleteDraft` op が Drafts のメッセージを実際に削除すること。
5. 他クライアントが `doveadm save` で直接 Drafts に書いた下書きが、
   `AccountSyncer.performInitialSync` (通常の mailbox 同期経路、Drafts
   固有のコードパスなし) で取り込まれ、`DraftQuery.unifiedRequest` が
   `.server` 行として返すこと。

### iOS シミュレータ検証 (XCUITest, 実機で確認済み)

`scripts/verify-ios-drafts-sync.sh` の10フェーズをすべて実行し、green を
確認した (`OtegamiDraftsSyncSetupUITests`/`SaveUITests`/`EditUITests`/
`SendUITests`/`ExternalDraftUITests`)。M3/M4/M5 と同じ「XCUITest フェーズ
と host 側 `doveadm`/Mailpit REST API 確認を交互に実行する」パターン。

実施内容 (host 側の確認結果込み):

1. `test1` を SMTP 込みで追加し、シード済みメッセージが表示されることを
   確認。
2. Composer で新規メッセージを作成し「キャンセル」→「下書きとして保存」。
   host 側で Drafts に 1 通、`\Draft` フラグ付きで着地したことを確認
   (`doveadm mailbox status`/`doveadm fetch ... flags`)。
3. サイドバー「下書き」から件名の label CONTAINS 述語で行を見つけてタップ
   → Composer が同じ件名でプリフィルされることを確認 (`composer.subject`
   の `.value`) → 本文に追記して再度「下書きとして保存」。host 側で
   Drafts のメッセージ数が引き続き 1 のまま (置換、重複しない) であること
   を確認。
4. 下書きを再度開いて「送信」。host 側で Mailpit に届いたこと、Drafts の
   コピーが削除された (メッセージ数が 0 になった) ことを確認。
5. host 側で `doveadm save` により別 subject の `.eml` を Drafts へ直接
   投入し、アプリを再起動 (`scenePhase == .active` の差分同期 — 今回の
   変更で `.inboxOnly` が Drafts も対象に含むようになったパス)。
   サイドバー「下書き」を開くと、`drafts.row.server-<messageId>`
   (`DraftQuery.UnifiedRow.server` 由来の id) としてこの外部下書きが
   現れ、タップすると Composer に件名・本文がプリフィルされることを
   確認。**編集せずに「キャンセル」で閉じても保存/破棄の確認ダイアログが
   一切出ない**ことを assert (`composer.saveDraftButton` が
   `waitForExistence` しない) — 開いただけでは何も消費されない設計の
   核心部分。host 側で、この下書きが閉じた後も Drafts に変わらず 1 通
   存在し続けることを確認 (`doveadm mailbox status`/`doveadm fetch`)。

スクリーンショットは `SCREENSHOT_DIR` (既定 `/tmp/otegami-verify/`) に
`drafts-01-saved.png`/`drafts-02-edited.png`/`drafts-03-sent.png`/
`drafts-04-external.png` として出力される。

### 実行時の環境ノート

- **`xcrun simctl erase` 直後の1回目のテストはネットワーク/IMAP 認証が
  不安定なことがある**: フルパイプライン (`erase` → `boot` →
  `build-for-testing` → Phase 1) を初回実行した際、`test1@otegami.test`
  への IMAP/SMTP 接続がそれぞれ別の実行で `authenticationFailed`/
  `connectionFailed` になったことを2回確認した — `doveadm auth test`/
  `curl telnet://localhost:1143` など host 側からの直接確認では同時点で
  問題は再現せず、実際に Phase 1 単体だけを直後に再実行すると成功した
  (このセッションの Drafts sync 固有の問題ではなく、erase 直後の
  simulator ネットワークスタックの初期化タイミングに起因すると見られる —
  M1〜M11 の他スクリプトが `erase` 後すぐ `boot` → `bootstatus -b` で
  ブート完了を待っている点は同じだが、ブート完了と simulator 内蔵ネット
  ワークスタックの準備完了は別のタイミングらしい)。再現したら
  該当フェーズだけを単体で再実行すれば通る。恒久対策 (ブート後に一定時間
  待つ、またはネットワーク到達性を明示的にポーリングする) は今後の課題
  として残す。
- **`BUNDLE_ID` はこの開発機では `com.mtkg.otegami`** — `apps/Otegami
  /Config/Local.xcconfig` の上書き (M9 追補の節で既出) により、
  `scripts/verify-ios-*.sh` の既定値 `com.m-tkg.otegami` のままだと
  スクリーンショット用の `xcrun simctl launch` が失敗する。この開発機で
  実行する際は `BUNDLE_ID=com.mtkg.otegami scripts/verify-ios-drafts-sync.sh`
  のように明示的に上書きすること。
- **`SyncEngineIntegrationTests` の `seeded.count == 1` アサーションは
  Trash に古いメッセージが残っていると壊れる (今回の変更とは無関係の
  既存の脆さ)**: `DraftsSyncIntegrationTests` の作業中に
  `SyncEngineIntegrationTests.incrementalSyncPicksUpExternalChanges` が
  `seeded.count == 4`/`messages.count == 5` で失敗するのを踏んだ。
  `performInitialSync` は account の全メールボックス (INBOX だけでなく
  Sent/Drafts/Trash/Junk も) を同期し、このテストの `seeded =
  MessageRecord.fetchAll(db)` はアカウント全体のメッセージ数を数えて
  いるため、過去の `verify-ios-m3.sh` 実行が Trash に残していた3通
  (`docs/verify.md` の「dev/mailstack: state persists across
  milestones」節が既に文書化している現象と同根) がそのままカウントに
  混入していた。`doveadm mailbox status ... messages Trash` で実際に
  3通確認した上で、このテストのコード自体に変更は加えていない
  (Drafts sync の変更とは独立に元から存在した脆さのため、スコープ外と
  判断)。実行順序によっては同じ理由で `SyncEngineIntegrationTests` 単体が
  再現することがある点を記録しておく。
