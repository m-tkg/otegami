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

## 実機フィードバック: 英語メールなのに翻訳ボタンが押せない (Task #128)

**症状**: 明らかに英語の通知メール (実例: Okta のサインオン通知。実アドレス
入りのため `.eml` はコミットせず、匿名化フィクスチャで再現) を開いても
翻訳バー/ボタンが一切表示されない。事前調査でそのメールの本文を
`MessageLanguageDetector.detect` に直接かけると `en` (信頼度 0.96) と
正常に判定されており、判定エンジン自体は壊れていない — にもかかわらず
アプリ上ではボタンが出ないという食い違いだった。

`MessageView.syncAIFeaturesState()` の翻訳ボタン表示条件
(`bodyRecord != nil && shouldShowTranslationBar && htmlControllerReadyIfNeeded`)
には3つの独立した条件があり、修正前はどれが false になっているのか
ログから判別する手段が無かった。疑い順に2つの仮説を立てて対応した:

1. **仮説(1) — HTML 表示中の `htmlTranslationController` 未接続の恒久化**
   (Task #61/#64 で塞いだはずの穴の再発、あるいはこの種の HTML での
   接続失敗): `htmlControllerReadyIfNeeded` は「HTML メッセージを HTML
   表示中で、かつ `htmlTranslationController` が接続済み」でない限り
   ボタン自体を隠していた。接続が何らかの理由で恒久的に失敗する HTML が
   あれば、ボタンは永久に出ない — しかもエラー表示すら無い「無反応」に
   見える。
2. **仮説(2) — 保存済み `detectedLanguage` が不正な非 `nil` 値のまま固定化**
   `backfillDetectedLanguageIfNeeded` は `detectedLanguage == nil` の
   ときだけ再判定していた。旧ビルドが (今の `resolvePlainText` 相当の
   クリーンな抽出を経ない、HTML/CSS混じりのサンプルなどから) 誤った
   非`nil`値を一度でも保存していれば、その値は「確定した非英語判定」と
   区別できず永久に固定化する。

いずれも実機の Console ログでしか最終的な切り分けはできない (このセッション
では実 `.eml` を再現に使えなかった) ため、両方を防御的に修正した:

### 変更

1. **計装**: `MessageView.translationGateLogger`
   (`Logger(subsystem: "com.mtkg.otegami", category: "TranslationGate")`)
   を追加し、`syncAIFeaturesState()` が毎回、3条件の評価値
   (`hasBody`/`shouldShowTranslationBar`/`htmlControllerReadyIfNeeded`/
   `showsTranslationButton`) と、それらの入力
   (`detectedLanguage`/`isHTMLMessage`/`isShowingHTML`/
   `htmlTranslationControllerConnected`) を `.debug` で記録するようにした。
   `log stream --predicate 'category == "TranslationGate"'` で「ボタンが
   出ない」報告を即座に切り分けられる。
2. **仮説(1)の対応 — HTML controller 不通時はテキスト翻訳へフォールバック**:
   `showsTranslationButton` はもう `htmlControllerReadyIfNeeded` を条件に
   含めない (`hasBody && shouldShowTranslationBar` のみ、要約ボタンと同じ
   粒度) — 本文の読み込みが終わり次第、翻訳可能なら常にボタンを出す。
   代わりに `requestTranslation(message:)` 側で、HTML表示中なのに
   `htmlTranslationController` が `nil` (未接続) だった場合、
   従来のように固定の失敗メッセージを出すのではなく
   `sourceTextForTranslation()` (WKWebView に依存しない、`bodyRecord.html`
   を `HTMLTextExtractor` で平文化する経路 — プレーンテキスト翻訳と共通)
   へフォールバックするようにした。レイアウト保持翻訳 (1i) は諦めるが、
   「翻訳そのものができない」よりはるかにまし、という判断。`extractTranslatableTexts()`
   自体の失敗 (接続済みの WebView 上での DOM 抽出失敗) は引き続き
   ユーザー可視の失敗として扱う — 「未接続」と「接続済みだが抽出失敗」は
   異なる異常であり、後者まで黙ってフォールバックするのはやり過ぎと判断
   したため区別している。
3. **仮説(2)の対応 — 再判定を非`nil`値にも拡張**:
   `backfillDetectedLanguageIfNeeded` はもう `detectedLanguage == nil` を
   厳密な前提にしない — 毎回本文から再判定し、結果が**保存値と食い違う
   場合だけ**上書きする。再判定が失敗した (サンプルが取れない、または
   `NLLanguageRecognizer` が確信を持てない) 場合は既存値を保持する
   フェイルセーフは維持。保存値と再判定結果が一致する (圧倒的多数派の)
   場合は DB 書き込み自体が発生しないので、「毎回再判定する」ことによる
   実質的なコストは開いた瞬間の `NLLanguageRecognizer` 呼び出し1回分のみ。

### 検証

匿名化フィクスチャ (`AppEnvironment.uitestFakeHTMLMessageBodySSONotice`
— 架空ブランド名のみの SSO 通知メール、実データは一切含まない) を
`uitestFakeHTMLMessages` に追加し、`detectedLanguage: "fr"` という
意図的に誤った値付きで挿入できるようにした
(`AppEnvironment.UITestFakeHTMLMessage.detectedLanguage`)。
`OtegamiHTMLTranslationUITests
.testEnglishMessageWithStaleWrongDetectedLanguageStillShowsTranslateButton`
が `OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX` の tap-free 直接遷移経路
(Task #56 と同じ) でこのメッセージを開き、保存値が不正なまま始まっても
最終的に翻訳ボタンが表示されることを確認する — 上記「仮説(2)の対応」の
end-to-end 再現。`make ios`/UITest ビルドは green。実機/シミュレータでの
このテスト自体の実行結果は `docs/verify.md` の既知不調 (2) (XCUITest の
タップ/要素検出不達) の影響を受けうるため未確定 — `PENDING.md` に記載。

## 要約品質: 指示チューニング (Task #132)

**症状**: `#122` の構造修正 (3行構造の反復・指示文リークの防止) 後も、
実データ検証 (再現手順: `scratchpad/summary-repro`、
`SUMMARY_REPRO_MAIL=yoyaku_padded.txt swift run` — フィクスチャ自体が
機微データのためコミット不可) で3つの残存課題が見つかった:

(a) 確率的 (実測で概ね3〜5回に1回) に■要約へ引用パートの話題が混入する
(引用パートにしか出てこない固有名詞・依頼内容などが、新規本文の内容
であるかのように紛れ込む)。
(b) 新規本文の具体的内容が「感謝を伝える返信です」のように平板化し、
何について感謝しているか・何を楽しみにしているかといった具体が消える
(ユーザー体感「一番上の本文が要約に入ってこない」)。
(c) 「ささきさんから…の返信」のように、新規本文冒頭の宛名 (相手への
呼びかけ) を送信者名と取り違えるなど、差出人・宛先を誤って主語に据える。

### 変更

`summarizeInstructions` (`FoundationModelsTranslationService.swift`、
■要約/■伝えたいこと/■アクションの3部構造を要求する側、通常の短文入力と
`summarizeLongText` map-reduce の reduce 側の両方が使う) に3点追加:

1. **具体性・網羅性 (b)**: ■要約パートの冒頭に「新規本文に実際に書かれて
   いる事柄を、書かれている順に漏れなく説明してください。一般化しすぎ
   ないでください」という指示と、「何について感謝しているか」等の具体例
   を追加。
2. **差出人・宛先の主語化禁止 (c)**: 新しい【差出人・宛先について】節を
   追加し、「〜さんから」「〜さんへの返信」「〜さん宛て」「〜さんは」
   「〜さんが」のように名前(敬称の有無を問わず)を主語・行為者にする
   言い回しを全パート共通で禁止し、常に「この返信」を主語にするよう
   指示。新規本文の冒頭の宛名(相手への呼びかけ)がそのまま名前として
   本文中に現れるケースが実際の失敗パターンだったため、「新規本文中に
   明記されている場合であっても」禁止する、とまで明記した。
3. **引用パートとの混同禁止 (a)**: 新しい【引用パートの内容を新規本文の
   内容と混同しない(重要)】節を追加し、引用パートにしか登場しない話題・
   固有名詞は新規本文自身が同じ話題に明示的に触れていない限り■要約に
   含めないことを明示。「判断に迷ったら、その語が新規本文の文字列その
   ものに含まれているかどうかで機械的に判定する」という具体的な判定
   基準まで指示した — 曖昧な「引用に頼りすぎない」だけでは実測で
   3〜5回に1回程度、話題が混入した。

追加で、`summarizeLongText`(長文の map-reduce 経路)専用の
`summarizePlainInstructions`にも同じ「差出人・宛先を主語にしない」規則
と、**新規に発見した第4の問題**への対処を追加:

4. **ラベル見出し自体の出力への混入**: `summarizeLongText`は
   `SummaryInputBuilder.build(...)`が組み立てた「■これは過去のやり取り
   (文脈参照用):」/「■これが今回届いた返信 (要約対象):」というラベル
   付き入力を`TranslationChunker.chunk(_:)`でそのまま分割する — チャンク
   境界がラベル行の直後に来ると、そのチャンクを渡された`summarizePlain`
   (ラベルなし指示) がラベル行自体を「保持すべき内容」と誤解して出力に
   書き写してしまうことがあり、それが最終`summarize`呼び出しの入力を
   汚染して「■要約」の代わりに「■これが今回届いた返信 (要約対象)」を
   出力してしまう、という#122と同系統だが1段手前で起きる構造漏れが実測
   で見つかった。`SummaryInputBuilder`の公開定数
   (`newTextSectionLabel`/`quotedTextSectionLabel`)を直接指示文に埋め込み、
   「この見出し行自体を出力に含めないでください」と明示することで解消。
   `summarizeInstructions`側の【出力形式】節にも同じ禁止を追記(defense-
   in-depth)。

### 検証

`scratchpad/summary-repro`(swift run 実行可能ツール、`SUMMARY_REPRO_MAIL`
で対象ファイルを切替) で以下を各5回以上実行し、いずれも(a)(b)(c)の再発
なしを確認:

- `yoyaku_padded.txt`(機微、コミット不可・実際の報告元): 8回実行し、
  8回とも引用パート("メイドバニー"等)の混入なし、差出人/宛先の主語化
  なし、"ぬるぬる"/"マンダロリアン"等の具体的内容を保った要約。
- `mail_fixture.txt`(架空フィクスチャ、短文・チャンク分割なしの経路):
  5回実行し、5回とも「佐藤さんは」のような主語化なし、引用パートのみの
  話題("新しい進行フォーマット"等)の混入なし。
- `mail_fixture_long.txt`(架空フィクスチャ、`summarizeLongText`の
  map-reduce 経路を実際に踏む長文): 5回実行し、5回とも上記4のラベル
  混入は解消。**既知の残課題**: 新規本文自身が文字通り「佐藤さんのご
  都合に合わせます」と書いている場合、■アクションパートがその内容を
  (「〜さんは」のような主語化ではなく「〜さんの都合に合わせ」という
  目的語的な言及として)保持することがある — これは(c)が対象とする
  「主語の誤推測」ではなく、新規本文に実際に書かれている具体的内容を
  保持しようとする(b)の指示と自然に両立する挙動と判断し、許容している
  (詳細は`FoundationModelsTranslationService.summarizePlainInstructions`
  の Task #132 follow-up doc comment参照)。

`#122`が固定した制約(3行構造がちょうど1回だけ出現・ラベルの反復なし)
は全実行を通じて崩れていない。`OtegamiTranslationFoundationModelsTests`
(実機上のオンデバイスモデルに対する結合テスト)も green。

## 要約品質: 引用本文をモデルに渡すのをやめる根治 (Task #134)

**症状**: `#132` の指示チューニング後も、実機 (`scratchpad/yoyaku.eml` —
機微、コミット禁止) で「気をつけて帰ってね」(新規本文の最後の行) 以降の
過去のやり取りが要約に混入する症状が継続した。調査の結果:

- 実機の `bodyRecord.plainText` は text/plain パートの内容そのものでは
  なく mailcore2 の `plainTextBodyRendering()` (HTML優先タグ剥がし) 経由
  になっており、`MailCoreIMAPSession+Mapping.swift:341` (旧実装) がこれを
  常に使っていた。この合成レンダリングの形状は `QuoteStripper` の引用
  マーカー検出と確実には一致しない疑いがあった (Task #134 の item 2、
  下記「plainText 経路の修正」参照)。
- `#132` 後の a43c07e で仕込んだ `TranslationGate`/`SummaryInput` の
  診断ログが `.debug` レベルのままで、実機の `log collect` アーカイブに
  残らず (`docs/verify.md` の新しい注記参照)、切り分けに使えなかった
  (`#105`/`#122` と同じ罠を3度目に踏んだ)。

**根治方針の転換**: `#62`〜`#132` は一貫して「引用部分の *内容* をどう
モデルに提示するか」(ラベル付け・文字数上限・時系列順・語彙禁止) を
チューニングし続けたが、実機での再発が示すのは「モデルに引用の内容を
見せている限り、何らかの確率でそこから何かを拾ってしまう」という
より根本的な問題だった。Task #134 では発想を変え、**引用の内容を一切
モデルに渡さない**構造的な修正にした:

- `SummaryInputBuilder.build` は `quotedText: String` の代わりに
  `hasQuotedContext: Bool` を受け取るようになり、引用が存在する場合でも
  固定のメタ1行 `(この返信は過去のやり取りへの返信。引用本文は省略
  している)` を新規本文の前に置くだけになった。実際の引用テキストは
  `MessageView.sourceTextForSummary()` からモデル入力へ一切渡らない。
- `FoundationModelsTranslationService.summarizeInstructions` /
  `summarizePlainInstructions` をこの新前提で整理。`#97` の時系列
  並び替え規則は不要になった (2つ目のコンテンツセクションが無いため)。
  `#132` の「引用の話題を借りない」規則は「新規本文に無い内容を補わ
  ない」規則へ一般化。

**再現用の回帰追加**: `mail_fixture_long.txt` は新規本文単体で1700字超
となるよう作られていたが、引用部分 (最大600字) を入力から取り除いた
結果、`TranslationChunker.defaultMaxChunkLength` (2000字) を単体では
超えなくなり、`summarizeLongText` の map-reduce (チャンク分割) 経路を
踏まなくなった。チャンク経路も引き続き検証できるよう、新規本文をさらに
パディングした `mail_fixture_long_padded.txt` を追加した
(`SummaryInput` が2000字をわずかに超えるよう調整、`TranslationChunker
.chunk(input).count == 2`)。

**実装中に見つけた回帰とその場での修正**: 当初案は `#97`/`#102` の
「引用への返信である旨を示す短い従属節を冒頭に一つだけ置いてよい」
規則を、内容ではなくメタ情報 (`quotedContextNoteLine`) 由来に再スコープ
して残し、例示フレーズとして「過去のやり取りへの返信として、」を
指示文に含めていた。`mail_fixture_long_padded.txt` (チャンク経路) を
実FMで3回実行したところ、3回とも ■要約 の内容が「過去のやり取りへの
返信として、」で始まりながら **■要約 ラベル行そのものが省略される**
崩れた出力になることを確認した — `summarizeLongText` の reduce 段階の
実際の入力 (`combined`、`summarizePlain` の部分要約を連結したもの) を
デバッグ出力で確認したところ、`combined` 自体には過去のやり取りへの
言及は一切含まれておらず、モデルが指示文中の例示フレーズをそのまま
無条件の枕詞として採用していたと判断した (`#122` が既に名付けた
「指示文中の出力に見える文言がそのまま出力に紛れ込む」失敗の一種)。
この許可を完全に撤廃し、「■要約は前置きの一文を書かず新規本文の内容
から直接書き始める」よう明示的に禁止する一文に置き換えたところ、
同フィクスチャで3回連続グリーンになった (`FoundationModelsTranslationService
.summarizeInstructions` の Task #134 doc comment参照)。

### 検証

`scratchpad/summary-repro` (`SUMMARY_REPRO_MAIL` で対象ファイルを切替)
で以下を各3回以上実行し、いずれも「引用混入ゼロ」「■要約が新規本文の
具体を保つ」「3行構造がちょうど1回」を確認 (実FM、修正後の最終版):

- `mail_fixture.txt` (架空、非チャンク経路): 3回実行、3回とも引用混入
  なし・「資料」「候補日を2〜3つ」「来週水曜」等の具体を保持。
- `mail_fixture_long.txt` (架空、この修正で非チャンク経路化):
  1回実行 (回帰なしの確認目的)、引用混入なし・具体を保持。
- `mail_fixture_long_padded.txt` (架空、新規追加、チャンク経路):
  4回実行 (指示文修正前1回で不具合発見、修正後3回連続グリーン)、
  ■要約ラベル欠落の再発なし・具体を保持。
- `yoyaku_padded.txt` (機微、実際の報告元、plain想定): 3回実行、3回とも
  引用混入なし (`SummaryInput` が149字のメタ1行+新規本文のみになった
  ことを確認済み)・新規本文の具体的な感情表現を保持。
- `yoyaku_htmlderived.txt` (機微、HTML剥がし近似): 3回実行、3回とも
  同様に引用混入なし・具体を保持。`QuoteStripper` の引用マーカー検出
  もこの近似形状で引き続き機能 (`detectedMarker=japaneseSaidWroteAddressEnd`)
  することを確認。

`OtegamiTranslationFoundationModelsTests` (実機オンデバイスモデルへの
結合テスト) も green。`make test`/`make mac`/`make ios` すべて green。

**既知の残課題 (Task #134 の対象外、観測のみ)**: `mail_fixture.txt` の
実行で、新規本文の宛名 (「佐藤さん」) が ■要約 の主語として誤って
採用される (「佐藤さんから…依頼がありました」) ケースを複数回のうち
数回observed — `#132` (c) が対象とした「差出人/宛先の誤った主語化」と
同系統の問題で、`#134` はこれを対象にしていない (残存する既存の
【差出人・宛先について】規則はそのまま維持)。

## 翻訳ボタンの常時有効化・要約/引用カードのキャッシュ救済 (Task #138)

**(1) 翻訳ボタン: 言語判定を廃止し常時有効に (ユーザー指示による仕様
変更)**: `#134`までは`MessageView.shouldShowTranslationBar`が
`message.detectedLanguage`(「英語メールらしいか」、`isEnglishMessage`と
いう別プロパティ)と`LocalizationSettingsStore.effectiveLanguageCode`
(「アプリの表示言語」)の両方を条件にしていた。design-phase-3 以降 `#90`/
`#128`と繰り返し「英語メールなのに翻訳ボタンが出ない/押せない」実機報告が
続いた根本原因が言語判定そのものの信頼性だったため、この判定を表示条件
から完全に撤去した。今は`aiFeaturesEnabled && bodyRecord != nil`
(`syncAIFeaturesState()`の`hasBody`)だけがゲートで、言語に関係なく常に
押せる。`isEnglishMessage`プロパティ自体も削除済み。実際の翻訳は英語→
日本語の一方向専用のまま (`requestTranslation`) — 日本語メールで押しても
実質無意味な結果にはなるが、「ボタンが出ない/押せない」という誤診断の
可能性を完全に潰すことを優先した。自動翻訳の起動条件
(`kickoffTranslationIfNeeded`の「`detectedLanguage == "en"`確信のみ」
ガード)は誤爆防止として意図的に維持している — 変更されるのは*ボタンの
表示/有効*条件だけ。`#128`の HTML controller 未接続時のプレーンテキスト
翻訳フォールバックはそのまま維持。

**(2) 要約/引用カード: キャッシュ済み本文の分離フォールバック**: 実機の
予約メールで`SummaryInput`ログが`source=plain, quotedTextLength=0,
detectedMarker=none`(分離できず全文がそのまま要約対象になり、引用だらけ
の要約になる)を記録した。原因は`#134`より前にキャッシュされた行の
`MessageBodyRecord.plainText`で、mailcore2の`plainTextBodyRendering()`
(HTML優先タグ剥がし)由来の合成テキストが`QuoteStripper`の引用マーカー
検出パターンと確実には一致しない形をしていたこと (`#134`のdoc comment
参照。`#134`自身は「次回フェッチ時から新しい経路に切り替わる」設計で、
既存キャッシュの移行はしない方針だった)。一方`MessageBodyRecord.html`は
常に`MCOMessageParser.htmlBodyRendering()`由来で、この問題の影響を受け
ない — ランタイム側の救済策として、`plainText`側でマーカーが見つからな
かった時だけ`html`側でも試すフォールバックを追加した:

- `QuoteStripper.separatingQuotedText(plainText:html:isReply:)`(新規):
  `plainText`を先に試し、マーカーが見つからなければ`html`
  (`separatingQuotedText(fromHTML:)`)でも試し、見つかった方を採用する。
  `MessageView.sourceTextForSummary()`が使う。
- `QuoteStripper.separatingQuotedHTML(html:plainText:isReply:)`(新規):
  `MessageView.htmlQuoteHistorySplit`(`#133`、引用折りたたみカード)が
  使う対になる関数だが、*あえて`html`を先に試す*順序にしている —
  `html`側の構造的マーカー(`blockquote`/`gmail_quote`など)が見つかれば
  タグ保持の`newHTML`/`quotedHTML`で`WKWebView`をそのまま短縮表示できる
  唯一の経路になるため、`plainText`優先にすると健全な(`#134`以降に取得
  された)ふつうのメッセージでもこの短縮を毎回捨てる回帰になってしまう。
  `html`側が失敗した時だけ`plainText`のマーカーへフォールバックし、
  `newHTML`は元の`html`をそのまま(分割せず)使う — 表示は短縮できないが、
  折りたたみカード自体は`plainText`分割の`quotedText`で出せる。

どちらも`packages/OtegamiKit/Sources/OtegamiCore/QuoteStripper.swift`に
実装、`QuoteStripperTests.swift`に「plain分離不能・html分離可能」
「html分離不能・plain分離可能」「両方失敗」の各ケースをユニットテスト
追加。実機の`yoyaku_htmlderived.txt`相当データでの再検証は本タスクの
セッションでは未実施 (機微フィクスチャが手元に無いため) — 実機確認
ポイントとして引き続き要注意。

**(3) 追加報告: 要約ボタンが押せないメールがある**: `syncAIFeaturesState()`
の`showsSummaryButton`ゲートは元々`bodyRecord != nil && aiFeaturesEnabled`
だった — 本文取得が失敗する (`load()`の`catch`分岐、`bodyRecord`は`nil`
のまま`errorMessage`が立つ) と、このメソッドはその後二度と呼ばれず、
ボタンは永久に非表示のまま固定される構造だった (`#64`のdoc comment参照)。
`(1)`の常時有効化と対称の方針で、`bodyRecord != nil || errorMessage !=
nil`(「読み込み試行が完了した」)をゲートに変え、取得失敗後もボタン自体
は出すようにした。タップされた時点でまだ`bodyRecord`が無ければ
`requestSummary`が本文取得を一度だけ再試行 (`retryBodyFetchForSummary`)
してから要約へ進み、それでも失敗すればエラー表示にフォールバックする。
切り分け用に`TranslationGate`と対になる`SummaryGate`ログ
(`syncAIFeaturesState()`ごとの`hasBody`/`hasError`/`showsSummaryButton`)
も追加した。

## 「詳しく要約」: 再生成のプルダウン化と詳細版サマリー (Task #148)

**要望**: AI要約シートの「再生成」ボタンを、通常の再生成に加えて
「詳しく要約」(■要約パートを約10文相当に増やす) も選べる`Menu`にしたい。
3パート構造 (Task #102)・引用排除 (Task #134) は両モードで維持する。
モード自体は保持しない — シートを開き直す/次に「再生成」する際は常に
既定 (通常) から始まる。

### 変更

- `MessageView.summarySheet`のツールバー右上を`Button("再生成")`から
  `Menu`化。中身は「再生成」(`requestSummary(message:)`、既定の
  `sentenceCount`はこれまでと同じ2) と「詳しく要約」
  (`requestSummary(message:detailed:true)`、`sentenceCount`は10) の2択。
  アクセシビリティ識別子は`messageDetail.summarySheet.regenerateMenu`
  (Menu自体)・`...regenerateButton`(既存、再生成)・
  `...regenerateDetailedButton`(新規、詳しく要約)。
- `FoundationModelsTranslationService.summarizeInstructions`の■要約
  パートの分量指示 (`summaryLengthGuidance(sentenceCount:)`) を分岐:
  `sentenceCount >= detailedSentenceCountThreshold`(6) のときは「目安
  として約N文程度の分量で…詳しく説明してください。内容の区切りが
  自然な場合は、時系列に沿って段落分けしてもかまいません(空行区切り)。
  ただし段落を分けることを理由に新規本文に無い内容を水増ししては
  いけません」という詳細版向けの文言に切り替える。素の「約10文程度で」
  という指示のままだと、そもそも新規本文の分量に対して不自然に長い
  要求になったり、1つの塊に無理やり詰め込もうとして読みにくくなったり
  する懸念があったため、「段落分けしてよい (必須ではない)」という
  逃げ道と、「水増し禁止」という既存ルール (`#132`(b)由来) の再強調を
  セットにした。通常 (`sentenceCount < 6`、既定2) の文言は変更なし。

### 実装中に見つけた回帰とその場での修正: `SummaryOutputSanitizer`の
### 新しい漏れパターン

`scratchpad/summary-repro`の`mail_fixture_long.txt`(架空フィクスチャ、
非チャンク経路) を`SUMMARY_REPRO_SENTENCE_COUNTS=10`で実FM実行した際、
■要約と■アクションの間に**本来無いはずの2つ目の「■伝えたいこと」
ラベルが挟まる**出力を観測した — Task #122の`SummaryOutputSanitizer`は
「完全な3パートブロックの*後ろ*に反復/リークが続く」パターン (a)(b) は
防いでいたが、このケースはパーツの*間*に割り込む反復という新しい形で、
既存実装の`content(label:...)`が「次に見つかる*必須*ラベル行の直前まで
全部」を内容として拾ってしまうため、割り込んだ2つ目のラベルとその内容
がまるごと1つ目の「■伝えたいこと」の内容に混入していた。

`actionContentEnd`(既存、■アクションの後続をトリムする箇所) がすでに
使っていた「次に現れる*任意の*■始まり行までを内容境界とする」という
探索を、■要約・■伝えたいことの内容境界にも同じ方針で適用する形で修正
(`SummaryOutputSanitizer.swift`)。壊れていない通常の出力では「次の
任意の■始まり行」がそのまま「次の必須ラベル行」と一致するため、既存の
挙動は変えていない。回帰テスト
(`SummaryOutputSanitizerTests.dropsRepeatedLabelBetweenRealParts`)
をこの実FM repro を模した形で追加。

### 検証

`scratchpad/summary-repro`(`SUMMARY_REPRO_MAIL`/`SUMMARY_REPRO_SENTENCE_COUNTS`
を切り替えて実FMで実行) で以下を確認:

- `mail_fixture.txt`(架空、短文・非チャンク経路): `sentenceCount=2,10`を
  同一実行で比較。`2`は変更前と同じ簡潔な要約。`10`は■要約が複数行に
  分かれ、新規本文の具体的な内容 (資料の分かりやすさ、開催形式の確認、
  候補日の依頼) をより多く保持しつつ、無い内容の水増しは無し (短い
  新規本文に対して不自然に間延びしない)。3回実行、3回ともラベル反復・
  引用混入なし。
- `mail_fixture_long.txt`(架空、長文・非チャンク経路、
  `SummaryInput`が1762字でチャンク閾値2000字未満): `sentenceCount=10`を
  3回実行。**サニタイザ修正前の1回目でラベル反復 (■伝えたいこと重複)
  を検出**、上記修正後の3回 (再修正後の1回含め計3回) はいずれもラベル
  反復なし・■要約が新規本文のほぼ全項目 (背景・提案骨子3本・
  スケジュール・予算・体制・リスク・セキュリティ・テスト計画・
  サポート体制・コスト) を漏れなく列挙する詳細な内容になることを確認。
- `mail_fixture_long_padded.txt`(架空、`TranslationChunker.chunk(input)
  .count == 2`のmap-reduce経路): `sentenceCount=10`を1回実行、3行構造
  ちょうど1回・引用混入なし・ラベル反復なしを確認。map-reduce経路では
  reduce段階の入力 (`combined`、各チャンクを`summarizePlain`で1文へ
  圧縮したもの) 自体が短いため、■要約の詳しさは非チャンク経路ほど
  伸びない — 既存のmap-reduceアーキテクチャの制約であり、Task #148が
  新たに悪化させたものではない (通常の`sentenceCount=2`でも同じ制約を
  受ける)。

`make test`(`SummaryOutputSanitizerTests`の新規回帰含め全green)/`make mac`
green。`OtegamiTranslationFoundationModelsTests`(実機オンデバイスモデルへ
の結合テスト) は本タスクでは未実行 — 上記`scratchpad/summary-repro`での
実FM確認で代替した。実機シミュレータでの「詳しく要約」タップ→
シート表示の目視確認は`PENDING.md`「Task #148」節参照。

## スレッド全体のAI要約 (Task #153)

**背景**: それまでの「AI要約」は常に現在展開中の**1通のメッセージ**が
対象 (`MessageDetailFooterToolbar.summarizeButton` → `MessageView
.requestSummary`)。スレッド全体 (アコーディオン表示、複数メッセージ) を
一気に把握したいという要望に対応し、`ThreadDetailView`自身に「スレッド
全体を要約する」別のボタン・別の状態・別のシートを追加した。単一メッセ
ージの要約とは完全に独立した経路 — `MessageDetailAIFeaturesState
.summaryState`には一切触れない。

### 表示側の変更

- **ナビゲーションタイトル**: `ThreadDetailView`の`.navigationTitle`が、
  グループ化/アコーディオン表示 (`!isFlatModeEntry` — 実際のメッセージ数
  に関わらず) では「スレッド」、真に1通のみのフラット表示
  (`isFlatModeEntry == true`) では従来どおり「メール」を表示するように
  なった。三項演算子の各分岐を`String(localized:)`で明示 —
  `ComposerView.navigationTitle`と同じ理由 (`docs/localization.md`の
  「`Text(String)`は自動でローカライズされない」節参照): 2つの文字列
  リテラルの三項演算子をそのまま`.navigationTitle(_:)`に渡すと`String`
  オーバーロードに解決され、`LocalizedStringKey`経由の自動ローカライズ
  が効かない。
- **ツールバーボタン**: グループ化/アコーディオン表示のときだけ、
  ナビゲーションタイトルの隣に`"sparkles"`アイコン (単一メッセージの
  「要約」ボタン`MessageToolbarAction.summarize`と同じアイコンで見た目
  を統一) のトグルボタンを追加。タップすると生成 (未生成/失敗時のみ)
  してシートを開く — `MessageDetailFooterToolbar.handleSummarizeTap()`
  と同じ形。生成中はボタン自体が`ProgressView`に差し替わる。
- **シート**: `MessageView.summarySheet`と同じ構造 (生成中/完成/失敗の
  3状態 + 「再生成」)。単一メッセージ版と違い「詳しく要約」の2択メニュー
  は無い (このタスクの範囲外、通常の1択のみ)。本文の描画は`SummaryText`
  (`MessageView.swift`) をそのまま再利用 — 元々`private`だったが、
  「`"■"`始まりの行を太字にするだけ」という汎用的な整形でラベル文字列
  自体には依存していないため、`private`を外して`ThreadDetailView`からも
  呼べるようにした (ラベルが■経緯/■現状であっても無変更で動く)。

### 入力の組み立て

**Task #160で`threadSummarySourceText()`は`threadSummarySourceEntries()`
に置き換わった** (下記の抽出ロジック自体は不変、戻り値の形だけが
「改行連結済みの1本の`String`」から「`ThreadDigestMessage`の配列」に
変わった — 詳細はTask #160節参照)。以下はTask #153当時の記述:
`ThreadDetailView.threadSummarySourceText()`が、時系列順
(`ThreadQuery.messages(threadId:db:)`の`ORDER BY internalDate, uid`) に
並んだ`messages`の各メッセージについて`"[日時] 差出人: 新規本文"`という
1行を組み立て、改行で連結する。

- **新規本文の抽出**: 各メッセージの`MessageBodyRecord`に対して
  `QuoteStripper.separatingQuotedText(plainText:html:isReply:)`
  (Task #138のplain優先・htmlフォールバック) で`.newText`を取り出し、
  `MessageView.sourceTextForSummary()`と同じ安全網として
  `HTMLTextExtractor.plainText(fromHTML:)`をもう一度通す。単一メッセージ
  要約が使う`SummaryInputBuilder`(「引用の有無だけを注記する」ラッパー)
  はここでは使わない — スレッド全体のダイジェストは各メッセージの新規
  本文をそのまま並べたいので、あのラッパーの前提と形が違う。
- **本文が未取得のメッセージ**: このスレッドの「現在展開中の1通」以外は
  `MessageView.load()`が走っていないため、`MessageBodyRecord`がまだ
  ローカルに無いことがある。`MessageView.retryBodyFetchForSummary
  (message:)`と同じ考え方で、ローカルに無い場合だけ1回ネットワーク越しの
  取得 (`SyncCoordinator.fetchBody(for:mailboxPath:account:auth:)`) を
  試み、失敗すればそのメッセージは静かにスキップする (ベストエフォート
  — スレッド全体の要約自体は取得できた分だけで続行する)。
- **差出人名**: `message.fromAddresses.first?.name ?? .address ?? "?"` —
  `EmailAddress.description`(`"名前 <address>"`形式) は使わない。「差出人
  名は入力に書かれている名前のみ使用・推測禁止」という後段のモデル指示を
  裏付けるため、モデルへ渡す文字列自体にアドレスを機械的に付加するような
  ことをせず、本文中の`From:`名前 (無ければアドレスそのもの) だけを渡す。
- **日時**: `(message.date ?? message.internalDate).formatted(.dateTime
  .year().month().day().hour().minute())` — `OtegamiDateFormat
  .listRowText(for:)`(一覧行用、今日なら時刻のみに省略) ではなく、常に
  年月日+時刻のフルフォーマット。モデルへの入力であって UI 表示ではない
  ため省略の必要が無く、複数日にまたがるスレッドでも各メッセージの日付が
  常に一意に読み取れる方を優先した。

### 要約呼び出し: `summarizeThread`/`summarizeThreadDigest`

**Task #160で`summarizeThread`のmap段(文字数ベースの`TranslationChunker`
分割)はメッセージ単位の固定マップに置き換わった** — `summarizeThreadDigest`
(reduce段) 自体は下記の記述のまま不変。以下はTask #153当時の
`summarizeThread`の設計記述 (詳細・現行の実装はTask #160節参照):

既存の`summarizeLongText`(単一メッセージ、■要約/■伝えたいこと/
■アクションの3パート) はチャンクの reduce 段が常に3パート構造化
`summarize`を呼ぶ作りで、スレッドダイジェスト向けの2パート
(■経緯/■現状) 出力にはそのまま使えない。`TranslationService`に
`summarizeLongText`と並ぶ、同じ形の map-reduce を持つ新メソッドを追加:

- **`summarizeThreadDigest(_:targetLanguage:)`** (protocol requirement,
  単発・構造化): `summarize`の2パート版に相当。
  `FoundationModelsTranslationService`側は新設の
  `summarizeThreadInstructions(targetLanguage:)`で、■経緯 (時系列の経緯
  — 誰が何を提案・質問・回答したかを起きた順に) → ■現状 (現在の状態 —
  結論・合意事項・未解決の点) の2ラベル構造を要求する。Task #122由来の
  反復・指示文リーク防止の枠組み (ラベルはこの2つのみ・この順番・この
  文字列そのまま・全体で一度だけ・指示文自体や英語を含めない) と、
  「差出人名は入力に実際に書かれている名前のみ使用・推測禁止」ルールを
  そのまま踏襲 — ただし単一メッセージ版の「常に『この返信』を主語に
  する」は使えない (スレッド要約は複数の差出人が主体になり得るため)、
  代わりに「使ってよい名前は入力の`[日時] 差出人:`部分に実際にある名前
  だけ、それ以外は禁止」という形に言い換えた。モデルの生応答は
  `summarize`と同じく必ず`SummaryOutputSanitizer.sanitize(_:labels:)`
  (下記) を通してから返す。`FakeTranslationService`にも決定的な
  ■経緯/■現状出力を返す実装を追加 (`summarizeThreadDigestCallCount`で
  呼び出し回数を独立追跡)。
- **`summarizeThread(_:targetLanguage:)`** (protocol extension,
  map-reduce): `summarizeLongText`と同じ形 — 短文
  (`TranslationChunker.defaultMaxChunkLength`以下) は
  `summarizeThreadDigest`を1回呼ぶだけ、長文は`TranslationChunker.chunk`
  で分割し各チャンクを既存の`summarizePlain`(変更なし、そのまま再利用)
  で圧縮、結合した結果を最後に`summarizeThreadDigest`へ1回だけ通す。
  `TranslationChunker.chunk`は変更していない — 既存の`splitIntoUnits`が
  `"\n"`区切りの行を優先的にユニット境界にする実装のため、本メソッドの
  入力 (1メッセージ1行の`"[日時] 差出人: 本文"`形式) では通常チャンク
  境界がメッセージとメッセージの間に来る。境界が`"[日時] 差出人:"`の
  途中に来るのは、1メッセージの本文単体がチャンク閾値 (2000字) を超えて
  なおかつ文末句読点も改行も無い場合のみで、これは通常の英文プローズに
  対しても既存のhard-slice フォールバックがもともと引き受けている稀な
  ケース — 本タスクのために`TranslationChunker`へ手を入れる必要は無いと
  判断した。

### `SummaryOutputSanitizer`の2ラベル対応汎用化

`SummaryOutputSanitizer.sanitize(_:)`(3ラベル固定) のロジックを
`sanitize(_:labels:)`(任意個数のラベル) へ一般化した。各ラベルの行位置を
順に探し (見つからなければ既存と同じ「トリムした原文をそのまま返す」
フォールバック)、各パートの内容境界を「次に現れる任意の`■`始まり行、
無ければ次のラベルの行 (最後のラベルなら`lines.count`)」で決める — Task
#148がバグ修正で追加した「反復/リークが**パーツの間**に挟まる」パターン
への防御を、`zip(labelIndices, labelIndices.dropFirst() + [lines.count])`
という一般形に書き直しただけで、3ラベルの場合の挙動は完全に不変
(既存`content(label:labelLineIndex:in:contentEnd:)`/`trailingContent
(afterLabel:in:)`はそもそもラベル文字列に依存しない実装だったため無変更)。
既存の`sanitize(_:)`は`sanitize(_:labels: [summaryLabel, intentLabel,
actionLabel])`を呼ぶだけの薄いラッパーになった。

### 検証

**単体テスト** (`packages/OtegamiKit`):

- `SummaryOutputSanitizerTests`: 既存8ケース (3ラベル) は無変更のまま
  green、新たに2ラベル (■経緯/■現状) 版を5ケース追加 (正常透過・末尾
  反復除去・指示文リーク除去・ラベル欠落時フォールバック・複数行内容の
  保持) — 3ラベル版の対応ケースをそのまま2ラベルへ写した形。
- `TranslationServiceSummarizeThreadTests`(新規、既存の
  `TranslationServiceSummarizeLongTextTests`と対の構成): 短文入力は
  `summarizeThreadDigest`を1回だけ・`summarizePlain`は0回、長文入力は
  `summarizePlain`をチャンク数分・`summarizeThreadDigest`を最終段で
  ちょうど1回だけ呼ぶことを`FakeTranslationService`の独立カウンタで確認。
- `make test` green (`MessageBuilderTests`の既知flaky日本語ラウンド
  トリップ以外)。`make mac` green。

**実FoundationModels確認** (`scratchpad/summary-repro`、既存の再現ランナー
に`SUMMARY_REPRO_MODE=thread`/`thread-long`を追加): 架空の6メッセージ
スレッド (田中太郎・佐藤花子・Alice Example という架空名、社内懇親会の
会場・予算・日程調整という当たり障りのない題材、実在の人物・会社・
メールアドレスとは無関係) を`"[日時] 差出人: 本文"`形式で組み立て、
`summarizeThread`を実行:

- 非チャンク経路 (`TranslationChunker.chunk(input).count == 1`) を3回
  実行。3回とも`■経緯`→`■現状`の2パート構造がちょうど1回ずつ、反復・
  指示文リークなし。出力に登場する人物名は`田中太郎`/`佐藤花子`/`Alice
  Example`のみ (入力に無い名前の創作なし)。分量はいずれも合計5〜6文
  程度で、タスク仕様の「5〜10文」の範囲内。実際の出力例 (1回目):

  ```
  ■経緯
  田中太郎さんが会場の候補を提案し、佐藤花子が予算の確認と日程の提案を
  行いました。その後、Alice Exampleさんが日程の確認と店舗の決定に賛成
  し、佐藤花子が予約の依頼をしました。田中太郎さんが予約の承諾と予約の
  確保を伝え、予約が取れ次第共有すると回答しました。

  ■現状
  イタリアン店での開催が決定され、予約の確保待ちの状態です。予約が
  取れ次第、スレッドで共有される予定です。
  ```

- チャンク分割経路 (`SUMMARY_REPRO_MODE=thread-long`、同じ6メッセージを
  日付違いで6周・入力3,119字・`TranslationChunker.chunk(input).count ==
  2`) を1回実行。map (`summarizePlain`を2チャンク分) → reduce
  (`summarizeThreadDigest`1回) の経路を実際に通した上で、■経緯/■現状の
  2パート構造がちょうど1回、反復・リークなしを確認。分量は合計約4文と
  やや短め (人工的に同じ内容を反復させたフィクスチャのため、map段階での
  圧縮が効きやすかったことが原因と見られる — 実際のスレッドで内容が
  メッセージごとに異なっていればこの制約は緩和されるはず。既存の
  `summarizeLongText`が同じmap-reduce構造上すでに抱える制約であり、
  本タスクが新たに悪化させたものではない)。

以上、計4回の実FM実行いずれも`SummaryOutputSanitizer`の2ラベル版が実際の
モデル出力を正しく整形できることを確認した。`scratchpad/summary-repro`は
リポジトリ外・非コミット (このドキュメント自身が示す既存の慣例どおり)。

**未確認**: スクリーンショットでの目視確認は「ナビゲーションタイトルが
『スレッド』になっている」「新設のツールバーボタンが表示されている」の
2点のみ (`docs/design-system.md`のTask #153節参照) — シート自体
(生成中/完成/失敗の各表示、「再生成」ボタン) をタップ経由でスクリーン
ショット確認する新シナリオは追加していない (Part 7の「任意・nice-to-
have」の範囲、時間の都合で見送り)。実機での確認ポイントは
`PENDING.md`参照。

## 翻訳を Apple Translation フレームワークの専用 NMT へ切替 (Task #159)

**背景**: それまでの翻訳 (`translate`/`translateParagraphs`/`translateStream`)
は要約 (`summarize`系) と同じ `FoundationModelsTranslationService` (汎用
オンデバイス LLM) が担っていた。ユーザー指示により、翻訳だけを Apple
`Translation` フレームワーク (`TranslationSession` — iOS 18+/macOS 15+ の
専用 NMT モデル。本アプリの対応OSは既に 26+ なので利用可) に切り替え、
**要約系は `FoundationModelsTranslationService` のまま維持**する。

### アーキテクチャ

1. **`TranslationService` を2分割**: `OtegamiTranslation` の
   `TranslationService` protocol から `translate`/`translateParagraphs`/
   `translateStream`/`availability` の4つを `TranslationOnlyService`
   という新しい protocol に切り出し、`TranslationService` はそれを
   refine (要約系3メソッドのみ追加宣言) するように変更した。
   `FakeTranslationService`/`FoundationModelsTranslationService` はどちら
   も既に全メソッドを実装済みだったため、この分割自体はどちらのファイル
   にも変更を必要としなかった。
2. **`AppleTranslationService`** (新パッケージ
   `OtegamiTranslationApple`): `TranslationOnlyService` の実装。
   `Translation.TranslationSession` を使う。
3. **`HybridTranslationService`** (`OtegamiTranslation`、Apple 依存なしの
   純粋な合成): `translate`系を`TranslationOnlyService`実装
   (`AppleTranslationService`) へ、`summarize`系を `any TranslationService`
   (`FoundationModelsTranslationService`) へ振り分けるだけの薄いラッパー。
   `AppEnvironment.translationService` が実際に保持するのはこの型のイン
   スタンス — `MessageTranslator`/`ThreadDetailView.requestThreadSummary`
   など既存の呼び出し側は、この型がどちらのメソッド群をどこへ転送してい
   るか一切知る必要がなく、無変更で動く。
4. **`MessageTranslator.EngineIdentifier.appleTranslation`**
   (`"apple-translation"`) を新設し、`foundation-models`とは別の識別子に
   した — `MessageTranslationRecord`のキャッシュ有効性チェック
   (`isStillValid`) がエンジン識別子の一致を見るため、切替後の初回オープ
   ンでは旧エンジンのキャッシュが自動的に無効化され、新エンジンで再翻訳
   される。

### `TranslationSession` の橋渡し (SwiftUI 依存を切り離す設計)

`TranslationSession`には public な initializer が無く (iOS 26.0+の
`TranslationSession(installedSource:target:)` は例外だが、「既にダウン
ロード済みのペア」前提の convenience initializer で、未ダウンロード時の
ダウンロード誘導 UI を伴わないため今回は使っていない)、Apple が唯一サ
ポートしているのは SwiftUI の `.translationTask(_:action:)` view modifier
経由での取得である。一方 `AppleTranslationService`/`MessageTranslator`
はビューを持たないサービス層のコードなので、両者を橋渡しする
`TranslationSessionCoordinator` (`OtegamiTranslationApple`、`@MainActor
@Observable`) を新設した:

- `AppEnvironment` が1つだけ保持する (`translationSessionCoordinator`)。
- `apps/Otegami` 側の `TranslationSessionHostView` (`ThreadDetailView`の
  ルートに `.background` で常駐、0サイズ・非表示) が
  `coordinator.configuration` を読んで `.translationTask` に渡す。
- `AppleTranslationService.translate`/`translateParagraphs` は
  `coordinator.translate(_:to:)`/`translateBatch(_:to:)` を呼び、内部で
  `configuration` を更新 → SwiftUI が新しい `TranslationSession` を
  action closure 経由で返す → `coordinator.attach(_:)` がそれを受け取り、
  待機していた `async` 呼び出し元へ渡す、という一往復を待つ。
- 同じ target 言語のセッションは使い回す (`FoundationModelsTranslationService`
  が「呼び出しごとに新しい `LanguageModelSession`」を選ぶのとは対照的 —
  そちらは会話履歴混入を避けるためだが、`TranslationSession`には会話履歴
  という概念自体が無いため使い回して問題ない。言語パックのダウンロード
  プロンプトが起動ごとに複数回出るのも避けられる)。

**`Translation.TranslationSession` は `Sendable` ではない** (実SDKの
`.swiftinterface` で確認済み) ため、`TranslationSessionCoordinator` の
公開 API は `session(to:) -> TranslationSession` のような「セッション
そのものを返す」形にはせず、`translate(_:to:) -> String`/
`translateBatch(_:to:) -> [String]`/`prepareTranslation(to:)` という
「セッションを内部で使い切って `Sendable` な結果だけ返す」形にした —
セッションの生存期間を丸ごと `@MainActor` 内に閉じ込めることで、
`TranslationOnlyService: Sendable` の要件を満たしたまま actor 境界を越え
させずに済む設計にしている。

### 言語パック未ダウンロード時の扱い (要件3)

`AppleTranslationService.translate`/`translateParagraphs` は実際の翻訳呼
び出し前に:

1. `LanguageAvailability().status(from:to:)` で名目上の言語ペア (呼び出
   し元が渡す `source`/`target`) の対応状況を確認 — `.unsupported` な
   ら「この端末は…への翻訳に対応していません」で即座に失敗させる。
2. `TranslationSessionCoordinator.prepareTranslation(to:)`
   (→ `session.prepareTranslation()`) を呼ぶ。Apple 公式のダウンロード
   誘導トリガーで、既にダウンロード済みなら no-op。

`Translation.TranslationError` (`.notInstalled`/`.unsupportedSourceLanguage`
等、実SDKで確認済みのケース) は `mapEngineError` で個別に
`TranslationServiceError` へマッピングし、「翻訳用の言語データが未ダウン
ロードです。設定 > 一般 > 言語と地域 から翻訳言語をダウンロードしてくだ
さい」のような具体的な文言にしている。**翻訳ボタン自体は #138 の方針
(常時有効) を維持** — `AppleTranslationService.availability` は常に
`.available` を返し (フレームワーク自体は本アプリの対応OSで常に存在す
るため)、未ダウンロードは「ボタンが押せない」ではなく「押した結果のエ
ラー文言」として表面化する。

### 自動翻訳の言語判定 (要件4、実機報告「Okta のサインオン通知メールが
`NLLanguageRecognizer`に`pl`と誤判定される」)

2つの独立した変更で対応した:

1. **自動翻訳の起動ゲート (`MessageView.kickoffTranslationIfNeeded`)**:
   `message.detectedLanguage == "en"`の完全一致条件を、`!= "ja"`
   (確信を持って日本語と判定されていない限り起動を試みる) へ緩和した。
   `docs/translation.md`の Task #138節が別のゲート
   (`shouldShowTranslationBar`) に対して既に確立した「過度に厳しい言語
   ゲートを緩める」という前例をそのまま踏襲したもの。`NLLanguageRecognizer`
   自体の置き換えは行っていない — Translation フレームワークには単独の
   「この文章の言語を判定する」API が存在せず (`LanguageAvailability`は
   言語ペアの対応状況のみ、`TranslationSession.Configuration(source: nil,
   ...)`は「翻訳時に内部で自動判定する」機能であって判定結果を単独で問
   い合わせる手段ではない)、この起動ゲート自体を Translation 側へ丸ごと
   置き換える手段が無かったため。
2. **実際の翻訳呼び出し (根治)**: `AppleTranslationService`は呼び出し元
   が渡す`source`(このアプリでは常に`.english`固定)をセッションの
   `Configuration`にそのまま使わず、常に`source: nil`(Translation フレー
   ムワーク自身による自動判定)で構成する。これにより、起動ゲートが
   (1の緩和によって、あるいは既存の誤判定によって) 誤って通過した場合で
   も、実際の翻訳エンジンが本当の原文言語を判定してから翻訳する —
   旧`FoundationModelsTranslationService`のように「`source: .english`だ
   と決め打ちで LLM に指示する」ことによる誤訳リスクがなくなる。

**検証できていない点 (重要)**: 上記の「Okta メールが実際に正しく自動翻
訳されるようになったか」は実機/シミュレータでの動作確認ができておらず
未検証。`TranslationSession.Response.sourceLanguage`(実SDKで存在を確認
済み、自動判定時に実際に使われた言語を返す)を使って「起動ゲートを完全
に Translation 側の判定結果だけで決める」設計も検討したが、そのために
は`MessageTranslator`/`MessageView`側に新しい状態受け渡し (「この自動翻
訳は実際には言語不一致でスキップすべきだった」という事後判定) を追加す
る必要があり、今回のタスク範囲では見送った — 将来の改善候補として
`PENDING.md`に記録する。

### 検証状況とシミュレータの既知不調領域 (要件・ルール)

- `make test`/`make mac`/`make ios` はいずれも緑 (エラー0件)。
- `OtegamiTranslationApple`パッケージの protocol 境界のユニットテスト
  (`HybridTranslationServiceTests`: 翻訳系呼び出しは翻訳エンジンのみに、
  要約系呼び出しは要約エンジンのみに届くこと、`availability`が翻訳エン
  ジン由来であることを2つの`FakeTranslationService`で検証) は追加済み。
- **`AppleTranslationService`の実エンジン部分 (`TranslationSession`本体
  を使う翻訳呼び出し) は自動テスト不可** — `FoundationModelsTranslationService`
  同様、実機/シミュレータでの動作が前提であり、`docs/translation.md`
  冒頭「design-phase-3: iOS Simulator の `.app` プロセスから呼んだとき
  の既知の制限」節が記録した Foundation Models 固有の Simulator 不調
  (`error -1`) と同じ「シミュレータ既知不調」領域に、Translation フレー
  ムワークも該当する可能性が高いと判断し、本タスクでは`scripts/verify-screen.sh`
  によるシミュレータでの Translation 動作確認を試みていない (`docs/verify.md`
  の「シミュレータでエラーが出たら粘らない」方針どおり)。
- 実機での確認ポイント: (1) 英語メール本文の翻訳ボタンが機能すること、
  (2) 言語パック未ダウンロード時にダウンロード誘導が実際に走ること、
  (3) 明らかに英語なのに`detectedLanguage`が英語以外に誤判定される
  メール (Okta 通知など) で自動翻訳が正しく起動・実行されること。

## スレッド全体のAI要約: メッセージ単位のmap段への改修 (Task #160)

**背景**: Task #153のスレッド要約は、実機フィードバック (2026-07-29) で
「■経緯/■現状が短すぎるし内容も少し変」と指摘された。原因は
`summarizeThread`のmap段が`TranslationChunker.chunk`の**文字数ベース**の
境界で回っていたこと — 短いスレッド (合計の新規本文が
`TranslationChunker.defaultMaxChunkLength`未満、実際のスレッドの
ほとんどがこれに該当) では`summarizePlain`を1回も呼ばず、丸ごと1回の
`summarizeThreadDigest`呼び出しに全てを委ねていた。Task #153の実FM確認
ログ (上記節) の6メッセージスレッドが「■経緯/■現状合計5〜6文」にしか
ならなかったのはこのため — メッセージ数に関係なく、文字数が閾値を
超えないかぎりモデル呼び出しは常に1回だけだった。

ユーザー指示: **「複数回 FoundationModel 実行していいから、時系列で経緯を
まとめて欲しい」**。

### 実装: mapをメッセージ単位に固定

`TranslationService.summarizeThread(_:targetLanguage:onProgress:)`
(protocol extension) のシグネチャを、単一の結合済み`String`から
`[ThreadDigestMessage]`(新設の`public struct`、`header`と`text`を別々に
持つ) へ変更した:

- **`ThreadDigestMessage.header`**: `"[日時] 差出人:"` — 呼び出し元
  (`ThreadDetailView.threadSummarySourceEntries()`) が信頼できるメタ
  データから組み立てる、確定文字列。
- **`ThreadDigestMessage.text`**: そのメッセージの新規本文のみ (引用除去
  済み)。

`summarizeThread`は`messages`の各要素を**必ず1回ずつ**ループし、`text`
だけを`summarizePlain`へ渡して1-3文へ圧縮 → その結果の前に`header`を
機械的に前置きして`"\(header) \(compact)"`という行を作る → 全メッセージ
分の行を改行で連結して`summarizeThreadDigest`へ1回だけ渡す (reduce段は
Task #153から不変)。`TranslationChunker`の文字数境界はもう使わない —
1メッセージの本文単体が`defaultMaxChunkLength`を超える場合だけ、内部の
`compactThreadMessageText(_:targetLanguage:)`が`summarizeLongText`と
同じチャンク分割の安全網を通す (通常のメッセージはこの分岐に入らない)。

**`header`をmap段のモデル入力に含めない理由**: `summarizePlainInstructions`
は「本文中に差出人・宛先名が出てきても主語にせず『この返信』を主語に
する」設計 (Task #122/#134) のため、`"[日時] 差出人:"`をモデルへの入力に
混ぜると、その名前・日時をモデルが不確実な言い回しで本文に混ぜて返す
(二重に言及される、あるいは不正確に言い換えられる) リスクがある。
`header`を常にコード側で確定させることで、reduce段の指示文
(`summarizeThreadInstructions`の【入力の構造】) が前提とする
`"[日時] 差出人: 本文"`という行フォーマットを型として保証できる。

### 進捗表示

メッセージ数が多いスレッドほどモデル実行回数(=生成時間)が増えるため、
`summarizeThread`に`onProgress: (@MainActor @Sendable (Int, Int) ->
Void)?`パラメータを追加した — `Optional`のクロージャ引数は暗黙に
`@escaping`になる (`AccountSyncer.performInitialSync(auth:onProgress:)`
の`onProgress`と同じ理由でSendable化が要る)、加えて`@MainActor`も付けた
のは`ThreadDetailView`(`View`、MainActor隔離) がこのクロージャを`self`
キャプチャ込みでそのまま書けるようにするため (`@MainActor`隔離自体が
`Sendable`の求める安全性の裏付けになる)。`ThreadDetailView`は
`threadSummaryProgress: (current: Int, total: Int)?`という別の`@State`
(`threadSummaryState`本体とは独立) にこれを受け、生成中シートに
「n/m 通目を要約中…」を表示する。

### テスト

`TranslationServiceSummarizeThreadTests`を新API向けに全面書き換え:
`summarizePlain`がメッセージ数ぶんちょうど1回ずつ・`summarizeThreadDigest`
が最終段でちょうど1回 (短いスレッドでも0回にならない、Task #153時代との
最大の違い)、空配列は両方0回、1メッセージの本文単体が閾値を超える場合の
チャンク安全網が発火すること、`onProgress`が`(1, n)`から`(n, n)`まで
メッセージ順に届くことの4ケース。`make test`/`make mac`/`make ios`
green。

**実FoundationModels確認** (`scratchpad/summary-repro`、`SUMMARY_REPRO_MODE
=thread`のfixtureをTask #153と同じ6メッセージ架空スレッドのまま、
`summarizeThread`の呼び出しだけ新APIへ追従): 3回実行、いずれも■経緯→
■現状の2パート構造がちょうど1回ずつ、反復・指示文リークなし、人物名は
入力の`田中太郎`/`佐藤花子`/`Alice Example`のみ。■経緯の分量はTask #153
時代の「合計5〜6文」から明確に改善し、3回中2回は6メッセージに対して
4〜6文 (ほぼ1通1行) となった。実際の出力例 (1回目、■経緯が6メッセージ
ちょうど6文):

```
■経緯
田中太郎が懇親会の会場として駅前の個室居酒屋と会社近くのイタリアンを提案を提案し、その後、佐藤花子が予算の具体的な金額を求めて質問をした。その後、田中太郎が予算1人あたり5000円程度でイタリアンのお店が収まりそうだと回答し、Alice Exampleが金曜の19時からの予約確認を求めた。その後、佐藤花子が金曜の19時に予約したいという要望を伝え、田中太郎が予約を金曜の19時に入れる旨を伝えた。

■現状
イタリアンのお店への予約が取れ次第、スレッドで共有する予定であり、具体的な予算金額についてはまだ合意に至っていない。
```

(この実行は「提案を提案し」という軽微な言い回しの重複と、■現状の
「予算金額について合意に至っていない」という部分がやや不正確 — 実際は
message 3で1人5000円程度と合意済み — という、モデル側の生成品質の
揺らぎが残っている。3回中1回はこの種の細かい不正確さが出たが、■経緯/
■現状の構造そのもの・差出人名の扱い・時系列の順序はいずれも正しく、
Task #153由来の指示文防御 (差出人名は入力にある名前のみ・新規本文に
無い内容を補わない) は機能し続けている。1メッセージの本文単体が
チャンク閾値を超える安全網経路は`FakeTranslationService`での単体テスト
のみ確認 — `summarizeLongText`がTask #122で実FM確認済みの同型ロジックの
再利用のため、今回は実FM再確認を省略した)。

`scratchpad/summary-repro`はリポジトリ外・非コミット (既存の慣例どおり)。

**未確認**: 「n/m 通目を要約中…」の進捗表示はシミュレータ/実機での
スクリーンショット確認をしていない (`PENDING.md`参照) — Foundation
Modelsの実行自体がシミュレータで既知不調 (`docs/verify.md`) なため、
生成中シート自体をタップ経由で開いて確認する新シナリオは追加していない。

## スレッド要約の二重圧縮を根治 (Task #160フォローアップ)

**背景**: Task #160でmap段をメッセージ単位に固定した後も、実機フィード
バックは続いた — 「スレッド要約が雑すぎて内容がほとんど抜け落ちている」。
原因は**二重圧縮**: (a) map段の`summarizePlain`は「短くする」ことを
最優先する圧縮指示のため、具体的な数値・固有名詞・決定事項を真っ先に
削る (単一メッセージの`summarizeLongText`が求める挙動としては正しい)。
(b) それでもなお、reduce段 (`summarizeThreadDigest`) が
「per-message圧縮結果をまとめて経緯を書く」ため、もう一段モデルが圧縮
し直していた。2段とも「短くする」方向のモデル呼び出しが直列に並んで
いれば、情報が生き残る保証はどこにも無い。

ユーザー指示: 構造的な再設計 — mapを「要約」から「事実抽出」へ、■経緯を
モデルで再圧縮しない、■現状だけモデル1回。

### 実装

1. **map段: `summarizeThreadEntry`(新設、protocol requirement)** —
   `summarizePlain`(圧縮) とは目的が正反対の「事実抽出」専用メソッド。
   `FoundationModelsTranslationService`の`summarizeThreadEntryInstructions`
   は「決定事項・依頼/質問・数値・日付・固有名詞を一切省略しない、削って
   よいのは挨拶・定型句だけ」と明示し、目安の文数 (2〜5文、新規本文が
   400字を超える長いメッセージは3〜8文) よりも情報保持を優先するよう
   求める。差出人名を主語にしない設計 (Task #122/#134由来) は維持 — 本文
   中の第三者名・地名・店名などを内容として書くことは禁止していない
   (「主語にしない」ことと「固有名詞を書く」ことは矛盾しない)。出力は
   `summarizePlain`と同様ラベルなしの地の文で、改行も禁止 (`summarizeThread`
   が1メッセージ1行の箇条書きへそのまま組み込むため) — 指示文に加えて
   コード側でも改行をスペースへ畳む後処理を入れた (二段構えの防御)。
2. **■経緯はモデルで再圧縮しない** — `TranslationService.summarizeThread`
   が各メッセージの`summarizeThreadEntry`結果を`"\(header) \(extracted)"`
   という行にして時系列のまま連結し、`"■経緯\n"`を前置きするだけ。ここに
   reduce段のモデル呼び出しは一切挟まらないので、原理的に情報損失が起き
   ない — これが「二重圧縮の根治」の核心。
3. **■現状だけモデル1回** — `summarizeThreadDigest`(protocol requirement、
   従来の■経緯/■現状2パート版から1パートへ縮小) が、上記と同じ`combined`
   (箇条書きと同一の行) を入力に、「このスレッドが最終的にどうなったか・
   未決事項・次のアクション」を約2〜4文で生成する。`■経緯`と同じ入力を
   見るので、差出人名についても引き続き「入力に実際に書かれている名前
   だけ使用・推測禁止」を課す。
4. **`SummaryOutputSanitizer`は■現状パートのみに適用** —
   `sanitize(_:labels:)`を`[ThreadDigestLabel.currentStatus]`という
   1ラベルだけで呼ぶ (このメソッドは元々任意個数のラベルに対応する汎用
   実装、Task #153の一般化がここでも活きた)。■経緯はアプリ側の文字列
   そのものなのでサニタイズ対象外。
5. **ラベル文字列の一元化**: `"■経緯"`/`"■現状"`を新設の
   `OtegamiTranslation.ThreadDigestLabel`(public enum) に集約 —
   `TranslationService.swift`(■経緯を前置きする側) と
   `FoundationModelsTranslationService.swift`(■現状をモデルに生成させる
   側・`SummaryOutputSanitizer`呼び出し側) の両方がこれを参照するので、
   2つのモジュールにまたがる文字列が二度と drift しない。
6. 進捗表示 (`onProgress`の「n/m 通目を要約中…」) は変更なし — map段が
   `summarizeThreadEntry`に変わっただけで、呼び出し回数・タイミングは
   Task #160と同じ (メッセージ1件につき1回)。

`ThreadDigestMessage.header`のフォーマットもTask #160の
`"yyyy/MM/dd HH:mm"`(フル日時) から`"M/d"`(`.dateTime.month().day()`) へ
短縮した — 以前は■経緯自体がこのヘッダー付き行をモデルに渡すだけの
入力だったので日時の精度がそのまま経緯パートの精度になっていたが、今は
■経緯がアプリ側の箇条書き表示そのものであり、ユーザーが読む一覧として
「月/日」程度の粒度の方が簡潔で読みやすい。

### テスト

`TranslationServiceSummarizeThreadTests`を新設計向けに全面書き換え:
`summarizeThreadEntry`がメッセージ数ぶんちょうど1回・`summarizeThreadDigest`
が最終段でちょうど1回・`summarizePlain`/`summarize`は0回 (map/reduceの
呼び出し先が完全に分離したことの確認)、返り値の文字列が「app-built
■経緯 + summarizeThreadDigestの■現状」という組み立てそのものと厳密に
一致すること、1メッセージの本文単体がチャンク閾値を超える場合に
チャンク数ぶんちょうど`summarizeThreadEntry`が呼ばれ**再結合の追加呼び出し
が無い**こと (Task #160時代の`compactThreadMessageText`は再結合の
`summarizePlain`をもう1回呼んでいたが、事実抽出でその追加圧縮をやると
二重圧縮の再発になるため意図的に削った)、`onProgress`の順序。
`HybridTranslationServiceTests`に`summarizeThreadEntry`の委譲確認を追加。
`make test`/`make mac`/`make ios` green。

**実FoundationModels確認** (`scratchpad/summary-repro`、Task #153/#160と
同じ6メッセージ架空スレッド、`summarizeThread`呼び出しを新APIへ追従・
`header`を実際の`"M/d"`短縮フォーマットへ追従) を3回実行。判定基準は
「各メッセージの具体的な内容 (数値・固有名詞) が■経緯に残っているか」:

- 3回とも、金額 (`5000円`)・曜日+時刻 (`金曜19時`)・会場の固有名詞
  (`駅前の個室居酒屋`/`会社近くのイタリアン`) が、対応するメッセージの
  ■経緯の行にちょうど残っていた — 3回中2回は6行すべてに、1回
  (run 3) はさらに「社内懇親会」という話題名まで残った。■経緯/■現状の
  2ラベル構造・反復無し・指示文リーク無し・登場人物名が入力の
  `田中太郎`/`佐藤花子`/`Alice Example`のみ、という既存の防御もすべて
  健在。

  before (Task #160、二重圧縮あり — `docs/translation.md`のTask #160節
  実行例、■経緯は6行相当の内容が4〜6文の地の文にまとめられていた):

  ```
  ■経緯
  田中太郎が懇親会の会場として駅前の個室居酒屋と会社近くのイタリアンを提案を提案し、その後、佐藤花子が予算の具体的な金額を求めて質問をした。その後、田中太郎が予算1人あたり5000円程度でイタリアンのお店が収まりそうだと回答し、Alice Exampleが金曜の19時からの予約確認を求めた。その後、佐藤花子が金曜の19時に予約したいという要望を伝え、田中太郎が予約を金曜の19時に入れる旨を伝えた。

  ■現状
  イタリアンのお店への予約が取れ次第、スレッドで共有する予定であり、具体的な予算金額についてはまだ合意に至っていない。
  ```

  after (今回の実行、run 1 — ■経緯がメッセージ1通1行の箇条書きになり、
  各行が対応するメッセージの具体的な内容をそのまま保持):

  ```
  ■経緯
  [07/20] 田中太郎: 駅前の個室居酒屋と会社近くのイタリアンの2つの会場候補について、皆さんの意見を伺いたい。
  [07/20] 佐藤花子: この返信では予算の想定について質問がなされていますが、具体的な数値や金額の記載は含まれていません。
  [07/20] 田中太郎: この返信では、予算が1人あたり5000円程度であること、イタリアンのお店であればその予算内で収まりそうであるという内容が述べられている。
  [07/20] Alice Example: 来週の金曜19時からイタリアンに賛成です。
  [07/20] 佐藤花子: 金曜19時にイタリアンのお店を予約できますか。
  [07/20] 田中太郎: 来週金曜19時にイタリアンのお店で予約を入れる予定です。予約が取れ次第、改めてこのスレッドで共有します。

  ■現状
  予算の数値は未記載だが、1人あたり5000円程度でイタリアンが予算内に収まりそうだと判断された。来週金曜19時にイタリアンで予約を入れる予定であり、予約が取れ次第スレッドで共有する。
  ```

  (2行目の「具体的な数値や金額の記載は含まれていません」は、当該メッセージ
  自体が「予算はどのくらいを想定していますか？」という質問のみで実際に
  数値を含んでいないため、ハルシネーションではなく正確な抽出 — 数値は
  次の行 (message 3) に正しく現れている。)

`scratchpad/summary-repro`はリポジトリ外・非コミット (既存の慣例どおり)。

**未確認**: 進捗表示の実機/シミュレータ目視確認は前節から変わらず未実施
(Foundation Modelsのシミュレータ既知不調のため)。1メッセージの本文単体が
チャンク閾値を超える安全網経路 (`extractThreadEntryText`のチャンク分割)
は`FakeTranslationService`での単体テストのみ確認 — 実際のメール1通が
2000字を超えることは稀なため、実FM確認は見送った。

## スレッド要約のメタ言及調を除去 (Task #160フォローアップ2)

**背景**: Task #160フォローアップで二重圧縮を根治した後の実機フィード
バック — 「生成時間は許容範囲。ただし『この返信では〜が述べられている』
『〜という内容が記載されています』のような説明調(メタ言及)の口調が
気になる」。原因は`summarizeThreadEntryInstructions`(前節で新設) が
`summarizePlainInstructions`由来の「差出人・宛先名を主語にせず『この
返信』を主語にする」ルールをそのまま引き継いでいたこと — モデルが
「この返信は/では」を毎回の主語に立てようとした結果、メッセージ自体を
話題にする説明調の言い回しに倒れ込みやすくなっていた。

### 実装

1. **`summarizeThreadEntryInstructions`を締める**: 「差出人・宛先名を
   主語にする際は常に『この返信』に置き換える」というルールを撤去し、
   代わりに【メッセージを説明するな、事実を直接書け(最重要)】という
   専用セクションを新設。「この返信では」「このメールでは」「この
   メッセージでは」「〜が述べられている」「〜と述べられている」「〜が
   記載されている」「〜と記載されている」「〜という内容」「〜と伝え
   られている」「〜と書かれている」を名指しで禁止し、悪い例/良い例の
   ペアを2組(会議室の予約、資料の提出期限) 指示文に含めた。
   - **イテレーション1の反省**: 最初に使った例文が偶然
     `scratchpad/summary-repro`の架空フィクスチャと同じ題材 (「予算は
     1人あたり5000円程度」) だったため、実FM確認1回目でこの数値が
     予算の**質問のみで金額が書かれていないメッセージ**(佐藤花子の
     2通目) の抽出結果にまで出現するハルシネーションを引き起こした
     (Task #97/#102/#122/#132/#134が既に記録している「指示文の例文
     そのものが出力に漏れる」という同じ失敗パターン)。例文の題材を
     架空フィクスチャと無関係なもの (会議室予約・提出期限) に差し替え、
     かつ【新規本文に実際に書かれていない内容を補わない】節に「質問
     だけで具体的な数値がまだ書かれていない場合、一般的な相場やあり
     そうな数値を書き加えてはいけない」という一文を追加してイテレー
     ション2で再確認 — 消えたことを確認済み (下記実FM確認)。
2. **アプリ側の後処理 (保険): `ThreadEntryMetaCommentaryStripper`**
   (新設、`OtegamiCore`) — `SummaryOutputSanitizer`と同じ「指示文 +
   実装側の後処理」の二段構えパターン。`summarizeThreadEntry`の出力の
   改行畳み処理の直後にもう一段通す。**正規表現ベースの過剰除去を避け
   るため、意図的に狭いスコープ**にした: 文自体が「この返信は/では」
   「このメールは/では」「このメッセージは/では」という自己参照の主語
   で*始まる*場合だけを書き換え対象にする — それ以外の文は、たとえ
   「伝えられている」のような禁止語を含んでいても一切手を触れない
   (これらの語は第三者の発言を伝える正当な内容でも自然に使われる —
   例:「先方からは来月まで待ってほしいと伝えられている」は事実その
   ものであり、削ってはいけない情報)。マッチした文はオープナーを除去
   し、末尾に決まったメタ言及の述語 (「〜が述べられている」等) があれば
   それも除去する。`ThreadEntryMetaCommentaryStripperTests`(8ケース):
   報告された悪い例がそのまま良い例の形に書き換わること、オープナーの
   みでも述語が無い文は正しく処理されること、開始マーカーの無い文は
   (禁止語を含んでいても) 完全に無変更で返ること、複数文の入力で対象
   の文だけが書き換わり他は無変更のまま残ること、空入力・終端記号なし
   入力・「オープナー+述語で中身が空になる」退化ケースの安全なフォール
   バック、をそれぞれ検証。
3. `SummaryOutputSanitizer`側の変更は無し — このフォローアップは
   ラベル構造ではなく`■経緯`各行の文体の話なので対象外。

### テスト

`ThreadEntryMetaCommentaryStripperTests`(新規、8ケース、上記参照)。
`make test`/`make mac`/`make ios` green
(`MessageBuilderTests`の既知flaky日本語ラウンドトリップ以外)。

**実FoundationModels確認** (`scratchpad/summary-repro`、Task #153/#160と
同じ6メッセージ架空スレッド) を2イテレーション、各3回実行:

- **イテレーション1** (例文の題材が架空フィクスチャと偶然一致):
  メタ言及は3回とも完全に消えたが、佐藤花子の2通目 (「予算はどのくらい
  を想定していますか?」— 金額の記載なし) の抽出結果に「予算は1人あたり
  5000円程度。」という**存在しない数値のハルシネーション**が3回とも
  出現 — 上記「実装」節の反省どおり指示文を修正。
- **イテレーション2** (例文を差し替え、質問への数値補完を明示的に禁止):
  3回とも、メタ言及ゼロ・佐藤花子の2通目のハルシネーション無し (「まだ
  回答なし」「まだ書かれていない」と正確に表現) の両方を達成。金額
  (`5000円`)・曜日+時刻 (`金曜19時`)・会場の固有名詞は引き続き対応する
  メッセージの行に正しく残っていた。

  before (イテレーション1、メタ言及調・run 1の抜粋):

  ```
  ■経緯
  [07/20] 田中太郎: この返信では、来週の社内懇親会の会場候補として、駅前の個室居酒屋と会社近くのイタリアンが提示されており、どちらがよいか皆さんの意見を伺いたいと伝えられている。
  ```

  after (イテレーション2、run 3の全文):

  ```
  ■経緯
  [07/20] 田中太郎: 駅前の個室居酒屋と会社近くのイタリアンの2つの会場候補について意見を伺いたい。 どちらの会場がよいか確認したい。
  [07/20] 佐藤花子: 予算はどのくらいを想定しているか確認したい(まだ回答なし)。
  [07/20] 田中太郎: 予算は1人あたり5000円程度で、イタリアンのお店ならその予算内で収まりそうだ。
  [07/20] Alice Example: 予算感も分かりました。 イタリアンに賛成です。 日程は来週の金曜19時からでよいでしょうか。
  [07/20] 佐藤花子: 金曜19時にイタリアンのお店を予約します。 田中さんに予約をお願いします。
  [07/20] 田中太郎: イタリアンのお店に来週金曜19時に予約を入れる。 予約が取れ次第、改めてこのスレッドで共有する。

  ■現状
  来週の金曜19時にイタリアンの店で予約を取る予定であり、予約が取れ次第スレッドで共有する。

  予算は1人あたり5000円程度で、イタリアンのお店が予算内で収まりそうだという合意があり、佐藤花子は金曜19時にイタリアンのお店を予約し、田中太郎に予約を依頼した。
  ```

  (イテレーション1のbefore例は「この返信では」で始まり「伝えられている」
  で終わる典型的なメタ言及パターン。イテレーション2のafter例は全行が
  事実の直接記述になっている。)

`scratchpad/summary-repro`はリポジトリ外・非コミット (既存の慣例どおり)。

**副次的に観測した点 (今回のスコープ外)**: イテレーション2の3回中2回で、
■現状パートが「・」始まりの箇条書き + 空行を挟んだ自由文、という
`currentStatusInstructions`が求める「2〜4文の一続きの文章」からやや
外れた形式で返ってきた (`SummaryOutputSanitizer`のラベル検出自体には
影響しない — 内容は正しく■現状のラベルの下に入る)。今回の報告 (メタ
言及・ハルシネーション) には直接関係が無く、`currentStatusInstructions`
自体は今回変更していないため、別途の報告があれば対応する。

## スレッド要約の「仕上げ」パスでさらに簡潔化 (Task #160フォローアップ3)

**背景**: ユーザー要望「要約済みのものを再度読ませてさらに要約を挟ませて、
もう少しシンプルにすることはできる?」— Task #160フォローアップ/フォロー
アップ2で■経緯が per-message 抽出の無加工列挙 (メッセージ1通につき
ちょうど1行) になったことで情報損失・メタ言及は解消したが、往復の多い
スレッドでは列挙がやや冗長に感じられた。

### 実装: map → refine (新規) → reduce

`TranslationService.summarizeThread`のパイプラインに、mapとreduceの間に
新しい任意パス`refineThreadEntries`(protocol requirement) を追加した:

1. **map (`summarizeThreadEntry`、不変)**: 各メッセージから事実を抽出。
2. **refine (新設)**: mapの抽出結果全体 (`combined`、header付き改行区切り
   の行) を1回読み、「同じ話題への複数の応答をまとめ、冗長な表現を削り、
   時系列の流れとして簡潔に書き直した■経緯」を生成する。**これは生の
   本文の再圧縮ではない** — 既に「情報を落とさない」制約下で抽出済みの
   テキストをさらに1段統合するだけなので、Task #160フォローアップが
   根治した二重圧縮バグ (2段とも生の本文を圧縮していた) とは構造が違う。
3. **reduce (`summarizeThreadDigest`、不変)**: `combined`(**refine前**の
   テキスト) を入力に■現状を1回生成 — refineが成功しても失敗しても
   スキップされても、■現状の入力は常に同じ。

**安全策 (2つ)**:
- **短いスレッド (3通以下) はrefineをスキップ** — 無加工の列挙が既に
  十分簡潔なため、追加のモデル呼び出しは不要と判断。
- **refineが失敗 (モデルエラー) しても要約全体を失敗させない** —
  無加工の列挙へフォールバックする。`FakeTranslationService`に
  `configureRefineThreadEntriesFailure(_:)`(このメソッドだけを狙って
  失敗させる、`blockedTexts`と同じ発想) を追加してテスト。

**情報保持の指示**: `refineThreadEntriesInstructions`は「決定事項・依頼/
質問・数値・日付・固有名詞は1つも落とさない」を最優先ルールとして明記し、
「田中が候補を提示し、佐藤が予算を確認、5000円程度で決定」のような
複数メッセージにまたがる統合を、帰属 (誰が言ったか) を保ったまま行うこと
を許可する。`summarizeThreadEntryInstructions`(Task #160フォローアップ2)
と同じ2つの教訓を引き継ぐ: メタ言及の明示的禁止 + 良い例/悪い例、および
例文の題材を実際のフィクスチャと無関係なもの (会議室の予約) にする
(Task #160フォローアップ2で例文とフィクスチャの題材が偶然一致し
ハルシネーションを誘発した反省を先取りして適用)。

**出力形式の違い**: refineの出力行は`summarizeThreadEntry`の入力/
`■現状`向け行と違い`"[日付] 差出人:"`ブラケットを持たない — 複数メッセージ
にまたがる統合行を単一のブラケットで表せないため、実名 (入力にある名前
のみ) を文中に直接使わせる。

### ラベル・サニタイズの適用位置

`refineThreadEntries`の出力は`currentStatusInstructions`と同じ「ラベル1行
+ 内容」形式 (`ThreadDigestLabel.progress`から始める) にし、
`SummaryOutputSanitizer.sanitize(_:labels:)`をそのまま適用できるように
した。`ThreadEntryMetaCommentaryStripper`もこの出力に通す — ただし
refineの出力は複数行 (1行1トピック) なので、`strip(_:)`を**行を保持した
まま各行を独立に処理する**よう一般化した (以前は改行を単一スペースに
畳んで1行として処理していた — `summarizeThreadEntry`の出力は元々1行
なので挙動は変わらないが、refineの複数行出力ではそのままでは行構造を
壊してしまうため)。

### 進捗表示: `ThreadSummaryProgress`

`onProgress`の型を、単純な`(current: Int, total: Int)`から
`ThreadSummaryProgress`(`.extractingMessage(current:total:)`/`.refining`
の2ケース) へ拡張した — refine実行中を「仕上げ中…」としてUIへ伝える
ため。`ThreadDetailView`側の変更は`threadSummaryProgress`の型と、進捗
テキストを組み立てる`progressLabelText(for:)`の追加のみ (#145 が並行
編集中のUI文字列ファイルには触れていない)。

### テスト

`TranslationServiceSummarizeThreadTests`に新規4ケース追加 (既存5ケースも
新しいカウンタ/イベント型に追従): refine閾値以下 (3通) でスキップされる
こと、閾値超 (4通) でrefineがちょうど1回実行されその結果が■経緯になる
こと (■現状の入力は依然として未refineの`combined`)、refine失敗時に
無加工列挙へフォールバックすること、`onProgress`が`.refining`イベントを
（該当する場合のみ）ちょうど1回追加で報告すること。
`ThreadEntryMetaCommentaryStripperTests`に2ケース追加: 新設の
「この経緯では/この経緯は」オープナー認識、複数行入力での改行保持。
`HybridTranslationServiceTests`に`refineThreadEntries`の委譲確認を追加。
`make test`/`make mac`/`make ios` green。

**実FoundationModels確認** (`scratchpad/summary-repro`、Task #153/#160と
同じ6メッセージ架空フィクスチャ、6通 > refine閾値3なのでrefineが必ず
発火) を3回実行、各回で refine 前 (`summarizeThreadEntry`だけを自前で
ループした無加工6行) と refine 後 (`summarizeThread`の最終出力) を両方
出力させて比較した。判定基準は「数値・固有名詞・結論の保持 + 冗長さの
減少」:

- 3回とも、■経緯の行数が6行(before) → 4〜5行(after) に減少 (目安の
  「メッセージ数の半分〜同数程度」の範囲内)。
- 3回とも、金額(`5000円`)・曜日+時刻(`金曜19時`)・会場の固有名詞
  (`駅前の個室居酒屋`/`会社近くのイタリアン`)・登場人物名 (`田中太郎`/
  `佐藤花子`/`Alice Example`) はすべて維持され、帰属 (誰が言ったか) も
  正しく保たれていた。メタ言及 (「この経緯では」等) は3回とも出現せず。
  1回だけ (run 1) 複数メッセージが1行に統合される様子が明確に確認できた
  (「佐藤花子が予算の想定額はまだ決まっていないと述べ、田中太郎が予算は
  1人あたり5000円程度で...とした」— 2メッセージが1行に統合)。

  before (run 1、refine前の無加工6行):

  ```
  [07/20] 田中太郎: 駅前の個室居酒屋と会社近くのイタリアンの2つの会場候補について意見を伺いたい。 どちらの会場がよいか確認したい。
  [07/20] 佐藤花子: 予算の想定額はまだ決まっていない。
  [07/20] 田中太郎: 予算は1人あたり5000円程度を考えています。 イタリアンのお店だとその予算内で収まりそうです。
  [07/20] Alice Example: 予算感も分かりました。 イタリアンに賛成です。 日程は来週の金曜19時からでよいでしょうか。
  [07/20] 佐藤花子: 金曜19時にイタリアンのお店を予約できるか確認したい。 予約の件について田中さんに確認したい。
  [07/20] 田中太郎: イタリアンのお店に来週金曜19時に予約を入れる。 予約が取れ次第、改めてこのスレッドで共有する。
  ```

  after (run 1、refine後の■経緯、6行 → 4行):

  ```
  ■経緯
  ・田中太郎が駅前の個室居酒屋と会社近くのイタリアンの2つの会場候補を提示し、どちらの会場がよいか意見を求めた。
  ・佐藤花子が予算の想定額はまだ決まっていないと述べ、田中太郎が予算は1人あたり5000円程度で、イタリアンのお店ならその予算内で収まりそうだとした。
  ・Alice Exampleが来週の金曜19時にイタリアンに賛成し、佐藤花子が金曜19時にイタリアンのお店を予約できるか確認したいと、予約の件について田中さんに確認したいと述べた。
  ・田中太郎がイタリアンのお店に来週金曜19時に予約を入れると述べ、予約が取れ次第、改めてこのスレッドで共有すると返答した。
  ```

`scratchpad/summary-repro`はリポジトリ外・非コミット (既存の慣例どおり)。

**副次的に観測した点 (今回のスコープ外、指示違反だが実害なし)**: 3回中
2回で、■経緯の各行が指示で明示的に禁止した「・」始まりの箇条書き記号を
付けて返ってきた (1回は付けなかった)。`SummaryText`は`"■"`始まりの行だけ
太字にする汎用的な整形のため、`"・"`始まりの行はそのまま地の文として
表示され、レイアウトは崩れない — 実害は無いため、追加のイテレーション
は行わなかった。再発・見た目上の違和感が実機で報告されれば、指示文の
禁止表現をさらに強めることを検討する。

**未確認**: 「仕上げ中…」の進捗表示・■経緯の行数減少そのものの実機/
シミュレータでのスクリーンショット確認はしていない (Foundation Models
のシミュレータ既知不調のため)。

## ■現状のハルシネーションを多層防御で根治 (Task #160フォローアップ4、最優先)

**背景**: ユーザーからの最優先フィードバック「■現状に全然関係ない話が
出てきた」。ユーザー本人からの明示指示「優先して対応してOTA配信して」。

### 根本原因の特定: 指示文自身の例文漏れ

`FoundationModelsTranslationService.currentStatusInstructions`(■現状専用の
指示文) の【出力例】が、Task #160/#160フォローアップ3の実FM確認に
一貫して使ってきた6メッセージ架空フィクスチャ (イタリアン・田中・
5000円・金曜19時) と**同じ題材**の具体的な例文
(`"水曜14時にイタリアンの店で開催することが合意され、予約はまだ取れて
いない。田中が予約を担当し、取れ次第スレッドで共有する予定。"`) の
ままだった — `summarizeThreadEntryInstructions`/`refineThreadEntriesInstructions`
が既に踏んだ「指示文の例文の題材そのものが出力へ漏れる」バグ
(Task #160フォローアップ2/3) と同型で、この指示文だけ修正対象から
漏れていた。しかもこの例文は自分たちの実FM確認フィクスチャと題材が
一致していたため、確認のたびに「本当に入力を読んでいるのか、それとも
例文を再現しているだけなのか」を区別できておらず、過去の確認では
発見できなかった (実際の入力にたまたま同じ単語が含まれていたため、
漏れがあっても正しい出力に見えてしまっていた)。

### 実装 (多層防御)

1. **例文を完全に抽象化**: `currentStatusInstructions`の【出力例】を、
   数値・固有名詞・カタカナ語を一切含まない抽象的な1文
   (`"いずれかの案で進めることが合意され、詳細はまだ決まっていない。"`)
   へ差し替えた。同じ理由で`summarizeThreadEntryInstructions`/
   `refineThreadEntriesInstructions`の例文 (会議室・鈴木・木村・水曜14時
   などの具体的な題材) も、防御的にすべて抽象的な言い回しへ差し替えた。
2. **接地 (grounding) ルールの明記**: `currentStatusInstructions`に
   【入力に無い話題を書かない(最重要)】節を新設 — 「入力のどの行にも
   書かれていない事実・話題・固有名詞・数値を一切書かない」「一般的な
   知識や『よくあるメールのやり取り』のパターンで補うことを禁止」
   「結論・次のアクションが判断できない場合は無理に埋めず"(未決)"とだけ
   書く」ことを明示した。
3. **出力検証 + 1回だけの再生成 + 機械的フォールバック**: 新設
   `ThreadDigestGroundingCheck`(`OtegamiCore`) が、■現状候補の中の
   数値・カタカナ語(2文字以上)・ラテン文字語(2文字以上)が、per-message
   抽出結果 (`combined`) にすべて文字列として出現するかを検証する —
   完全な事実確認ではなく「発明された固有名詞・数値」を捕まえる軽量な
   ヒューリスティック。漢字の一般語はチェック対象外 (要約は言い換えが
   前提のため、漢字語の完全一致を要求すると正常な出力まで弾いてしまう —
   「過剰に厳しくして正常出力を落とさない」という仕様上の要求への対応)。
   検証に落ちたら`summarizeThreadDigest`を1回だけ再生成し、それでも
   ダメなら■現状を「最後のメッセージの抽出内容 (`perMessageLines.last`)」
   そのままへ機械的にフォールバックする — ハルシネーションを出すくらい
   なら保守的に。この経路は`FakeTranslationService`に
   `configureSummarizeThreadDigestResponses(_:)`(意図的にグラウンディング
   に失敗する応答をテストで注入できる) を追加してテスト。
4. **実FM確認1周目で見つかった残存問題とその対策**: 抽象化した例文でも、
   短い(2通の)スレッドで■現状が「(実在する差出人名)が確認を行い、結果が
   出次第共有する予定。」という**入力に無い後続アクションを作り出す**
   現象が再現した — 差出人名は実在するため`ThreadDigestGroundingCheck`
   はすり抜ける (固有名詞は実在するが行為そのものが入力に無い、という
   このグラウンディング検査のスコープ外のケース)。原因は例文の「担当者が
   確認を行い、結果が出次第共有する予定」という後続アクションの節が、
   内容の薄いスレッドで目安の文数 (2〜4文) を埋める「埋め草」として
   使われていたこと。対策として、【内容ルール】に「文数はあくまで目安、
   入力が薄ければ無理に水増ししない (入力に無い後続アクションを作って
   まで文数を満たさない)」を明記し、例文自体も後続アクションの節を
   含まない1文だけに短縮した。再修正後、同じ短いスレッドフィクスチャで
   3回とも解消を確認 (下記)。

### テスト

`ThreadDigestGroundingCheckTests`(新規、8ケース): 報告されたパターンを
実際に検出できること (数値・カタカナ語の不一致)、正常な (言い換えられた)
出力を誤って弾かないこと (漢字語の言い換え・パラフレーズは検査対象外)、
カタカナの長音記号・中黒を含む語が1トークンとして正しく扱われること、
空入力・トークンなし入力の扱い。`TranslationServiceSummarizeThreadTests`
に2ケース追加: グラウンディング失敗時に1回だけ再生成しグラウンディング
成功した再生成結果を使うこと、2回とも失敗した場合に最後のメッセージの
抽出内容へ機械的にフォールバックすること。`make test`/`make mac`/
`make ios` green。

**実FoundationModels確認** (`scratchpad/summary-repro`) — 従来の6メッセージ
フィクスチャに加え、誘発されやすいと想定した3種類の新規フィクスチャを
追加し、計4種類 × 3回 = 12回実行 (2イテレーション目):

- **`thread`** (6メッセージ、往復・結論あり): 3回とも■経緯/■現状の
  内容は入力に基づき、無関係な話題の混入なし。
- **`thread-short`** (2メッセージ、refine閾値以下): イテレーション1回目で
  「(実在の差出人名)が確認を行い、結果が出次第共有する予定」という入力に
  無い後続アクションの創作が3回中1回発生 — 上記「実装」節4番の指示文
  修正後、再実行した3回とも「定例は15時に決定された。」のみの1文へ収束
  (無理な水増し無し)。
- **`thread-open`** (4メッセージ、結論が出ていない未決スレッド): 3回とも
  「日程が未定のまま、会場の検討が継続されている」のように、入力にある
  事実だけで簡潔にまとまり、無関係な話題の混入なし。
- **`thread-notify`** (4メッセージ、通知メールのみ・往復なし): 3回とも
  ログイン通知・支払い期限・利用明細・パスワード変更という4件の実際の
  通知内容だけを反映し、無関係な話題の混入なし (2回、■現状の末尾に
  独立した"(未決)"という行が付く軽微な体裁の癖はあったが、内容自体は
  入力に基づいていた — 実害なしのため今回は追加対応せず)。

以上、二重の実FM確認 (計15回実行) で、報告された「■現状に全然関係ない
話が出てきた」というパターンの再現は無かった。`scratchpad/summary-repro`
はリポジトリ外・非コミット (既存の慣例どおり)。

**未確認**: `thread-notify`の「(未決)」の独立行の体裁の癖、および
以前の節で既出の■経緯の「・」箇条書き記号混入・■現状の箇条書き+空行
混じり形式は、いずれも今回のスコープ (ハルシネーション根治) とは別の
軽微な体裁の問題として残っている。実機での違和感が改めて報告されれば
対応する。

## テスト

- `OtegamiTranslationTests`: `FakeTranslationService` の状態遷移、
  `ParagraphSplitter`（空行分割・空白トリム・空入力等）、
  `MessageLanguageDetector`（英文/和文/混在/短文/記号のみ）、
  `TranslationChunker`（上限内はそのまま・文境界優先分割・句読点の無い
  長文の強制分割・日本語の句点対応）、`SentenceSplitter`（ASCII/日本語
  終端・改行のみ・終端なし1文・空白トリム・空入力、上記 Task #81 節参照）、
  `HybridTranslationService`（翻訳/要約それぞれが対応するエンジンだけに
  委譲されること、`availability`が翻訳エンジン由来であること、上記
  Task #159 節参照）。
- `OtegamiTranslationAppleTests`: `TranslationLanguage.locale`のマッピング
  のみ（実エンジンは実機依存のため自動テスト不可、上記 Task #159 節参照）。
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
