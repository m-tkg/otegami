# オンデバイス翻訳エンジン

英文メールを Apple Foundation Models framework でオンデバイス翻訳する機能の、
エンジン層（プロトコル・実装・キャッシュ）についてのドキュメントです。UI への
組み込みは別フェーズで行うため、ここではエンジン層とその検証結果のみを扱います。
UI 設計の全体像は [`design_handoff_ios_mail/README.md`](../design_handoff_ios_mail/README.md)
（特に 1e/1i と `translationState`）を参照してください。

## アーキテクチャ

`MailTransport`/`MailTransportMailCore` の分離（プロトコルと実装を別ターゲット
にする）と同じ形を踏襲しています。

```
OtegamiTranslation              — プロトコルと純粋ロジック(Linux 可)
  ├─ TranslationService          プロトコル本体
  ├─ FakeTranslationService      決定的な実装（テスト・将来のプレビュー用）
  ├─ ParagraphSplitter           段落分割（純粋な文字列処理）
  └─ MessageLanguageDetector     言語判定（NaturalLanguage、#if canImport で分離）

OtegamiTranslationFoundationModels — 実装（Apple限定、iOS/macOS 26+）
  └─ FoundationModelsTranslationService   LanguageModelSession ベースの実装

TranslationEngine               — キャッシュと永続化のオーケストレーション
  ├─ MessageTranslator           キャッシュ確認→エンジン呼び出し→永続化
  └─ MessageTranslationState     UI 層向けの状態モデル (.none/.translating/...)

SyncEngine.BodyFetcher          — 本文取得直後に MessageLanguageDetector を実行
OtegamiStore                    — MessageTranslationRecord・message.detectedLanguage (v15)
```

呼び出し側（将来の UI 層）は常に `TranslationService` プロトコルと
`MessageTranslator` だけを見ます。`FoundationModels` を import しているのは
`OtegamiTranslationFoundationModels` の1ファイルだけです。

### なぜこの分離か

- Foundation Models framework は iOS/macOS 26 以降専用で、対応デバイスも限られ
  ます（後述）。プロトコルの背後に実装を隠すことで、非対応環境（古い OS、
  Foundation Models 非対応デバイス、Linux 上のサーバーコード）でもビルドが
  壊れません。実際、`server/otegami-relay`（Linux, `otegami-relay`
  パッケージ）は `OtegamiRelayAPI`/`OtegamiCore` だけを使うため、翻訳関連の
  ターゲットは一切ビルドグラフに入りません。
- `FakeTranslationService` により、実機のオンデバイスモデルなしでキャッシュや
  状態遷移のロジックを高速・決定的にテストできます。

### 言語判定は翻訳と別の可用性を持つ

`MessageLanguageDetector`（`NLLanguageRecognizer` ベース）は `TranslationService`
に含めていません。LLM を使わない軽量な処理であり、`NaturalLanguage` framework は
本パッケージが対象とする全ての Apple OS バージョンで利用可能（Foundation Models
のような 26+ 限定ではない）だからです。`SyncEngine.BodyFetcher` が本文取得
直後に同期的に実行し、結果を `MessageRecord.detectedLanguage`
（BCP-47、例: `"en"`/`"ja"`）に保存します。一覧のスクロール中に判定が走ること
はありません。

## Foundation Models の実 API（調査結果）

実装前に、ローカルの Xcode（この検証時点では 27 beta、iOS/macOS 26 以降を
サポート）に含まれる `FoundationModels.framework` の `.swiftinterface`
（`$SDK/System/Library/Frameworks/FoundationModels.framework/.../FoundationModels.swiftinterface`）
を直接読んで実 API を確認しました。知識だけに頼らず確認した結果は以下の通り。

- **可用性チェック**: `SystemLanguageModel.default.availability`
  （`@available(iOS 26.0, macOS 26.0, *)`、同期プロパティ）が
  `.available` か `.unavailable(UnavailableReason)` を返します。
  `UnavailableReason` は `.deviceNotEligible` / `.appleIntelligenceNotEnabled`
  / `.modelNotReady` の3種類。`isAvailable: Bool` という簡易プロパティも
  あります。`TranslationAvailability`/`TranslationUnavailableReason`
  （`OtegamiTranslation`）はこれと1:1で対応するようマッピングしています
  （`FoundationModelsTranslationService.availability` 参照）。
- **セッション**: `LanguageModelSession(model: SystemLanguageModel = .default,
  instructions: String? = nil)`（iOS/macOS 26+ で利用可能な初期化子）。
  `respond(to: String, options: GenerationOptions) async throws ->
  Response<String>`（`.content` が結果文字列）で一括取得、
  `streamResponse(to:options:) -> ResponseStream<String>`
  （`AsyncSequence`）でストリーミング取得できます。
- **ストリーミングの意味論（実機で確認）**: `streamResponse` が返す各要素は
  **それまでの翻訳全体のスナップショット**であり、差分（デルタ）ではありません。
  実際に英文を日本語に翻訳しながら18回分のスナップショットを観察したところ、
  `"そのミーティング"` → `"そのミーティングは"` → `"そのミーティングは明日"`
  → … → 完全な訳文、という形で常に「今までの全体」が返ってきました。
  `TranslationService.translateStream` のドキュメントコメントもこの意味論を
  そのまま契約にしています（呼び出し側は最新の要素を描画するだけで、連結しては
  いけません）。
- **1セッション=1リクエスト**: `LanguageModelSession` は同時に1リクエストしか
  さばけず（`LanguageModelSession.Error.concurrentRequests`）、会話履歴を
  自動的に引き継ぎます。`FoundationModelsTranslationService` は呼び出しごとに
  新しいセッションを作る設計にしています（段落ごと・呼び出しごとに独立させ、
  ある翻訳が別の翻訳の文脈に汚染されないようにするため）。
- **利用可能言語**: `SystemLanguageModel.default.supportedLanguages` は
  BCP-47 相当の `Locale.Language` の集合を返します。検証機での実測値は
  23言語（`da, de, en, es(419/ES/US), fr(CA/FR), it, ja, ko, nb, nl, pt(BR/PT),
  sv, tr, vi, zh(Hans/Hant)`）で、英語・日本語とも含まれています。
- **コンテキストサイズ**: `SystemLanguageModel.default.contextSize` の実測値は
  8192 トークン。非常に長い1段落（`ParagraphSplitter` が分割しない、改行の
  無い巨大な1ブロック）は理論上これを超えうるので「既知の制限」に記載します。

## 実機での動作確認

**実際に動きました。** シミュレータではなく、この検証を行ったマシン上で
Apple Intelligence が有効だったため、`SystemLanguageModel.default.isAvailable`
が `true` を返し、実際の翻訳を実行できました。

- `SystemLanguageModel.default.availability` → `available`
- 英→日翻訳の実例（`LanguageModelSession.respond(to:)`）:
  - 入力: `"Hi team, the quarterly report is attached. Please review it by
    Friday and send me your comments. Thanks!"`
  - 出力: `"こんにちは、チームの皆さん。四半期報告書が添付されています。
    金曜日までに確認してご意見をお送りください。ありがとうございます。"`
- ストリーミング（`streamResponse(to:)`）でも、上記の「累積スナップショット」
  として正しく段階的な訳文が得られることを確認済み。
- `OtegamiTranslationFoundationModelsTests`（`packages/OtegamiKit/Tests/OtegamiTranslationFoundationModelsTests/`）
  として、この実機確認を自動テスト化してあります。英→日・日→英・段落分割・
  ストリーミング・要約の6テストすべてが実機で green です
  （`swift test --filter FoundationModelsTranslationServiceTests`）。
  CI・他の開発機では Apple Intelligence が有効とは限らないため、
  `isFoundationModelsTranslationAvailable()` で可用性チェックし、
  非対応環境では suite ごと **スキップ**（失敗ではない）します。

### シミュレータでの Foundation Models

Foundation Models はデバイス本体のモデル資産を使うため、iOS シミュレータ上で
実行する場合もホスト Mac が Apple Intelligence 対応・有効である必要があります
（モデル自体はホスト側で推論される）。今回はホスト Mac 上で直接検証しました
（`xcrun swiftc` で単体のコマンドラインバイナリをビルドして実行、および
`swift test` 経由）。iOS アプリとして実機/シミュレータ上で動かす確認は、
UI 組み込みフェーズで `scripts/verify-*.sh` の枠組みに合わせて改めて行う想定
です。

## 可用性の条件

`SystemLanguageModel.default.availability` が `.unavailable` を返す理由は
3通りです。ユーザー向けの文言は UI フェーズで検討しますが、エンジン層としては
この3種類を区別して呼び出し側に返せるようにしてあります
（`TranslationUnavailableReason`）。

| 理由 | 内容 |
|---|---|
| `deviceNotEligible` | ハードウェアが Apple Intelligence の要件（メモリ等）を満たさない |
| `appleIntelligenceNotEnabled` | デバイスは対応しているが、設定で Apple Intelligence が OFF |
| `modelNotReady` | 対応・有効だが、オンデバイスモデルのダウンロードが未完了 |

OS バージョンは iOS/macOS 26 以降が前提（本アプリの最低対応バージョンと一致）。
対応言語は前述の23言語（英語・日本語含む）。

## キャッシュ方針

- `messageTranslation` テーブル（v15 migration）に、メッセージ1件につき最大
  1行をキャッシュします。列は `sourceLanguage`/`targetLanguage`/
  `translatedText`（全文）/`paragraphs`（段落ごとの原文・訳文ペアの JSON
  配列）/`engineIdentifier`/`translatedAt`。
- **段落単位で保持**する理由: 1i の「段落長押しでその段落だけ原文表示」を
  実現するには、段落の対応関係（どの訳文段落がどの原文段落に対応するか）が
  必要です。`ParagraphSplitter.split(_:)` で本文を段落に分割し、
  `TranslationService.translateParagraphs` で段落ごとに独立して翻訳、
  結果を1:1で `TranslatedParagraph` として保存します（段落ごとに独立した
  リクエストにしているのは、1回の応答をあとから区切り文字で再分割する方式
  より安全なため — モデルが区切り文字を改変・エコーする可能性を避けられます）。
- **モデル更新への対応**: `engineIdentifier`（例: `"foundation-models"`,
  `"fake"`）を記録し、`MessageTranslator` はキャッシュのエンジン識別子が
  現在使用中のものと一致しない場合、古いキャッシュとして無視し再翻訳します。
  Apple 側のオンデバイスモデルが将来バージョンアップされて訳文の質が変わって
  も、識別子自体は変わらないため厳密なモデルバージョン単位の無効化はしません
  （必要になった場合は `engineIdentifier` にモデルのバージョン文字列を含める
  形で拡張できます）。
- 永続化を選んだ理由: 長い本文の翻訳はオンデバイスとはいえコストがあり
  （実測で数秒〜、本文が長いほど増える）、同じメッセージを何度も開くたびに
  再翻訳するのは体感速度・電力の両面で望ましくないためです。

## 非対応環境でのフォールバック

- **Foundation Models 非対応（OS/デバイス/未有効化）**: `TranslationService
  .availability` が `.unavailable` を返すので、UI フェーズはこれを見て
  翻訳導線自体を隠す/無効化できます。エンジン層は例外を投げるのではなく
  状態として返す設計です（`MessageTranslator.translate` は失敗時も
  `.failed(message:)` を返すのみで、呼び出し側の `do`/`catch` を必須にしません）。
- **Linux（サーバーコード）**: `OtegamiTranslationFoundationModels` は
  ビルドグラフに一切入らないため、そもそもコンパイル対象になりません。
  `MessageLanguageDetector` は `#if canImport(NaturalLanguage)` で
  ファイル全体を囲んであるので、`OtegamiTranslation` ターゲット自体は
  Linux 上でも（何もしないコードとして）コンパイルが通ります。
- **テスト**: `FakeTranslationService` が決定的な代替実装として、
  ロジック（キャッシュ、状態遷移、段落整合）を実機なしで検証します。

## プライバシー上の利点

翻訳はすべてオンデバイスで完結します（`LanguageModelSession` はネットワークを
使いません）。メール本文が外部サーバーに送信されることはなく、この点は
「複数アカウント横断」と並ぶ本アプリの差別化要素として重要なセールスポイントです
— 特にメールという個人情報・機密情報を含みやすいデータに対して、翻訳のために
外部の翻訳 API/クラウド LLM にテキストを送る必要が一切ない、という設計です。

## 既知の制限

- **コンテキストサイズ (実機報告を受けて対応済み)**: オンデバイスモデルの
  コンテキストは実測 8192 トークン。実機で「翻訳が、メールによって成功
  したり失敗したりする」という報告があり、原因は長文の英文メール (段落数
  の多いニュースレターや引用の多い返信) がこの上限を超えていたこと —
  `translateParagraphs` は元々1回のエンジン呼び出しが失敗すると
  メッセージ全体の翻訳が失敗する実装だったため、長い段落が1つでもあると
  メール全体が翻訳できなくなっていた。`TranslationChunker`
  (`OtegamiTranslation`) を追加し、`MessageTranslator.translate` が
  各段落をさらに安全な長さのチャンクに事前分割してからエンジンへ渡し、
  結果をチャンク単位から段落単位へ再結合するようにした (段落境界自体は
  1i の原文/訳文対応のため変えない)。要約 (`AISummaryBar`) にも同じ
  問題があり得るため、`TranslationService.summarizeLongText` (map-reduce:
  チャンクごとに1文要約→まとめて再要約) を追加し `MessageView
  .requestSummary` から使うようにした。それでもエンジン側が
  `LanguageModelError.contextSizeExceeded` を返した場合は
  `TranslationServiceError.tooLong` として区別し、`.userFacingMessage`
  で「本文が長すぎるため処理できませんでした」という具体的な理由を
  表示する (`.failed`/`.unavailable` と合わせて「なぜ失敗したか」を
  常に区別して表示)。
- **1セッション=1リクエストのオーバーヘッド**: 段落ごとに新しい
  `LanguageModelSession` を作る設計のため、段落数が多いメールほど
  セッション初期化コストが積み重なります（実測ではモデルのウォームアップ
  自体は軽量でしたが、大量の段落を持つメールでの体感速度は未検証）。
- **要約の文数指定はヒント**: `summarize(sentenceCount:)` はプロンプトで
  指示しているだけで、モデルの出力文数を厳密に保証しません。
- **翻訳の一貫性**: `temperature: 0.3` で決定性寄りに設定していますが、
  オンデバイスモデルの出力は呼び出しごとに完全に同一とは限りません
  （`FakeTranslationService` と異なり真の意味で決定的ではない）。これが
  キャッシュを永続化するもう一つの理由です — 一度保存した訳文は再翻訳するまで
  変わりません。
- **UI 未実装 (このドキュメントを最初に書いた時点)**: design-phase-3
  で実装済み。`apps/Otegami/Sources/Features/ThreadDetail/TranslationBar.swift`/
  `TranslatedBodyView.swift` と `AppEnvironment.translationService`/
  `messageTranslator`、当時の `ComposerView` の「英語に翻訳して送る」
  トグル (どの作成画面からも手動でON/OFFできる汎用トグルだったが、後の
  表示・操作改善バッチで「英語で返信を下書き」という単一の入口に一本化
  する形で UI としては削除された — 内部の翻訳ロジック自体は残っている。
  `docs/design-system.md`「6. 「英語に翻訳して送る」の削除」節参照) が
  該当。UI 層の設計判断 (既定は訳文、自動翻訳の ON/OFF 設定、HTML メー
  ルは訳文表示時にプレーンテキスト化される、等) は
  `docs/design-system.md` の design-phase-3 節にまとめてある。

## 要約からの引用除外 (QuoteStripper)

ユーザー要望 (Task #46): 「メールの返信がたくさん繰り返されて過去の文章が
たくさんある時、そこは要約の対象外にして欲しい」。長い返信スレッドを要約
すると、新しく書かれた分だけでなく引用された過去のやり取り全体まで要約の
入力に含まれてしまい、要約の質が下がる (古い話題が混ざる、`sentenceCount`
に対して新規分の比率が薄まる) 問題への対応。

- **`QuoteStripper` (`OtegamiCore`)**: 純関数、`HTMLTextExtractor` と同じく
  Linux 互換 (WebKit/NSAttributedString 不使用)。「最初に見つかった引用
  マーカーより後ろを丸ごと落とす」という戦略 — 各メールクライアントの
  引用規約 (Gmail の `gmail_quote`/`gmail_attr` div、Apple Mail/Thunderbird
  の `<blockquote>`、Thunderbird の `moz-cite-prefix` div、Outlook の
  `divRplyFwdMsg`/`appendonsend` id、プレーンテキストの `> ` 引用行、
  「On ... wrote:」「-----Original Message-----」「〜さんは書きました」
  「差出人: .../送信日時: ...」ヘッダブロック等) は例外なく「引用がどこ
  から始まるか」を示すものであって「どこで終わるか」ではないため、
  new-then-quoted の top-posting (このアプリ自身の `ComposerView
  .quotedBody`/`forwardHeaderBlock` が生成する形もこれ) を前提に、最初の
  マーカーの手前で打ち切る。
  - `strippingQuotedText(fromHTML:)`: 上記の HTML 構造マーカーのうち最も
    早い位置で HTML 文字列を打ち切ってから `HTMLTextExtractor.plainText`
    で平文化する。
  - `strippingQuotedText(fromPlainText:)`: 上記のプレーンテキスト・
    マーカーのうち最も早い位置で文字列を打ち切る。
  - **フォールバック**: 打ち切り後の本文 (前後空白を除く) が40文字未満
    ならその除去を行わず全文を使う — 「転送だけして新規コメントなし」
    のようなメールで要約の入力が空になるのを防ぐ。
- **適用範囲は要約のみ**: `MessageView.sourceTextForSummary()` という
  専用メソッドを新設し、`requestSummary` だけがこれを経由する。
  `sourceTextForTranslation()` (翻訳と本文表示が共有) 自体は変更しない
  — 翻訳・本文表示は受信した通りの全文 (引用込み) を扱う必要があるため、
  同じ関数を要約用に書き換えるのではなく分離した。

## 要約: 引用を「文脈」として使う (Task #62)

Task #46 で上記の「引用より後ろを丸ごと落とす」対応をした後も、実機で
「まだ過去の返信などの引用の内容を要約してるっぽい。完全には無視しなく
ていいけど、そういう流れがある上で、どういうメールなのかを要約するよう
にして欲しい」というフォローアップ報告があった。引用を完全に無視するの
ではなく、返信の流れ (文脈) として使いつつ、要約の主対象は「このメール
自体が新しく書いた部分」にしたいという要望 — Task #46 のハード除去
(引用を要約入力から完全に消す) では「要約対象からは除外できるが文脈も
失われる」ため、引用を捨てずに扱う設計に変更した。

- **`QuoteStripper.SeparatedText` / `separatingQuotedText`**: 「最初に
  見つかった引用マーカーの手前で打ち切る」という Task #46 の戦略はその
  まま (マーカー一覧・フォールバック条件も同じ)、`strippingQuotedText`
  (新規部分だけを返す、後方互換のため残置) に加えて、新規部分と引用部分
  の**両方**を `SeparatedText { newText, quotedText }` として返す
  `separatingQuotedText(fromHTML:)`/`separatingQuotedText(fromPlainText:)`
  を追加。引用マーカーが見つからない、またはフォールバックが発動した
  場合は `quotedText` が空文字列になり、`newText` に全文が入る (=引用と
  分離すべきものが実際には無いケース)。
  - **パターンの追加**: 実機での漏れ調査で見つかった未対応の引用形式を
    2件追加 — HTML: Yahoo Mail の `yahoo_quoted` div、ProtonMail の
    `protonmail_quote` div。プレーンテキスト: Apple Mail (iOS/macOS) の
    日本語返信ヘッダ「2026/07/28 10:00、山田太郎のメール:」(Gmail の
    「〜さんは書きました」パターンとは異なる言い回しで、既存パターンでは
    捕捉できていなかった)。
- **`SummaryInputBuilder` (`OtegamiCore`)**: `separatingQuotedText` の
  結果を要約入力の1文字列に組み立てる純関数。`quotedText` が空なら
  `newText` をそのまま返す (Task #46 と同じ挙動)。空でなければ
  「■このメールの新規部分」「■引用されている過去のやり取り (文脈)」の
  2セクションに組み立てて返す — ラベル文字列は
  `newTextSectionLabel`/`quotedTextSectionLabel` として公開し、
  `FoundationModelsTranslationService.summarizeInstructions` の文言と
  食い違わないよう単一の情報源にしてある。
  - **引用側だけ文字数上限で切り詰め** (`quotedContextCharacterLimit`、
    デフォルト600文字): 新規部分は無制限のまま
    `TranslationService.summarizeLongText` の map-reduce に委ねる (元々
    長文メール対応のために存在する仕組み) が、引用は「文脈」であって
    要約対象そのものではないので、長い引用チェーンがモデル入力を際限
    なく膨らませないよう切り詰める。新規部分を優先し、引用側だけを削る。
- **`summarizeInstructions` の更新**: 「入力に2つのラベル付きセクション
  がある場合、引用セクションは会話の流れを理解するための文脈としてのみ
  使い、要約は新規セクションが伝えている内容について書くこと。引用の
  再要約はしないこと」という指示を追加。ラベルが無い (=引用が無い/分離
  すべきものが無い) 通常ケースはそのまま従来通り全文を要約する。
- **`MessageView.sourceTextForSummary()`**: `QuoteStripper
  .strippingQuotedText` の代わりに `separatingQuotedText` を呼び、
  `SummaryInputBuilder.build(newText:quotedText:)` で上記の構造化文字列
  (または引用なしなら `newText` そのまま) を組み立てて
  `summarizeLongText` に渡す。適用範囲は Task #46 と同じく要約のみ。

## 要約: 「引用だけの要約」再発の追加対応 (Task #90)

Task #62 の対応後も実機報告が続いた: 「まだ、要約において過去の引用のみが
要約されてたりする。引用は考慮するものの基本は引用じゃない部分を要約する
ようにして欲しい」。原因は2つに分解できる — (1) `QuoteStripper` が分離
自体に失敗し (未対応の引用マーカー形式で本文全体が「新規部分」扱いになる)
本文全体が要約対象に回ってしまうケース、(2) 分離自体は成功しても
`summarizeInstructions` の指示が弱く、モデルが新規部分が短いときに引用側
へ寄ってしまうケース。両方に対応した。

- **検出強化 (1): 返信ヘッダの手がかりを使った条件付き緩和パターン** —
  `separatingQuotedText(fromPlainText:isReply:)`/`strippingQuotedText
  (fromPlainText:isReply:)` に `isReply` パラメータを追加 (デフォルト
  `false`、既存呼び出し・テストは無変更)。`true` のときだけ
  `QuoteStripper.replyOnlyPlainTextQuoteMarkerPatterns` (「wrote:」を欠いた
  「On ... <address>」行、Sent/To/Subject ブロックを伴わない裸の
  「From: Name <address>」行、日本語の「送信者:」単独行) を有効化する。
  これらは「引用ヘッダらしき行だが確証が薄い」パターンで、返信だと確定
  していない本文にまで適用すると旅程表の「From: 東京」のような地の文を
  誤検知しうるため、呼び出し元がメッセージの `In-Reply-To` ヘッダの有無
  (`MessageView.sourceTextForSummary()` では `message?.inReplyTo != nil`)
  で「これは返信だ」と確認できた場合限定で有効化する設計にした。
  - **HTML 側にも2パターン追加** (`isReply` 非依存 — 命名クラス付きの
    `gmail_quote`/`yahoo_quoted`等と違い、そもそもクラス名を持たない
    スタイルベースの引用構造で、既存パターンにマッチする文脈が元から
    無いためリスクが低い): クラス名を持たない `border-left` スタイルのみ
    の引用 div (`borderLeftQuoteDiv`)、Outlook モバイル/新 Outlook Web が
    `<hr>` の代わりに使う `border-top` スタイル div + 直後の
    From/差出人/Sent/送信 ブロック (`borderTopFromBlock`、既存の
    `hrFromBlock` の div 版)。
  - **`SeparatedText.detectedMarker`**: どのマーカー (`"blockquote"`
    `"onWrote"` `"quoteBlockLine"` 等、パターンごとの名前) で分離が
    成立したか (成立しなければ `nil`) を新規公開。次項の診断ログのために
    追加した。
- **指示強化 (2)**: `FoundationModelsTranslationService
  .summarizeInstructions` の Task #62 時点の文言 ("use the quoted section
  only to understand the flow") はまだ柔らかい推奨止まりだったため、
  「引用セクションの内容だけを要約してはならない (must not)。要約の主対象
  は新規セクション」という禁止形の指示に強化。加えて、新規部分が「了解
  です」のような一言だけの場合に水増しや引用への逃げをせず、「このメール
  が文脈に対して何をしたか」を1-2文で述べるよう明記した (例:
  「見積もりの件を了承する返信」であって見積もり自体の再要約ではない)。
- **診断ログ**: `MessageView` に OSLog `Logger(subsystem: "com.mtkg
  .otegami", category: "SummaryInput")` (`summaryInputLogger`) を追加し、
  `sourceTextForSummary()` が呼ばれるたびに `isReply` の値、新規部分/
  引用部分それぞれの文字数、`detectedMarker` (未検出なら `"none"`) を
  1行で出す。実機で「このメールは分離できているか、できているとして
  どのパターンで検出したか」を Console.app (`log stream --predicate
  'subsystem == "com.mtkg.otegami" && category == "SummaryInput"'` 等) で
  確認できるようにするための追加 — Task #62 時点は分離結果を確認する
  手段が無く、実機報告のたびに再現条件を推測するしかなかった。

## 要約: 叙述順を時系列に揃える (Task #97)

実機報告: 「返信メールの要約で叙述順が時系列と逆になる。メールでは末尾に
過去のやり取りが引用されるが、時系列では引用の方が過去。現在の要約は
『新規本文の要約 → 後から引用に言及』の順で出力され、話が前後しておかしな
要約になる」。

Task #62/#90 は「引用を主題にしない (要約の主対象は新規部分)」という
*重み付け*は正しく直してあったが、モデルへの入力そのものが「新規部分が
先、引用 (過去の文脈) が後」という順で組み立てられており (`SummaryInputBuilder.build`)、
出力の叙述順もその入力順に引きずられていた。入力を新規→過去の順で見せて
おきながら「主題は新規部分」とだけ指示しても、モデルは素直に読んだ順に
語ってしまう — 「主題はどちらか」と「語る順序はどちらが先か」は別の軸
だったのに、#62/#90 の指示は前者しか制御していなかった。

- **`SummaryInputBuilder`**: セクションの並び順を入れ替え、**引用 (過去の
  やり取り) を先、新規部分 (今回の返信) を後**にした — メール本文の
  レイアウト (新規が上、引用が下) とは逆だが、時系列 (引用の方が古い)
  には順方向になる。ラベル文言も役割ベースに書き換え:
  - `quotedTextSectionLabel`: `"■これは過去のやり取り (文脈参照用)"`
    (旧: `"■引用されている過去のやり取り (文脈)"`)
  - `newTextSectionLabel`: `"■これが今回届いた返信 (要約対象)"`
    (旧: `"■このメールの新規部分"`)
  - 引用側の文字数上限 (`quotedContextCharacterLimit`、600文字) は
    Task #62 のまま維持。
- **`FoundationModelsTranslationService.summarizeInstructions`**: ラベル
  文言の変更に合わせて更新した上で、出力の構造を明示的に指示する一文を
  追加 — 「両方のセクションがある場合、出力もラベルの並び順ではなく時系列
  順に組み立てること: まず引用の文脈を伝える1文 (必要な場合のみ)、続けて
  今回の返信の内容を述べる。今回の返信を先に説明してから引用に後から
  言及する構成にしないこと」。Task #90 の「引用を主題にしない」「新規部分
  が短い場合は返信が何をしたかを述べる」指示はそのまま維持し、今回の追加
  指示と矛盾しないよう「主題は新規部分のまま、語順だけ引用が先」という
  形にした。
- **`MessageView.sourceTextForSummary()`**: 変更なし (doc comment のみ
  更新) — 入力順序の変更は `SummaryInputBuilder` 内で閉じており、呼び出し
  側の変更は不要だった。
- **テスト**: `SummaryInputBuilderTests` の既存アサーション (「新規部分が
  先」) を反転させ「引用が先・新規部分が後」に変更、ラベル文言の役割
  (「過去のやり取り」/「要約対象」を含むこと) を確認するテストを追加。
  `FoundationModelsTranslationService.summarizeInstructions` 自体は
  `FoundationModelsTranslationServiceTests` が実機 (Apple Intelligence
  利用可能環境) 限定のスイートで、CI では素通りする — 実際の要約出力の
  叙述順が改善したかどうかは実機確認に委ねる (このファイル上部の
  「実機での動作確認」節参照)。

## 要約: 3パート構造 ■要約/■伝えたいこと/■アクション (Task #102)

実機報告を offline の再現ランナー (スクラッチパッド上、リポジトリ外 —
実際のメール本文を Foundation Models に投げて出力を確認できる小さな
`swift run` プロジェクト) で再現確定。QuoteStripper の新規/引用分離、
Task #97 の入力時系列化はどちらも正常に効いているのに、深くネストした
返信チェーン (5段階以上の引用) に対して短い新規本文が乗っているケースで
は、3文要約のうち2文が引用側の日付・時刻つき逐次再話 (「◯月◯日 ◯時、
Xさんから『…』と返信があり、Yさんが…と伝え…」) になり、今回の返信の
内容は最後の1文に押し込められてしまっていた。

Task #97 の指示 (「引用の文脈を伝える1文 (必要な場合のみ)」) は「1文」と
は言っていたが、その1文がどれだけ長く・何通の引用メッセージをまとめて
語ってよいかを縛っていなかった — モデルは「1文」の制約を守りながらも、
読点でつないだ1つの長い文でネスト引用を全部逐次再話することで指示を
「満たして」しまっていた。

### 変更

- **`FoundationModelsTranslationService.summarizeInstructions`**: 出力を
  自由文から固定の3パート・ラベル付き構造に変更した。
  ```
  ■要約
  (内容の要約 — 今回届いた返信の内容が主。過去のやり取りへの言及は
  必要な場合のみ冒頭の従属節1つまで)

  ■伝えたいこと
  (送り主の意図・トーン、1文程度)

  ■アクション
  (受信者に求められる対応。不要なら「特になし」)
  ```
  「1文」という緩い縛りに代えて、■要約パートには「引用メッセージを
  1通ずつ逐次再話することは (何通あっても) 禁止」「日付・時刻や
  『〜さんが「…」と返信し』のような個別メッセージへの言及は禁止」という
  “何をしてはいけないか”を名指しした禁止事項を追加 — Task #97 の failure
  mode の直接の原因 (日付入り逐次再話) をピンポイントで塞いだ。Task #90 の
  「引用を主題にしない」「新規部分が短い場合は返信が何をしたかを1-2文で
  述べる」指示はそのまま維持。
  - `sentenceCount` の意味を再定義: ■要約パートの文数のみを指す
    (■伝えたいこと/■アクションは常に1文程度で、要約対象の長さに応じて
    伸び縮みしない固定長の情報のため)。呼び出し側 (`MessageView
    .requestSummary` → `TranslationService.summarizeLongText` の既定値
    `sentenceCount: 2`) は変更していない。
- **`MessageView.summarySheet`**: 表示側は `SummaryText`
  という小さな内部 `View` を新設し、`"■"`で始まる行だけ太字にする軽い
  整形を追加 (大掛かりな UI 変更はせず、既存の `.textSelection(.enabled)`
  ・アクセシビリティ識別子はそのまま維持)。ラベルの並び方はモデルが生成
  する生テキストの改行構造に委ねている — 決め打ちのパース/バリデーション
  は行わない (ラベルが省略された場合もそのまま表示されるだけで壊れない)。
- **`SummaryInputBuilder`/入力順序**: 変更なし。Task #97 の「引用が先・
  新規部分が後」の入力順は今回の症状の直接原因ではなかった (再現ランナー
  で確認済み) — 既存の `SummaryInputBuilderTests` がこの順序を引き続き
  カバーしている。

### 検証

`FoundationModelsTranslationServiceTests` は実機 (Apple Intelligence 利用
可能環境) 限定で CI では素通りするため、実際の出力確認は上記の offline
再現ランナーで行った。機微メール本文の代わりに、同じ構造 (短い新規本文 +
5段ネストの引用 + 日本語 Gmail 帰属行 `"2026年M月D日(曜) HH:MM 名前
<email>:"`) を持つ架空フィクスチャ (架空の名前・`example.com` アドレス、
社内定例ミーティングの調整という当たり障りのない内容) を作り、
`sentenceCount` 1/3/5 それぞれで確認した。

- 修正前 (実際の機微メールでの再現、内容はぼかして要約): 3文中2文が
  引用チェーンの各メッセージを日付・送信者付きで逐次再話し、今回の返信
  本体の内容 (お礼と近況の一言) は最後の1文に圧縮されていた。
- 修正後 (同じ機微メールで再実行): ■要約は今回の返信の内容 (お礼・近況・
  今後への言及) のみで、引用チェーンの逐次再話・日付言及は消えた。
  ■伝えたいことはトーン (感謝を伝えつつ関係を大切にしたい) を、■アクション
  は「特になし」(この返信は何かを求めるものではない) を正しく出力した。
- 架空フィクスチャでの確認 (`sentenceCount=1/3/5`): いずれも■要約に日付・
  逐次再話が現れず、■アクションは新規本文の依頼内容 (候補日を期限までに
  連絡してほしい) を正しく拾えた。`sentenceCount` を増やすと■要約の文数が
  伸びる一方、■伝えたいこと/■アクションはほぼ1文のまま安定していた
  (「`sentenceCount`は■要約だけを縛る」という再定義どおりの挙動)。

## 要約: 3パート構造の反復・指示文リーク再発の修正 (Task #122)

実機報告 (スクリーンショット確認済み) で、Task #102 の3パート要約に2つの
症状: (a) ■要約/■伝えたいこと/■アクションの3パートが複数回繰り返される、
(b) 正しい3パートの後ろに `summarizeInstructions` のラベル定義ブロック
(「■要約 — in about 2 short sentences, describe...」のような、ラベルと
英語の説明文を `" — "` で1行に連結した文言) がそのまま出力され、各ラベルの
回答が再掲される。

### 原因1: チャンク分割経路が3パート構造をチャンクごとに複製していた

`TranslationService.summarizeLongText` (長文メール向けの map-reduce) は、
分割した各チャンクを**構造化された** `summarize` (3パート指示つき) で
要約し、その結果を連結してから、もう一度 `summarize` に通していた。長文
メール (チャンク閾値 `TranslationChunker.defaultMaxChunkLength` == 2000字
超) では、この時点で「■要約/■伝えたいこと/■アクション」がチャンクの数
だけ既に出力に含まれており、それを**入力として**最終 `summarize` 呼び出し
に渡していた — 出力してほしい構造そのものが入力中に複数回現れる状態で
モデルを呼んでいたことになる。(a) の「3パートが複数回繰り返される」症状は
主にこの経路で発生していたと考えられる。

### 原因2: 指示文の「ラベル — 説明」形式がもっともらしい出力行に見えた

`summarizeInstructions` は各ラベルの説明を「■要約 — in about N short
sentences, describe...」のように、ラベルと説明文を `" — "` でひと続きに
した英語の1行として書いていた。これは「ラベル+同じ行の内容」という、
モデルが実際に出力すべき行の形とよく似ている — 正解の3パートを出力し
終えた後、モデルが自分の入力コンテキストに残っているこの行を「まだ出力
すべき何か」と誤認し、そのまま (あるいは劣化した形で) 継続生成してしまう
のが (b) の直接の原因と見られる。

### 変更

1. **チャンク段階を非構造化に分離**: `TranslationService` に
   `summarizePlain(_:targetLanguage:sentenceCount:)` を追加 — ■ラベルを
   一切使わない、プレーンな1文程度の要約を返すメソッド。
   `summarizeLongText` はチャンクの map 段階をこちらに切り替え、
   最終的な reduce 段階 (連結後のテキストを`summarize`に渡す) だけが
   3パート構造を要求する。チャンク数に関わらず reduce は必ず1回だけ実行
   する (以前は「チャンクが1個だけならreduceをスキップ」という分岐が
   あったが、`summarizeLongText`のチャンク閾値と`TranslationChunker`の
   `maxLength`が同じ値である以上、チャンク分割に入った時点でチャンクが
   1個だけになることは数学的に起こり得ない — 「1個の場合はスキップ」は
   到達不能なデッドコードだったと判明したため削除し、常にreduceを通す
   形に単純化した)。`FakeTranslationService`/
   `FoundationModelsTranslationService`双方に`summarizePlain`を実装。
2. **`summarizeInstructions`の構造を再編**: 「ラベル + " — " + 説明」を
   1行に連結する形をやめ、(i) ルール説明を日本語の文章で書く (出力言語と
   揃えることで、仮にリークしても言語の不一致という分かりやすい壊れ方に
   ならないよう完全には防げないが、リスクは下げた)、(ii) 出力形式を
   「3行構造のみ・ラベルは3つの文字列そのまま・説明や指示文自体や英語を
   含めない・この構造は全体で一度だけ」という命令文として、ラベル説明とは
   別の段落に独立させる、(iii) 具体的な出力例を1つ添える、の3ゾーンに
   分離した。Task #62/#90/#97/#102 由来の内容ルール (引用の逐次再話禁止・
   日付/時刻禁止・短い新規本文の扱い・従属節は冒頭1つまで) はプロセ文中に
   そのまま維持。`summarizePlain`用の非構造化バージョン
   (`summarizePlainInstructions`) も追加。
3. **出力後処理の防御パーサ `SummaryOutputSanitizer`
   (`OtegamiCore/SummaryOutputSanitizer.swift`)**: 生成された文字列から
   最初の完全な「■要約→■伝えたいこと→■アクション」ブロックだけを抽出し、
   それ以降のテキスト (2回目以降のラベル、リークした指示文断片) を切り
   落とす純粋関数。`FoundationModelsTranslationService.summarize`が
   モデルの応答を返す直前に必ず通す — 1./2.の修正で原因そのものを塞いだ
   後の、多重防御としてのバックストップ。`OtegamiTranslationFoundationModels`
   ターゲットは`OtegamiCore`への依存を明示的に追加 (従来は`OtegamiTranslation`
   経由の推移的依存にのみ頼っていた)。

### 検証

`OtegamiCoreTests/SummaryOutputSanitizerTests`(単体・8ケース: 正常系の
そのまま透過、(a)反復除去、(b)指示文リーク除去、(a)+(b)複合、ラベルと内容が
同一行のケース、ラベル欠落時のフォールバック、複数行にまたがる内容の保持)
と、`OtegamiTranslationTests/TranslationServiceSummarizeLongTextTests`
(`FakeTranslationService`の`summarizeCallCount`/`summarizePlainCallCount`
を使い、短文は`summarize`のみ1回・長文は`summarizePlain`をチャンク数分+
`summarize`を最終段で1回だけ呼ぶことを確認) を追加。`make test`緑
(既知flakeのMessageBuilderTests日本語ラウンドトリップを除く)。

実機相当の確認は、スクラッチパッドの再現ランナー (Task #102と同じ、
`FoundationModelsTranslationService`を直接呼ぶ`swift run`プロジェクト、
リポジトリ外) を`summarizeLongText`経由に更新した上で:

- 短文フィクスチャ (`mail_fixture.txt`、Task #102と同じ架空フィクスチャ、
  チャンク分割は起きない): `sentenceCount=2,3`で5回ずつ (計10回) 実行し、
  いずれも反復・リークなしの単一3パートを確認。
- 長文フィクスチャ (`mail_fixture_long.txt`、新規追加・架空、新規本文
  だけで約1,700字・引用込みの`SummaryInput`が2,373字とチャンク閾値
  2,000字を超え、`TranslationChunker.chunk`が2チャンクに分割されることを
  確認済み): `sentenceCount=2,3`で5回ずつ (計10回) 実行し、いずれも
  map-reduce経路を通った上で反復・リークなしの単一3パートを確認。

いずれの経路も出力が確率的にぶれる性質のバグだったため複数回の実行で
確認したが、全20回で症状は再発しなかった。

## バグ修正: 実機で「翻訳ボタンが出ない」「AI要約が壊れている」

実機報告を受けて調査・修正。上記の長文コンテキスト超過とは別の、翻訳・
要約 UI 側の問題。

### 1. 翻訳ボタンが英文メールでも出ない

`MessageView.isEnglishMessage`/`shouldShowTranslationBar` は元々
`message.detectedLanguage == "en"` という厳密一致だった。
`detectedLanguage` は `SyncEngine.BodyFetcher.fetchBody` が本文を**初めて**
取得した瞬間にしか設定されない (`prefetchRecent` は `bodyState ==
.notFetched` のメッセージだけが対象) ため、この項目が追加される前に
本文取得済みだったメッセージ (実機の実際の受信箱の大半) は永久に `nil`
のままになり、英文であってもバーが出なかった。

`isEnglishMessage` を「`"en"` または `nil` (未判定)」に緩和し (確信を
持って英語以外と判定されたメッセージだけ非表示のまま)、`MessageView
.backfillDetectedLanguageIfNeeded` を追加してメッセージを開いたタイミング
で (ネットワーク不要、ローカルの本文テキストから) 検出し直し、
`message.detectedLanguage` を永続化するようにした。自動翻訳
(`kickoffTranslationIfNeeded`) の方は未判定メッセージまでは広げず、
確信を持って英語と判定された場合のみ従来通り自動実行する — 「バーは
出すが、判定不能なものを黙って翻訳し始めない」という安全側の設計。

### 2. AI要約が壊れている

- **エラーメッセージが生の Swift enum ダンプだった**: `MessageView
  .requestSummary` の `catch` が `summaryState = .failed("\(error)")` と
  していたため、`TranslationServiceError` を投げた場合に
  `failed(message: "...")` のようなデバッグ表記がそのままユーザーに
  見えていた。`(error as? TranslationServiceError)?.userFacingMessage`
  を使うよう修正 (`TranslationBar`/`MessageTranslator.translate` と同じ
  経路)。
- **HTML メールの要約に HTML タグが混ざる可能性**: `sourceTextForTranslation()`
  は `bodyRecord.plainText` が空でない場合はそれをそのまま返しており、
  実在するメールの一部は `text/plain` パート自体に HTML マークアップが
  混入している (送信側の誤ラベリング) ことがある。渡す文字列がどちらの
  由来であっても必ず `HTMLTextExtractor.plainText` を通すようにし
  (通常のプレーンテキストには何もしない no-op、HTML 混入時のみ保険として
  機能する)、翻訳・要約どちらもこの一本化した経路を通るようにした。
- 長文でのエラーは上記のコンテキスト分割で対応済み。

**実機修正の確認**: シミュレータでは design-phase-3 節に記録済みの
`FoundationModels.LanguageModelError エラー -1` (サンドボックス化された
`.app` プロセスからの制限、実機/`swift test` では発生しない) が引き続き
再現するため「タグなしの日本語要約」自体は表示できなかったが、これが
逆に上記1点目のエラーメッセージ修正を実地で確認する結果になった:
`07-html-only-japanese.eml` (`text/plain` パート無し、`HTMLTextExtractor`
経由必須) を開いて「要約」をタップしたところ、`messageDetail.summaryBar
.footnote` は修正前の生の enum ダンプ (`failed(message: "...")`) ではなく
「要約に失敗しました: 操作を完了できませんでした。（FoundationModels
.LanguageModelError エラー -1）」という自然な日本語メッセージになって
いることを `app.debugDescription` で確認した — HTML からの抽出
(`sourceTextForTranslation()`) も例外を出さず完走しており、クラッシュ・
無限ローディングいずれも発生しない。

いずれも `packages/OtegamiKit` 側にユニットテストがある
(`TranslationChunkerTests`/`MessageTranslatorTests` の新規ケース)。UI
側の判定ロジック自体 (nil 緩和・バックフィル) はシミュレータの
`OtegamiM2VerificationUITests` 等、実際に英文メールを表示する既存の
検証フローで回帰確認する。

## design-phase-3: iOS Simulator の `.app` プロセスから呼んだときの既知の制限

UI 組み込み後、実機シミュレータ上で `OtegamiTranslationBarUITests`
(XCUITest) を通して実際に英文メールを翻訳させたところ、
`FoundationModelsTranslationService.translateParagraphs` の呼び出しが
**一貫して** 以下のエラーで失敗した:

```
FoundationModels.LanguageModelError error -1.
```

6回連続でリトライ (`TranslationBar` の「再試行」ボタンを毎回タップ) し
ても同じエラーで失敗し続けた — 単発の warm-up 失敗ではなく、再現性のあ
る失敗だった。

**同じホスト機・同じタイミングで、`swift test --filter
FoundationModelsTranslationServiceTests` (サンドボックス化されていない
プレーンな macOS プロセス) を実行すると、6件のテストすべてが 2〜5 秒で
正しく翻訳/要約/ストリーミングに成功した。** つまり:

- `SystemLanguageModel.default.availability` は両方の実行方式で
  `.available` を返す (`TranslationBar` の見出しが「利用できません」に
  ならず、通常の「英語 → 日本語（端末内で翻訳）」を表示していたことか
  らも確認済み) — 可用性チェック自体は誤っていない。
- `FoundationModelsTranslationService`/`MessageTranslator`/
  `TranslationBar` のコード自体に不具合はない — 呼び出しコード・プロン
  プト・オプションは両方の実行方式で完全に同一。
- 違いは **呼び出し元プロセスの種類** だけ: サンドボックス化された iOS
  Simulator の `.app` プロセス経由だと失敗し、素の macOS プロセス
  (`swift test` バイナリ) 経由だと成功する。

原因はおそらく、Apple の on-device 推論ブローカー (Simulator 上での
Foundation Models 推論は実際にはホスト Mac 側で行われる —
`docs/translation.md` 冒頭の「シミュレータでの Foundation Models」参照)
との通信が、サンドボックス化された Simulator アプリプロセスからは何ら
かの権限/セッション要件を満たせていないという、この開発機のツールチェ
ーン (Xcode 27 beta + iOS 27 beta シミュレータ) 固有の制限とみられる。
`docs/verify.md`/`docs/ci.md` がこれまでに記録してきた「この
simulator/toolchain 固有の不具合」と同じ性質のものと判断し、UI 実装側
の不具合とは切り離して記録する。

**この制限が UI に与える影響**: 翻訳バーは失敗時、赤いエラーメッセージ
と「再試行」ボタンを正しく表示する (実機スクリーンショットで確認済み
— `docs/verify.md` 参照) — フォールバック UI 自体は意図通り動作してい
る。翻訳が実際に成功した状態の画面は、この開発機のシミュレータ環境で
は確認できなかった。**実機 (Simulator ではなく実際の iPhone/iPad) での
確認、または非 beta の Xcode/シミュレータでの再確認が今後の課題として
残る** (`PENDING.md` 参照)。

## 実機フィードバック: 「勝手に翻訳しないで」「HTML はレイアウトを保って」

実機ユーザー報告2件を受けての改修 (`apps/Otegami/Sources/Features/ThreadDetail/
HTMLMessageView.swift`/`MessageView.swift`、`packages/OtegamiKit/Sources/
TranslationEngine/MessageTranslator.swift`)。

### 自動翻訳のデフォルトを OFF に変更

`TranslationSettingsStore.autoTranslateEnglishKey` の既定値を **ON → OFF**
に変更した。英文メールを開くたびに黙って翻訳が始まるのはユーザーの意図に
反する、という直接のフィードバックへの対応。翻訳バー自体 (「翻訳」ボタン)
は従来どおり英文メールに表示され、押したときだけ翻訳が走る。設定
(設定 → メールビューア → AI 機能 → 「英文を自動で翻訳」) で従来どおり
自動翻訳に戻すこともできる。

キーも `translation.autoTranslateEnglish` → `translation.autoTranslateEnglish.v2`
にリネームした。`UserDefaults.register(defaults:)` は「一度も明示的に書き
込まれていないキー」にしかフォールバック値を提供できず、旧キーは
`@AppStorage` が読んだ時点で解決済みの値 (`true`) を書き戻しうるため、
デフォルトを変えるだけでは既存ユーザーの端末で新しい既定 (`false`) が
効かない可能性があった。キーをリネームすることで、アップグレードでも
新規インストールでも確実に `false` から始まる。

### HTML メールはレイアウトを保持したまま翻訳する

以前は HTML メールを翻訳すると `TranslatedBodyView` (プレーンテキストの
段落を並べるだけのビュー) に丸ごと差し替えられ、表・画像・罫線などの
レイアウトが失われていた (このファイルの「UI 未実装」節に記載の通り、
これは design-phase-3 の時点で意図的に受け入れたトレードオフだった)。

新方式 (`HTMLTranslationController`、`HTMLMessageView.swift`):

1. WKWebView 内の DOM を JS で走査し (`allowsContentJavaScript = false`
   で無効化されているのはページ自身が埋め込むスクリプトであり、ホスト
   側 Swift からの `evaluateJavaScript` 呼び出しはこの制限を受けない —
   `HTMLDocumentBuilder.wrap(bodyHTML:)`のfit-to-width節参照)、`<script>`/
   `<style>`/`<title>` と空白のみのノードを除外して可視テキストノードを
   収集する。各ノードは `<span data-otegami-i="N" data-otegami-original="...">`
   でラップし、後続の書き戻し呼び出しから同じノードを再度指せるようにする。
2. 収集したテキスト配列を `MessageTranslator.translateHTMLTextNodes
   (messageId:texts:...)` に渡す — 既存の `translate(messageId:sourceText:...)`
   と同じキャッシュ/チャンク分割/永続化パイプラインを共有しつつ (両者は
   内部で `translateAligned` という共通の private メソッドに委譲)、
   `ParagraphSplitter` によるプローズ段落分割を経由しない (DOM ノード境界
   はプローズの段落境界と一致しないため)。
3. 翻訳結果を同じノードへ `data-otegami-translated` 属性として書き戻し、
   訳文/原文セグメントの切替は同じノードの `textContent` を
   `data-otegami-translated`/`data-otegami-original` 間で入れ替えるだけ
   — DOM 構造・画像・表・スタイルは一切変更しない。

**キャッシュの分離**: `MessageTranslationRecord` は messageId 単位で最大
1行という既存スキーマを変えていない。HTML 経路は `engineIdentifier` に
`.html-nodes` サフィックスを付けて保存する (`MessageTranslator
.htmlEngineIdentifierSuffix`) ため、同じメッセージを「常にテキストで
表示」設定/切替ボタンで両方のモードで翻訳しても、形の異なる2つの
`paragraphs` 配列が混ざることはない — 既存の `isStillValid` の
`engineIdentifier` 一致チェックをそのまま再利用しているだけで、新しい
テーブル列は追加していない。

**プレーンテキストメールは変更なし**: `TranslatedBodyView` (段落長押し
での原文表示を含む) は従来どおりプレーンテキスト本文にのみ使われる。

**シミュレータでの検証**: この開発機の Simulator では Foundation Models
自体が呼べない (前述の「design-phase-3: iOS Simulator の `.app`
プロセスから呼んだときの既知の制限」節) ため、HTML レイアウト保持翻訳の
表示経路そのものは `OTEGAMI_UITEST_FAKE_TRANSLATION=1` (launch
environment) で `FakeTranslationService` に差し替えて検証した
(`AppEnvironment.init()`、`OtegamiHTMLTranslationUITests`)。決定的な
`"[ja] ..."` 出力がレイアウトを保ったまま DOM に書き戻されることは
確認できたが、実際の Foundation Models による訳文の品質・実機での
2デバイス確認はこのフラグの対象外 (`PENDING.md` に記載)。

## 実機フィードバック: 「HTML メールの翻訳ボタンが無反応」(Task #61)

**症状**: HTML メールを開き、翻訳フローティングボタンをタップしても
何も起きない（プレーンテキストのメールは動く）。要約ボタンは影響なし
(`sourceTextForSummary()`はJSを一切経由しないため)。

**根治した握り潰し**: `HTMLTranslationController.extractTranslatableTexts()`
(DOM テキストノード収集のJS呼び出し) が何らかの理由で失敗しても、以前は
`try?` で握り潰して空配列 `[]` を返していた。`MessageView
.requestTranslation`はその空配列をそのまま `MessageTranslator
.translateHTMLTextNodes` に渡し、0段落を「翻訳」して `.translated` (成功)
状態にしていた — 結果、画面には何の変化も起きず、エラーも出ないため
「タップしても無反応」に見えていた。

**修正 (2点)**:

1. `extractTranslatableTexts()` の戻り値を `[String]` から `[String]?`
   に変更 — `nil` は「抽出そのものが失敗した」を意味し、`MessageView
   .requestTranslation`はこれを見て翻訳フローティングボタンを
   `.failed("本文の読み込みに失敗しました。もう一度お試しください。")`
   にする（空だが正常な抽出＝画像だけで文字が無いメールとは区別する）。
   `htmlTranslationController` がまだ `nil` (`HTMLMessageView.onAppear`
   がまだ発火していないごく短い窓でタップされた場合) も同様に、以前の
   無言 `return` をやめて `.failed(...)` にした。
2. 収集スクリプト自体も `return texts;` (bare な JS 配列) ではなく
   `return JSON.stringify(texts);` (プレーンな JSON 文字列) を返すよう
   変更し、Swift 側で `JSONDecoder` によりデコードする — この
   プロジェクトのツールチェーンでは `evaluateJavaScript` の戻り値
   ブリッジが **Promise 解決値**に対して壊れていることが Task #58 で
   確認済み (`HTMLWebViewCoordinator.fitToWidthScript`のdoc comment
   参照）。この抽出 IIFE 自体は Promise を経由しない同期呼び出しであり、
   壊れているのは Promise 解決値のケースだけだと Task #58 時点では
   推定されていたが、実機フィードバックが「HTML メールの翻訳だけ無反応」
   と報告している以上、複雑な値のブリッジそのものに実機依存の余地を
   完全には排除できない。すでに実証済みの「JSON 文字列として運ぶ」形
   (`readDiagScript`と同じ形) に統一しておくのは低コストな保険であり、
   ロジック自体は変えない。

**実機での検証状況**: この修正はコードレビュー（`HTMLWebViewCoordinator
.fitToWidthScript`のdoc comment、Task #58 の既知の教訓）に基づく対応で、
`make test`/`make mac`/`make ios` は緑になっているが、シミュレータでの
XCUITest による end-to-end 再現・確認は完了していない — この開発機の
シミュレータでは、翻訳フローティングボタン自体がシミュレータのシステム
言語設定 (`LocalizationSettingsStore.effectiveLanguageCode`) と
メール本文の検出言語 (`detectedLanguage`) の両方に依存して表示・非表示
が切り替わるため (英語UIでは常に非表示)、UITest 実行時の権限ダイアログ
(連絡先アクセス) や別プロセスとのシミュレータ競合と合わさって、この
セッション内では安定した再現に至らなかった。実機での再確認は
`PENDING.md` 参照。

## 実機フィードバック: ガードレール誤発動の寛容化 (Task #61)

**症状**: 無害なマーケティングメール (例: 3Dプリンタコミュニティの通知
メール) を翻訳すると、「翻訳に失敗しました: The model's safety
guardrails were triggered.」でメール全体の翻訳が失敗する。Apple
Foundation Models のガードレールは誤発動することがあり (Apple 既知の
挙動で、アプリ側で無効化する API はない)、原文には実際に問題のある
内容は含まれていない。

**修正方針**: 翻訳はチャンク (プレーンテキスト) / DOM テキストノード
(HTML) 単位で行われている — ガードレール誤発動を検知したチャンクだけ
原文のまま残して続行し、他のチャンクが1つでも翻訳できていれば全体は
成功 (`.translated`) 扱いにする。全チャンクがブロックされた場合だけ
失敗 (`.failed`) にする。

1. `TranslationServiceError` に `.contentBlocked(message:)` を新設 —
   `.failed` から独立させたのは、`MessageTranslator.translateAligned`
   がこのケースだけを「チャンク単位で原文のまま続行」の対象として
   識別できるようにするため。
2. `FoundationModelsTranslationService.mapEngineError` がガードレール
   誤発動を検知: iOS/macOS 27+ の `LanguageModelError.guardrailViolation`
   と、26+ (この非推奨だが現行の deployment target) の
   `LanguageModelSession.GenerationError.guardrailViolation` の両方を
   `.contentBlocked` にマップする。
3. `MessageTranslator.translateAligned` は以前 `service.translateParagraphs`
   への一括呼び出しでチャンク配列全体を1回のエンジン呼び出しに渡して
   いたが、これだとチャンク1つの例外が配列全体を巻き込んで失敗させて
   いた。1チャンクずつ `service.translate` を呼ぶループに変更し、
   `.contentBlocked` だけをそのチャンクの原文採用で握り潰して続行する
   (他のエラーは従来どおり全体を失敗させる)。
4. `TranslatedParagraph` に `wasBlocked: Bool` (既定 `false`) を追加 —
   `paragraphs` は既存の `.blob` 列に JSON として保存されているだけなので
   GRDB スキーマ移行は不要。`decodeIfPresent` により、この機能追加より
   前にキャッシュされた行も `false` として問題なくデコードできる。
   `MessageTranslationRecord.hasPartiallyBlockedContent`
   (=`paragraphs`のいずれかが`wasBlocked`) を UI 層が読む。
5. `TranslationFloatingButton`: 全体が `.translated` かつ
   `hasPartiallyBlockedContent` の場合、赤い失敗カプセルではなく控えめな
   グレーのカプセルで「一部の文は翻訳できませんでした」と表示する
   （スキップされた段落自体は原文のまま表示される）。

**テスト** (`MessageTranslatorTests`): `FakeTranslationService
.configureContentBlocked(for:)` で特定の入力文字列だけ
`.contentBlocked` を投げるよう設定し、(a) 3段落中1段落だけブロックされて
も残り2段落は翻訳され全体は `.translated` になること、その段落だけ
`wasBlocked == true` で原文がそのまま採用されること、
`hasPartiallyBlockedContent == true` になること、(b) 唯一の段落がブロック
された場合は `.failed` になることを確認。

## 実機フィードバック: ガードレール弾きチャンクの文単位リトライ (Task #81)

**症状**: MakerWorld のメールを翻訳すると、Task #61 のチャンク単位寛容化
のあとも「一部が翻訳されずに原文のまま残る」範囲が実機で確認されたより
広かった。原因はチャンク粒度の粗さ — `TranslationChunker` のチャンクは
複数文をまとめて1つの塊にすることがあり (`TranslationChunker
.defaultMaxChunkLength` 以下ならパラグラフ全体が1チャンク)、その塊の
どこか1文だけがガードレールを誤発動させても、Task #61 の実装はチャンク
**全体**を原文のまま残していた。同じチャンク内の無害な文まで巻き添えで
未翻訳になっていた、というのが実際の不具合。

**修正方針**: `.contentBlocked` を受けたチャンクを、そのまま原文採用する
前に**文単位**へさらに分割し、1文ずつ `service.translate` を再試行する。
本当にガードレールが反応する文だけが原文のまま残り、同じチャンク内の
無害な文は救済される。

1. `SentenceSplitter`（`OtegamiTranslation`、新規）: `.`/`!`/`?`/`。`/`．`/
   `！`/`？` 終端 (改行のみの行はそれ自体を1文として) で分割する、
   `TranslationChunker` の内部分割ロジックとほぼ同じだが独立した公開型。
   `TranslationChunker` 自身は変更していない（既存の分割挙動・テストへの
   影響を避けるため）。
2. `MessageTranslator.translateAligned` の`.contentBlocked`ハンドラを
   `retryBlockedChunkBySentence(_:sourceLanguage:targetLanguage:)` 呼び
   出しに変更: `SentenceSplitter.split(chunk)` が2文以上に分割できる場合
   だけ1文ずつ再試行し、`.contentBlocked` を受けた文だけがその文の原文を
   採用、それ以外の文は通常どおり翻訳される。1文にしか分割できない
   チャンク（Task #61 が想定していた「短い1文がまるごとブロックされた」
   ケース）は従来どおりチャンク全体の原文をそのまま採用する — **再帰は
   1段まで**で、文単位で再びブロックされてもそれ以上（単語・節単位）へは
   分割しない。
3. 「全チャンクがブロックされた場合だけ失敗」の判定も文単位に合わせて
   更新: あるチャンクが「1文も翻訳できなかった」場合だけそのチャンクを
   `.failed` 相当としてカウントし、メッセージ全体でその状態が揃った場合
   だけ `.failed` にする。1文でも翻訳できていれば、そのチャンク・段落は
   部分スキュー扱い（`wasBlocked`）で成功パスに乗る。
4. OSLog (`Logger(subsystem: "com.mtkg.otegami", category:
   "MessageTranslator")`) で、どのチャンク/文が `.contentBlocked` に
   なったか（本文そのものではなく先頭20文字のみ、プライバシー配慮）を
   記録 — ガードレールの誤発動条件は Apple 側が公開しておらず再現性が
   低いため、実機の sysdiagnose から後追いで切り分けられるようにする
   ためのログ。

**テスト**: `SentenceSplitterTests`（ASCII/日本語終端・改行のみ・
終端なし1文・空白トリム・空入力）、`MessageTranslatorTests` に3件追加
— (a) チャンクがブロックされても文単位再試行でほとんどの文が翻訳される
こと（ブロックされた1文だけ原文のまま）、(b) 文単位再試行後も全ての文が
ブロックされたままの場合はその段落が原文のまま `wasBlocked` になり、
かつ他の段落は正常に成功すること、(c) ガードレールに触れない通常の
複数文チャンクはチャンク単位1回のエンジン呼び出しのままで、文単位
リトライの経路が余計に走らないこと（非退行）。

## テスト

- `OtegamiTranslationTests`: `FakeTranslationService` の状態遷移、
  `ParagraphSplitter`（空行分割・空白トリム・空入力等）、
  `MessageLanguageDetector`（英文/和文/混在/短文/記号のみ）、
  `TranslationChunker`（上限内はそのまま・文境界優先分割・句読点の無い
  長文の強制分割・日本語の句点対応）、`SentenceSplitter`（ASCII/日本語
  終端・改行のみ・終端なし1文・空白トリム・空入力、上記 Task #81 節参照）。
- `TranslationEngineTests`: `MessageTranslator` のキャッシュヒット/ミス、
  エンジン識別子が変わった場合の再翻訳、失敗時の状態、`invalidate()`、
  上限を超える段落がチャンク分割されたうえで1つの `TranslatedParagraph`
  に再結合されること、ガードレール誤発動チャンクの寛容化 (部分スキップ
  成功・全滅時失敗、上記「ガードレール誤発動の寛容化」節参照)、ブロック
  されたチャンクの文単位リトライ (部分救済・全滅時の原文維持・非退行、
  上記「ガードレール弾きチャンクの文単位リトライ」節参照)。
- `OtegamiTranslationFoundationModelsTests`: 実機のオンデバイスモデルに対する
  結合テスト（可用性に応じて自動スキップ）。
- `SyncEngineTests`（`BodyFetcherTests`）: 本文取得時に
  `message.detectedLanguage` が正しく設定されることの検証。
- `OtegamiStoreTests`（`AppDatabaseTests`）: v15 migration
  （`messageTranslation` テーブル・`message.detectedLanguage` 列）の
  マイグレーション成否とレコードのラウンドトリップ。

いずれも `make test` に含まれます。
