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

- **コンテキストサイズ**: オンデバイスモデルのコンテキストは実測 8192 トークン。
  `ParagraphSplitter` は空行区切りで段落分割しますが、改行のない非常に長い
  1段落（例: 改行なしで貼り付けられた長大なログやコード）は理論上これを
  超える可能性があります。現状のエンジン層はこのケースを明示的にはハンドリング
  しておらず、`LanguageModelSession` 側のエラー（`GenerationError` 系）が
  `TranslationServiceError.failed` として呼び出し側に伝わるのみです。
  UI フェーズで「長すぎる段落はスキップ/切り詰め」等の扱いを検討する必要が
  あります。
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
- **UI 未実装**: このドキュメントの時点ではエンジン層のみで、翻訳バー・
  段落長押し・「英語で返信を下書き」等の実際の画面操作は次フェーズです。

## テスト

- `OtegamiTranslationTests`: `FakeTranslationService` の状態遷移、
  `ParagraphSplitter`（空行分割・空白トリム・空入力等）、
  `MessageLanguageDetector`（英文/和文/混在/短文/記号のみ）。
- `TranslationEngineTests`: `MessageTranslator` のキャッシュヒット/ミス、
  エンジン識別子が変わった場合の再翻訳、失敗時の状態、`invalidate()`。
- `OtegamiTranslationFoundationModelsTests`: 実機のオンデバイスモデルに対する
  結合テスト（可用性に応じて自動スキップ）。
- `SyncEngineTests`（`BodyFetcherTests`）: 本文取得時に
  `message.detectedLanguage` が正しく設定されることの検証。
- `OtegamiStoreTests`（`AppDatabaseTests`）: v15 migration
  （`messageTranslation` テーブル・`message.detectedLanguage` 列）の
  マイグレーション成否とレコードのラウンドトリップ。

いずれも `make test` に含まれます。
