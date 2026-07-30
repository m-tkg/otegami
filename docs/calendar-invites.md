# カレンダー招待メール対応 (Task #66)

「カレンダーの招待メールが来た時、『承諾』『辞退』『未定』のボタンを出す」
機能のドキュメント。UI/送信/永続化がどう分かれているか、EventKit (端末カレンダー
への追加) がなぜスコープ外か、を記録する。

## アーキテクチャ

`MailTransport`/`MailTransportMailCore` と同じ「純粋ロジックと具体実装を分ける」
方針を踏襲している。

```
OtegamiCore                     — 依存追加なしの純粋パース/生成ロジック
  ├─ CalendarInvite              パース結果のモデル (UID/SEQUENCE/SUMMARY/
  │                               LOCATION/ORGANIZER/ATTENDEE一覧/DTSTART/DTEND)
  ├─ CalendarPartStat            RFC 5545 §3.2.12 の PARTSTAT (ACCEPTED 等)
  ├─ ICSCalendarParser           ICS テキスト → CalendarInvite (行のunfold、
  │                               プロパティ/パラメータのパース、TEXTエスケープ
  │                               解除、DTSTART/DTENDのタイムゾーン解決)
  └─ ICSReplyBuilder             CalendarInvite + PARTSTAT → METHOD:REPLY の
                                  ICS テキスト・件名・本文テキストを生成

MailTransport
  └─ ComposeAttachment.contentTypeParameters
                                  Content-Type に method=REPLY 等を追加する
                                  ための拡張 (既存のmimeType/filename/dataに
                                  加えて任意個のパラメータを持てる)

MailTransportMailCore
  └─ MailCoreMessageBuilder.mcoAttachment
                                  contentTypeParametersをMCOAttachmentへ反映
                                  (下記「mailcore2 Swiftポートのバグ」参照)

SyncEngine
  └─ SyncCoordinator.sendCalendarReply(_:account:auth:)
                                  ComposeDraftを即時SMTP送信 (Outboxを経由しない
                                  理由は下記)

OtegamiStore
  └─ CalendarInviteResponseRecord (v28 migration)
                                  「この端末が最後に送った回答」を message.id
                                  1件につき1行だけ保持 (再回答で置き換え)

apps/Otegami (UI)
  ├─ MessageView.calendarInviteAttachment
  │                               attachments配列からtext/calendarパート
  │                               (無ければ.ics拡張子) を検出するだけの薄い層
  ├─ CalendarInviteSectionView     ICS読み込み・パース・回答送信・DB永続化の
  │                               状態を持つ (SyncCoordinator/AppDatabaseを叩く)
  └─ CalendarInviteCardView        見た目だけの表示コンポーネント
```

## ICS の取得経路: 添付ファイルと同じ仕組みを再利用

Google カレンダーの招待メールは `multipart/mixed` の中に
`text/calendar; method=REQUEST` パートを持つ (実際には `multipart/alternative`
の兄弟パートとして入っている)。`MailCoreIMAPSession+Mapping.parts(from:)` は
本文取得時にこのパートも通常の添付/インラインパート一覧
(`MCOMessageParser.attachments()`) の一部としてそのまま検出するため —
`MCHTMLRenderer.cpp`の`isTextPart`が`text/calendar`をbody部分ではなく
attachment扱いにしている — **`MailTransportMailCore`/`SyncEngine.BodyFetcher`
に一切変更を加えていない**。`attachment`テーブルに`mimeType="text"`,
`mimeSubtype="calendar"`の行が既存の仕組みだけで入る。

`CalendarInviteSectionView`は`MessageView.openAttachment(_:)`と全く同じ
`SyncCoordinator.fetchAttachment`を使ってこの行のバイト列をダウンロード
(既にローカルにあればネットワークに触らない)、UTF-8デコードして
`ICSCalendarParser.parse(_:)`に渡す。第一弾はパース結果をDBに保存せず毎回
その場でパースする方針 (実装コストとのトレードオフ、`ICSCalendarParser`
自体はO(パート内の行数)程度の軽い処理なので問題にならない)。

## 送信: iTIP REPLY を組み立てて即時SMTP送信

`ICSReplyBuilder.buildReply(for:partStat:selfAddress:)`が
`METHOD:REPLY`のVCALENDARテキストを生成する。元の`UID`/`SEQUENCE`を
そのまま踏襲し (`SEQUENCE`はattendeeの返信では増やさない — 主催者側の編集
だけが増やす)、自分の`ATTENDEE`行に選んだ`PARTSTAT`を設定する。件名は
Google カレンダー自身の招待返信と同じ規約 ("Accepted: <タイトル>" 等) を
踏襲しており、主催者の受信箱で見た目が揃う。

送信は`SyncCoordinator.sendCalendarReply(_:account:auth:)` — 通常の送信
(`OutboxMessageRecord`→`OpQueueKind.send`の永続キュー経由) ではなく、
`fetchBody`/`fetchAttachment`と同じ「その場で短命なセッションを開いて
即時送信」方式。理由:

- 招待カードの3ボタン以外に「送信待ち」表示やキャンセルUIを持たない
  一回限りの送信であり、Outbox/opQueueの永続化・リトライ機構を持ち込む
  価値が薄い。
- `OutboxAttachmentRecord`には`contentTypeParameters`列が無く
  (このためだけにスキーマ変更するのは過剰)、永続キュー経由にするには
  そこにも同じ拡張が要る。
- 失敗時はボタンをもう一度タップすれば再送できる — `MessageView
  .openAttachment(_:)`の「ダウンロード失敗→タップで再試行」と同じUXで
  十分。

## `CalendarInviteResponseRecord`: 「すでに回答済み」の表示用

message.id 1件につき1行、最後に送った`PARTSTAT`だけを保持する
(`v28`マイグレーション、`onDelete: .cascade`でメッセージ削除に追従)。
再回答は行を置き換える (履歴は持たない)。この端末からまだ一度も回答して
いない場合は、ICS自身のATTENDEE一覧から自分のメールアドレスに一致する
行のPARTSTATを表示のフォールバックに使う (`CalendarInviteSectionView
.loadCurrentResponse(for:)`) — ただし他のクライアント (Webブラウザ等) で
その後に回答した結果までは反映しない (このメールのICSは取得時点の
スナップショットのため)。

## mailcore2 Swift ポートのバグ: `setContentTypeParameterValue`

ピン留めしている mailcore2 リビジョンの Swift ポート
(`src/swift/abstract/AbstractPart.swift`) の
`setContentTypeParameterValue(_ value:name:)`は、内部で
`nativeInstance.setContentTypeParameter(value, name)`という順番で呼んで
いる。しかしコア (C++) 側のシグネチャは`setContentTypeParameter(name,
value)`で、Objective-C バインディングは正しい順序で呼んでいる — **Swift
ポートだけが引数を取り違えている**。

`MailCoreMessageBuilder.mcoAttachment`はこれを回避するため、あえて
`(value: name, name: value)`と引数を入れ替えて呼んでいる (コメントに詳細
あり)。`MessageBuilderTests.calendarReplyContentTypeParameterRoundTrips`
が実際に生の RFC 822 バイト列を検査して `Content-Type: text/calendar;
method=REPLY (or "REPLY")` になっていることを確認している — 「素直な」
引数順で書くと `text/calendar; REPLY="method"` のように名前と値が逆転した
壊れたヘッダになることを、このテストを書く過程で実際に踏んで発見した。

## スコープ外・今後の課題

- **EventKit (端末カレンダーへの追加) は対象外**。招待メールへの回答は
  iTIP REPLY の送信だけで完結する (Google カレンダー側は自動でイベントを
  作成/更新する) — 端末のカレンダーアプリに別途予定を作る/回答を反映する
  機能は別途の権限・UI設計が要るため、この回では見送った。
- 1通のメールに複数の`VEVENT`がある場合や、繰り返しイベント
  (`RRULE`/`RECURRENCE-ID`) の個別インスタンスへの回答は未対応
  — `ICSCalendarParser`は最初の`VEVENT`だけを見る。
- `VTIMEZONE`コンポーネント自体はパースしない — `DTSTART`/`DTEND`の
  `TZID`パラメータを`TimeZone(identifier:)`で直接解決するだけ (多くの
  実際の招待メールで使われる`Asia/Tokyo`等の標準IANA名では問題ないが、
  自前定義のカスタムタイムゾーンには対応しない)。

## 検証

- 単体テスト: `ICSCalendarParserTests`/`ICSReplyBuilderTests`
  (`OtegamiCoreTests`)、`MessageBuilderTests
  .calendarReplyContentTypeParameterRoundTrips`
  (`MailTransportMailCoreTests`)、`AppDatabaseTests
  .roundTripsCalendarInviteResponse`、`SyncCoordinatorTests`の
  `sendCalendarReply`系3件。
- 統合テスト (dev mailstack 必須、opt-in):
  `dev/mailstack/seed/fixtures/36-calendar-invite-google.eml`
  (Google カレンダー形式の招待、`test1@otegami.test`宛) を使った
  `CalendarInviteIntegrationTests` — 実際のIMAP経由でtext/calendarパートを
  発見・ダウンロードし、`ICSCalendarParser`で正しくパースできることを
  確認する。

  ```sh
  make mailstack-up
  make mailstack-seed
  cd packages/OtegamiKit && OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter CalendarInviteIntegrationTests
  make mailstack-down
  ```
- 画面確認: `scripts/verify-screen.sh calendar-invite` — DB直接注入
  (`OTEGAMI_UITEST_INSERT_FAKE_CALENDAR_INVITE=1`、実際のIMAP接続は行わない)
  で招待カードを表示する。非同期読み込みのタイミングによっては
  `scripts/verify-screen.sh`の待機時間内に描画が間に合わないことがある
  (機能自体は正常動作、`docs/verify.md`「シミュレータ検証の既知の不調」
  5番目の項目参照)。

### 実機確認ポイント (ユーザー確認が必要)

- **実際の Google カレンダー招待メールで「承諾」をタップし、主催者側の
  Google カレンダーに出欠が反映されるか** — この回では dev mailstack の
  架空アドレスでの一往復のみ確認済みで、実際の Gmail アカウント宛の
  本物の Google カレンダー招待に対する動作は未確認。
- 招待メールの `From:`/`Reply-To:` が主催者と異なる代理送信ケース
  (会議室予約システム等) での見た目・返信先の妥当性。

## Task #94: 実機で招待カードが出ない (根治)

実機で実際の Google カレンダー招待メールを開いても招待カード
(承諾/辞退/未定) が出ず、「添付ファイル 0 個」と表示される報告への対応。
#84 (commit 6899890) で「multipart/alternative 内の text/calendar +
無名 application/ics」の認識は直したはずだったので、原因は (a) MIME
認識の再発、(b) 認識はできているが非同期の表示経路が失敗、のどちらかを
切り分ける必要があった。

### 調査結果: (a) MIME認識は問題なし (新規ユニットテストで再確認)

`CalendarInviteIntegrationTests` (#84 で追加) は実 Dovecot 必須の opt-in
テストで、`make test`/CI では実行されない ( `.enabled(if:
TestIMAPEnvironment.primary != nil)` でスキップされる) — つまり #84 の
回帰があっても`make test`だけでは検知できない状態だった。これを埋めるため
`MailTransportMailCoreTests/CalendarInviteMIMEParsingTests.swift`を追加:
`MCOMessageParser(data:)`はネットワーク不要でローカルにRFC822バイト列を
解析できる (`MessageBuilderTests`が既に同じ前提で動いている) ことを
利用し、`MailCoreIMAPSession.bodyContent(from:)` (`fetchBody`が実際に
呼ぶのと同じ関数) に以下2パターンのフィクスチャを直接投入して常時
(`make test`/CI) 検証できるようにした:

- `multipart/mixed` > `multipart/related` (cid: 画像付き) >
  `multipart/alternative` > `[text/plain, text/html, text/calendar]` —
  #84 が直した「alternative の中」よりさらに一段深いネスト
  (Gmail が本文にインライン画像を含む場合にこの`related`層が入る)。
- `text/calendar`単体のみで、対になる`application/ics`添付が無いケース。

両方とも既存コードのまま (変更なしで) 正しく`text/calendar`パートを発見・
認識することを確認済み — mailcore2の`MCHTMLRenderer`がコンテナ種別を
問わず再帰的に`multipart/*`を辿る実装 (この節冒頭の「アーキテクチャ」節
参照) なので、ネストの深さは無関係だった。**MIME認識層は今回の実機報告の
原因ではないと判断**。

### 調査結果: (b) 非同期表示経路が本命

`docs/verify.md`の既知不調5番目 (#66回で発見・未確定のまま保留) が有力
候補だった: `CalendarInviteSectionView`は`@State`(`invite`/`isLoading`/
`loadErrorMessage`)を自分自身で持ち、`.task(id: calendarAttachment.id)`
でICSダウンロード+パースを行っていた。この View は
`MessageView.body`の`if let calendarInviteAttachment, let mailboxPath { ... }`
という**optional-bindingの条件分岐の中**にあり、`MessageView.load()`が
自身の複数の`@State`(`attachments`など)を書き換えるたびに`body`が
再評価される — その過程で`calendarInviteAttachment`が一時的に`nil`に
戻る瞬間 (`load()`冒頭の`attachments = []`) があると、この分岐自体が
false→true→false→trueと切り替わり、SwiftUIが子Viewの identity を
リセットして`CalendarInviteSectionView`を作り直す。すると
`.task`がキャンセルされ、`isLoading = true`にすら到達しないまま
`invite == nil, isLoading == false, loadErrorMessage == nil`という
「3分岐すべてfalse」の初期状態で止まる — これは`Group`が何もレンダリング
しない、つまり**カード枠ごと無言で消える**のと同じ見た目になる。これは
「添付ファイル0個」(実際の添付は隠しているので0件で正しい) の横で
カードだけが出ない実機報告と一致する。Task #61 (`if let`分岐が
`WKWebView`を再生成したバグ) と同根の構造的な問題。

### 修正: 状態をView remountから独立させる

`CalendarInviteLoader` (`apps/Otegami/Sources/Features/ThreadDetail/
CalendarInviteLoader.swift`) を新設し、ICSダウンロード/パース結果・
RSVP送信中フラグなどの状態をすべてここに移した。`@Observable`な
参照型で、`MessageView`自身の`@State`として保持する
(`MessageDetailAIFeaturesState`/`aiState`が既に確立していた「参照型の
状態保持オブジェクトはView再構築を生き延びる」パターンを流用)。
`CalendarInviteSectionView`は`loader`を受け取って表示するだけの
純粋な表示View になり、自前の`@State`も`.task`も持たない。

読み込み自体は`MessageView.load()`自身の一連の非同期処理の一部として
(`loadCalendarInviteIfNeeded`) 素の`Task { }`で起動する — SwiftUIの
`.task`修飾子と違い、素の`Task`はどのViewのライフサイクルにも紐付かない
ので、`CalendarInviteSectionView`が何度作り直されようと読み込み自体は
中断されない。`CalendarInviteLoader.load(attachment:...)`は同じ
`attachment.id`に対しては既に読み込み済み/読み込み中なら何もしない
no-op なので、`MessageView.load()`が(オフラインfallback等で)複数回
呼ばれても安全。

これにより「認識したら必ずカード枠を出す」(読込中→内容 or
エラー+再試行ボタン、`CalendarInviteSectionView`の3分岐は
`loader.state`から導出され、初期状態から`.loading`を経由するので
空の`Group`になる瞬間が無い) も同時に満たしている。エラー時は
「再試行」ボタン (`loader.retry(...)`) で同じ添付に対してもう一度
ダウンロードを試みられる。

### OSLog計装

`Logger(subsystem: "com.mtkg.otegami", category: "CalendarInvite")`を
`CalendarInviteLoader`に追加。実機のConsoleで以下を一発で確認できる:

```sh
log stream --predicate 'subsystem == "com.mtkg.otegami" && category == "CalendarInvite"'
```

- `recognize:` — マッチした添付の`contentType`/ファイル名、または
  候補なしの場合は全添付の`contentType`一覧。
- `download:` — ローカルキャッシュ済み/ダウンロード開始/完了(バイト数)/
  失敗。
- `parse:` — `ICSCalendarParser.parse`の成否、UID/METHODなど。
- `card:` — 「現在の回答」をどこから決定したか (この端末の送信記録 /
  ICSのATTENDEE PARTSTAT / 記録なし)。
- `respond:` — RSVP送信の成否。

### 応答済み表示 (ATTENDEE PARTSTAT)

`ICSCalendarParser`は元々 (Task #66時点で) `ATTENDEE`の`PARTSTAT`を
パース済みで、`CalendarInviteSectionView`(現在は`CalendarInviteLoader
.loadCurrentResponse`)もこの端末の送信記録
(`CalendarInviteResponseRecord`)を優先しつつ、無ければ招待のATTENDEE
リストから自分のアドレスを探して表示する仕組みが既にあった。今回は:

- `ICSCalendarParserTests`に`ACCEPTED`/`DECLINED`/`TENTATIVE`の
  `PARTSTAT`を明示的にパースするテストを追加 (従来は`NEEDS-ACTION`のみ
  カバー)。
- 表示文言を「現在の回答: 参加」のような曖昧な言い回しから、「承諾済み」
  「辞退済み」「未定で返答済み」という「既に返答済みであること」が
  一目でわかる文言に変更 (`CalendarInviteCardView.respondedLabel`)。
  ボタン自体の文言 (「承諾」「辞退」「未定」) は変更を促す動作なので
  そのまま。

### 検証

- `make test`緑。新規
  `CalendarInviteMIMEParsingTests`(`MailTransportMailCoreTests`、dev
  mailstack不要)、`ICSCalendarParserTests`のPARTSTAT追加分を含む。
- `make mac`のフルビルドは、この変更を含むセッション内では別要因の
  ビルド破損と同時進行だったため単体では確認できなかったが、変更した
  4ファイル (`MessageView.swift`/`CalendarInviteLoader.swift`/
  `CalendarInviteSectionView.swift`/`CalendarInviteCardView.swift`) は
  目視レビューと`make test`側のカバレッジで問題ないことを確認済み。
- シミュレータでの`scripts/verify-screen.sh calendar-invite`は既知不調
  5番目 (非同期読み込みのタイミング) の影響を受けるため未実行 — 実機での
  確認ポイントは上記「実機確認ポイント」節参照。
