# 性能検証 (M10)

10万通規模の合成データに対する計測結果と、そこから加えた改善のまとめ。
計測は `packages/OtegamiKit/Tests/OtegamiStoreTests/PerformanceTests.swift`
(opt-in、`make test`/CI には含まれない) で行っている。

```sh
cd packages/OtegamiKit
OTEGAMI_PERF_TEST=1 swift test --filter PerformanceTests
```

## 計測環境

- Apple M3 Pro, 18GB RAM, macOS 27.0 (26A5388g)
- 実ファイルの `DatabasePool`(WAL モード)。`AppDatabase.makeInMemory()` の
  `DatabaseQueue` はディスクに一切触れないため、ページキャッシュや WAL の
  コストを再現できず計測に使えない — `PerformanceTests` は専用の一時ディレクトリに
  `.sqlite` ファイルを作って計測している。

## データセット

- 合計 10万通、2アカウント。
  - account1: 8万通、事前スレッド化済み(1メッセージ=1スレッドの最悪ケース。
    90% は INBOX、10% は Sent)。本文は20通に1通のみ格納
    (`BodyFetcher.prefetchRecent` が新着のみ先読みする実挙動を模す)。
  - account2: 2万通、`threadId = NULL` のまま投入し、
    `ThreadAssigner.assignAllUnthreaded` で一括スレッド化して計測
    (「長期間オフライン後に再度開いた」ケースを模す)。

## 結果

| チェックポイント | 目標 | 結果 |
|---|---|---|
| 統合Inbox 首頁50件 (`ThreadQuery.unifiedInboxSummariesObservation`) | <100ms | **66.7ms** |
| 単一メールボックス 首頁50件 (`ThreadQuery.summariesObservation`) | <100ms | **8.8ms** |
| 検索 (FTS5 trigram, "perf message") | <500ms | **399.5ms** (200件でキャップ) |
| 検索 (LIKE フォールバック, "42") | <500ms | **87.0ms** (200件でキャップ) |
| ValueObservation 初回発火 (統合Inbox, limit 50) | 目安 | 80.6ms |
| `ThreadAssigner.assignAllUnthreaded` (2万通) | 目安 (ハード目標なし) | 13.7秒 |

一覧・検索とも目標を達成。以下、達成までに行った改善と、その根拠になった
具体的な計測値。

## 改善1: 検索結果の上限 (`SearchQuery.defaultResultLimit = 200`)

**改善前**: `SearchQuery.threadSummaries` は該当スレッドを無制限に返していた。
2文字程度のありふれた単語や、シード全通に共通する単語 (`"perf message"` —
account1 の全件名に含まれる) で検索すると数万〜8万スレッドがヒットしうる。
`ThreadQuery.summaries(forThreads:)` はスレッドごとに最新メッセージを
1クエリで引く設計 (N+1) なので、ヒット件数がそのまま往復回数になる。

実測 (改善前、無制限):

- FTS 検索 "perf message" (8万スレッドがヒット): **14,586.8ms**
- LIKE フォールバック検索 "42" (3,372スレッドがヒット): **604.7ms** (目標超過)

**改善後**: `threadSummaries(query:scope:limit:db:)` に `limit`
(既定 200) を追加し、`ThreadRecord` の取得自体を `LIMIT` で絞ってから
`summaries(forThreads:)` の N+1 を実行するように変更。8万件ヒットする
クエリでも「まず200件返す」形になり、UI 的にも「8万件のヒットを全部
表示する」より「絞り込んでください」の方が正しい体験になる。

実測 (改善後、limit 200):

- FTS 検索 "perf message": **399.5ms** (14,586.8ms から **97%削減**)
- LIKE フォールバック検索 "42": **87.0ms** (604.7ms から **86%削減**)

## 改善2: LIKE フォールバックの冗長な `DISTINCT` を削除

`SearchQuery.matchLIKE` は `message`/`messageBody`(1:1)/`mailbox`(1:1) を
結合しているだけで、`message.id` はどのみち重複しえない。にもかかわらず
`SELECT DISTINCT message.id ...` としていたため、SQLite が不要な重複排除用の
一時 B-Tree を作っていた。`DISTINCT` を外すだけで安全 (`SearchQueryTests` で
回帰確認済み)。上記の 87.0ms には改善1と2の両方の効果が含まれる
(改善1のみ・改善2適用前の中間計測では 736.1ms — DISTINCT 削除単体でも
ボトルネックの主要因ではなかったが、"200件キャップ" と組み合わせて安全側に
効いている)。

## 改善3: `ThreadQuery` の `EXISTS` ベース書き換え + `LIMIT` 対応 (v9 index)

**改善前**: `SELECT DISTINCT thread.* FROM thread JOIN message ... JOIN mailbox
... ORDER BY thread.lastMessageDate DESC LIMIT ?` — SQLite のクエリ
プランナが「`ORDER BY`+`LIMIT` を先に満たしてから `DISTINCT` で間引く」
プランを選べば速いが、そうでなければ **一致する message 行を全部 JOIN・
重複排除してから** ソート・LIMIT を適用することになる。特に「1スレッドに
大量のメッセージが同一メールボックスにある」ケース (長大なメーリングリスト
スレッド等) では、JOIN の中間結果がスレッド数よりずっと多くなり
`DISTINCT` のコストが跳ね上がる。

**改善後**: `thread` を主語に `EXISTS (SELECT 1 FROM message WHERE
message.threadId = thread.id AND message.mailboxId = ?)` という所属判定に
書き換え、`thread_on_lastMessageDate`(v9 index) で `thread` を
`lastMessageDate` の順に直接たどりながら `EXISTS` チェックで
`LIMIT` 件見つかった時点で打ち切れるようにした。`EXISTS` 側の判定自体も
`message_on_threadId_mailboxId`(v9 index) で O(1) に近い索引参照になる。

実測 (v9 index 導入後、10万メッセージ・1スレッドに5,000メッセージが
同一メールボックスに集中する「メガスレッド」を意図的に作った worst-case):

- 改善前のクエリ形 (`DISTINCT`+`JOIN`): **159.4ms** (目標超過)
- 改善後のクエリ形 (`EXISTS`): **79.9ms**

このデータセットではない「1スレッド=1メッセージ」の通常ケース(このファイル
冒頭の計測データセット)では両クエリ形の差はほぼ無かった (index 追加後は
どちらも 70〜85ms、index なしではどちらも 100〜140ms) — SQLite の
プランナが単純なケースでは同程度のプランを見つけられるため。つまり
**index 追加(v9)自体が主要な改善**であり、`EXISTS` への書き換えは
「プランナの判断に依存しない、メガスレッドのような worst case でも
確実に速い」という安定性のための変更という位置づけ。

`request(mailboxId:limit:)`/`unifiedInboxRequest(accountIds:limit:)` は
どちらも `limit: Int? = nil` (省略時は無制限、既存呼び出しと後方互換) を
追加し、`MessageListView` は 200件ずつのページングで呼び出す
(下記「アプリ側のページング」参照)。

## 改善4: 未読数バッジ用インデックス (`message_on_mailboxId_flagsRaw`)

M10 で追加した「サイドバー未読数バッジ」(`MessageQuery.unreadCounts`/
`unifiedInboxUnreadCount`) は `mailboxId` と `flagsRaw` の両方でフィルタする
ため、両者の複合indexを追加。単体の計測目標はないが、`unreadCounts` は
サイドバー描画のたびに(mailbox一覧の`ValueObservation`ごとに)呼ばれるため
このインデックスは体感速度に直結する。

## 既知の制約: `ThreadAssigner.assignAllUnthreaded` は依然として遅い

2万通の未スレッド化メッセージを一括スレッド化するのに **13.7秒**
かかっている(目標値なし、計測のみ)。原因は
`ThreadAssigner.buildContext` がメッセージ1件ごとに
References/gmailThreadId/件名候補の複数クエリを発行し、さらに
`assignThread`→`recomputeAggregates` がスレッド作成・メッセージ更新・
集計の複数ラウンドトリップを伴うため(1メッセージあたり実測で
概算 7〜8 ステートメント、2万通で 14万〜16万ステートメント)。

このパスは UI をブロックしない(`AppEnvironment.startObservingAccounts`
内の `Task` からバックグラウンドで実行される)ため、体感上の問題は
「アカウント一覧の初回反映が少し遅れる」程度に留まる。ただし将来
100万通規模を扱う、あるいはこのパスをフォアグラウンドで待たせる設計に
変える場合は、バッチ化(スレッド作成・集計をまとめて行う)が必要になる
— `docs/roadmap.md` の将来項目として記録した。

## アプリ側のページング (`MessageListView`)

`ThreadQuery`/`SearchQuery` の `limit` パラメータに対応して、
`MessageListView` は一覧を200件ずつ読み込む: 初期表示は200件、
リストの最終行が画面に現れたら次の200件を追加要求する
(`onAppear` ベースの単純な無限スクロール)。選択中のメールボックス/
統合Inboxが変わるたびにページサイズは200件にリセットされる。

## 10万通データでのスクロール確認 (macOS)

`/tmp/otegami-verify/m10-perf-*.png` — dev ビルドを10万通シードした
DB に対して起動し、統合Inbox一覧をスクロールしたスクリーンショット。
詳細は最終報告のmacOS検証セクション参照。
