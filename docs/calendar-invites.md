# カレンダー招待メール対応

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

## 既知のSwiftUIの落とし穴: optional-binding分岐にぶら下がる状態の破棄

`CalendarInviteSectionView`は当初、自分自身の`@State`
(`invite`/`isLoading`/`loadErrorMessage`)を持ち、`.task(id:)`でICS
ダウンロード+パースを行っていた。この View は`MessageView.body`の
`if let calendarInviteAttachment { ... }`という**optional-bindingの
条件分岐の中**にあり、親の`@State`書き換えのたびに`body`が再評価される
過程で対象が一時的に`nil`に戻る瞬間があると、分岐がfalse→true→falseと
切り替わってSwiftUIが子Viewのidentityをリセットし、`CalendarInviteSectionView`
ごと作り直す。すると進行中の`.task`はキャンセルされ、`isLoading = true`
にすら到達しないまま「3分岐すべてfalse」の初期状態で止まる —
`Group`が何もレンダリングしない、つまり**カード枠ごと無言で消える**のと
同じ見た目になる。

対策として、ICSダウンロード/パース結果・RSVP送信中フラグなどの状態は
`CalendarInviteLoader` (`apps/Otegami/Sources/Features/ThreadDetail/
CalendarInviteLoader.swift`、`@Observable`の参照型) に切り出し、
`MessageView`自身の`@State`として保持している。読み込みは
`MessageView.load()`の一連の非同期処理の一部として素の`Task { }`で
起動する — SwiftUIの`.task`修飾子と違い素の`Task`はどのViewの
ライフサイクルにも紐付かないため、`CalendarInviteSectionView`が
何度作り直されようと読み込み自体は中断されない。
`CalendarInviteSectionView`は`loader`を受け取って表示するだけの
純粋な表示Viewで、自前の`@State`も`.task`も持たない。

**一般化した教訓**: `if let`のようなoptional-binding条件分岐の中に
非同期処理を持つ子Viewを置くと、親の状態更新のタイミング次第で
子Viewのidentityがリセットされ、進行中のタスクが黙って消える。
非同期の読み込み状態は、条件分岐の外側 (親の`@State`として保持する
`@Observable`参照型など) に置き、View自体は表示専用にするとこの問題を
避けられる。

## スコープ外・今後の課題

- **EventKit (端末カレンダーへの追加) は対象外**。招待メールへの回答は
  iTIP REPLY の送信だけで完結する (Google カレンダー側は自動でイベントを
  作成/更新する) — 端末のカレンダーアプリに別途予定を作る/回答を反映する
  機能は別途の権限・UI設計が要るため見送っている。
- 1通のメールに複数の`VEVENT`がある場合や、繰り返しイベント
  (`RRULE`/`RECURRENCE-ID`) の個別インスタンスへの回答は未対応
  — `ICSCalendarParser`は最初の`VEVENT`だけを見る。
- `VTIMEZONE`コンポーネント自体はパースしない — `DTSTART`/`DTEND`の
  `TZID`パラメータを`TimeZone(identifier:)`で直接解決するだけ (多くの
  実際の招待メールで使われる`Asia/Tokyo`等の標準IANA名では問題ないが、
  自前定義のカスタムタイムゾーンには対応しない)。
- 既知の制限: 実際の Google カレンダー招待に対する主催者側への出欠反映、
  および招待メールの`From:`/`Reply-To:`が主催者と異なる代理送信ケース
  (会議室予約システム等) は、この開発環境 (dev mailstack) では確認できて
  いない。

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

## デバッグ手段: OSLog計装

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

`ICSCalendarParser`は`ATTENDEE`の`PARTSTAT`(`ACCEPTED`/`DECLINED`/
`TENTATIVE`/`NEEDS-ACTION`)をパースする。`CalendarInviteLoader
.loadCurrentResponse`はこの端末の送信記録
(`CalendarInviteResponseRecord`)を優先しつつ、無ければ招待のATTENDEE
リストから自分のアドレスを探して表示する。表示文言は「承諾済み」
「辞退済み」「未定で返答済み」のように、既に返答済みであることが一目で
わかる言い回しにしている (ボタン自体の文言は「承諾」「辞退」「未定」の
まま)。

### 検証

- 単体テスト: 上記「検証」節に加え、`CalendarInviteMIMEParsingTests`
  (`MailTransportMailCoreTests`、dev mailstack不要) が
  `multipart/related`を挟む深いネストや`application/ics`添付を伴わない
  `text/calendar`単体ケースなど、MIME認識のエッジケースをカバーする。
- シミュレータでの`scripts/verify-screen.sh calendar-invite`は、
  非同期読み込みのタイミングによっては待機時間内に描画が間に合わない
  ことがある ([docs/verify.md](verify.md) のシミュレータ既知不調参照。
  機能自体の不具合ではない)。
