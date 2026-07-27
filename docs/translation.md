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

## テスト

- `OtegamiTranslationTests`: `FakeTranslationService` の状態遷移、
  `ParagraphSplitter`（空行分割・空白トリム・空入力等）、
  `MessageLanguageDetector`（英文/和文/混在/短文/記号のみ）、
  `TranslationChunker`（上限内はそのまま・文境界優先分割・句読点の無い
  長文の強制分割・日本語の句点対応）。
- `TranslationEngineTests`: `MessageTranslator` のキャッシュヒット/ミス、
  エンジン識別子が変わった場合の再翻訳、失敗時の状態、`invalidate()`、
  上限を超える段落がチャンク分割されたうえで1つの `TranslatedParagraph`
  に再結合されること。
- `OtegamiTranslationFoundationModelsTests`: 実機のオンデバイスモデルに対する
  結合テスト（可用性に応じて自動スキップ）。
- `SyncEngineTests`（`BodyFetcherTests`）: 本文取得時に
  `message.detectedLanguage` が正しく設定されることの検証。
- `OtegamiStoreTests`（`AppDatabaseTests`）: v15 migration
  （`messageTranslation` テーブル・`message.detectedLanguage` 列）の
  マイグレーション成否とレコードのラウンドトリップ。

いずれも `make test` に含まれます。
