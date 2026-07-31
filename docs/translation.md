# オンデバイス翻訳・要約

メール本文の翻訳と AI 要約を、すべて Apple のオンデバイスモデルで行う
機能のドキュメント。ネットワークには一切送信されない。UI の配置・見た目
は `docs/design-system.md` を参照 (このファイルはエンジン層の設計と
挙動のみを扱う)。

## エンジン構成

翻訳と要約は**別々のフレームワーク**が担当する。

```
OtegamiTranslation                 — プロトコルと純粋ロジック (Linux 可)
  ├─ TranslationOnlyService          翻訳系4メソッドのprotocol (translate/
  │                                  translateParagraphs/translateStream/
  │                                  availability)
  ├─ TranslationService              TranslationOnlyServiceをrefineし、
  │                                  要約系3メソッド (summarize/
  │                                  summarizePlain/summarizeThreadEntry)
  │                                  を追加宣言
  ├─ HybridTranslationService        翻訳呼び出しをAppleTranslationServiceへ、
  │                                  要約呼び出しをFoundationModelsTranslation
  │                                  Serviceへ振り分けるだけの薄い合成
  ├─ FakeTranslationService          決定的な実装 (テスト用)
  ├─ ParagraphSplitter/SentenceSplitter/TranslationChunker
  │                                  段落・文・チャンク分割 (純粋な文字列処理)
  └─ MessageLanguageDetector         言語判定 (NaturalLanguage)

OtegamiTranslationApple             — 翻訳の実装 (Translation framework、iOS 18+/macOS 15+)
  ├─ AppleTranslationService         TranslationOnlyServiceの実装
  └─ TranslationSessionCoordinator   TranslationSessionとSwiftUIの橋渡し (@MainActor)

OtegamiTranslationFoundationModels  — 要約の実装 (Foundation Models framework、iOS/macOS 26+)
  └─ FoundationModelsTranslationService  LanguageModelSessionベースの要約実装

TranslationEngine                   — キャッシュと永続化のオーケストレーション
  ├─ MessageTranslator               キャッシュ確認→エンジン呼び出し→永続化
  └─ MessageTranslationState         UI層向けの状態モデル

OtegamiCore                         — QuoteStripper/SummaryInputBuilder/
                                       SummaryOutputSanitizer/
                                       ThreadEntryMetaCommentaryStripper/
                                       ThreadDigestGroundingCheck (未使用、後述)
```

呼び出し側 (`MessageTranslator`、アプリ層) は常に `TranslationService`/
`TranslationOnlyService` プロトコルだけを見る。`FoundationModels` を
import しているのは `OtegamiTranslationFoundationModels` の1ファイル、
`Translation` を import しているのは `OtegamiTranslationApple` の
数ファイルだけ。`AppEnvironment.translationService` が実際に保持するのは
`HybridTranslationService` のインスタンス — 呼び出し側はこの型がどちらの
メソッド群をどこへ転送しているか一切知る必要がない。

### なぜ翻訳と要約でエンジンが違うのか

- **翻訳**: Apple `Translation` フレームワーク (`TranslationSession`) —
  翻訳専用にチューニングされた NMT モデル。iOS 18+/macOS 15+ で利用可能
  (本アプリの対応OSは既に26+なので条件を満たす)。
- **要約**: Apple `FoundationModels` フレームワーク
  (`LanguageModelSession`) — 汎用オンデバイス LLM (「Apple Intelligence」)。
  iOS/macOS 26+ 限定。要約は自由文生成・構造化出力・指示追従が必要なため、
  翻訳専用モデルではなく汎用 LLM を使う。
- 翻訳は元々 `FoundationModelsTranslationService` が担っていたが、専用
  NMT の翻訳品質・速度を活かすため Apple `Translation` フレームワークへ
  切り替えた。要約はそのまま `FoundationModelsTranslationService` が担う。
- `TranslationLanguage` は `english`/`japanese` の2ケースのみを持つ閉じた
  enum — このアプリの翻訳は英文メールを日本語で読む方向専用で、他の言語
  ペアは扱わない。翻訳可否・言語データのダウンロード要否は
  `Translation.LanguageAvailability.status(from:to:)` (英語↔日本語ペア)
  で判定し、未ダウンロードならシステムのダウンロード誘導 UI を
  (`TranslationSessionCoordinator.prepareTranslation(to:)`) トリガーする。

### 言語判定は独立した可用性を持つ

`MessageLanguageDetector`（`NLLanguageRecognizer` ベース）は
`TranslationService` に含まれていない。LLM を使わない軽量な処理であり、
`NaturalLanguage` framework は本パッケージが対象とする全ての Apple OS
バージョンで利用可能 (Foundation Models/Translation framework のような
バージョン限定ではない) だからである。`SyncEngine.BodyFetcher` が本文
取得直後に同期的に実行し、結果を `MessageRecord.detectedLanguage`
（BCP-47、例: `"en"`/`"ja"`）に保存する。この判定結果は「翻訳ボタンを
表示するか」の条件には使わない (後述) — 自動翻訳を起動するかどうかの
判定にのみ使う。

## 翻訳 UX

- **翻訳ボタンは常時有効**: メッセージの本文が読み込まれていれば、検出
  言語に関係なく常にタップできる (`MessageDetailFooterToolbar`)。過去に
  言語判定 (`detectedLanguage == "en"`) をボタン表示条件にしていたが、
  実機で「英語メールなのにボタンが出ない」という誤判定由来の不具合が
  繰り返し報告されたため、この判定を表示条件から完全に撤去した。実際の
  翻訳は英語→日本語の一方向専用のまま。
- **自動翻訳はオプトイン**: 既定 OFF (設定 → メールビューア → AI 機能
  →「英文を自動で翻訳」)。ON にすると、`message.detectedLanguage != "ja"`
  (確信を持って日本語と判定されていない) かつアプリの表示言語が英語で
  ない場合に自動的に翻訳を開始する。実際の翻訳呼び出し時は
  `AppleTranslationService` が `source: nil` (Translation framework 自身
  による自動判定) でセッションを構成するため、この起動ゲートが誤って
  通過しても、実際に英語以外のテキストへ誤った「英語として」翻訳が
  適用されるリスクはない。
- **一発で原文に戻せる**: メッセージ単位の 訳文/原文 切替 (フッター
  ツールバー) に加え、`TranslatedBodyView` は段落ごとに長押しでその段落
  だけ原文表示にできる (`MessageTranslationRecord.paragraphs`、原文と
  訳文が段落単位で1:1対応)。
- **段落単位でキャッシュ**: 翻訳結果は `messageTranslation` テーブルに
  メッセージ1件につき最大1行、段落ごとの原文・訳文ペアとして永続化
  (`MessageTranslator`)。同じメッセージを再度開いたときは再翻訳せず
  即座に表示する。キャッシュの有効性はソース/ターゲット言語とエンジン
  識別子 (`"apple-translation"`) の一致で判定し、エンジンが変われば
  自動的に無効化・再翻訳される。
- **HTML メールはレイアウトを保持**: `HTMLTranslationController` が
  WKWebView 内の DOM テキストノードを収集し、`MessageTranslator
  .translateHTMLTextNodes` で翻訳、結果を同じノードへ書き戻す (訳文/原文
  はノードの `textContent` を入れ替えるだけ)。表・画像・罫線などの
  レイアウト・スタイルは変更しない。DOM 抽出に失敗した場合や
  `htmlTranslationController` が未接続の場合は、`HTMLTextExtractor` で
  HTML を平文化するプレーンテキスト経路へ自動フォールバックする。

## 要約の3パート構造 (■要約/■伝えたいこと/■アクション)

1通のメッセージの AI 要約は、固定の3パート・ラベル付き構造で出力される
(`FoundationModelsTranslationService.summarizeInstructions`):

```
■要約
(内容の要約 — 新規本文に実際に書かれている事柄を、書かれている順に
漏れなく説明する。一般化しすぎない)

■伝えたいこと
(送信者の意図・トーン、1文程度)

■アクション
(受信者に求められる対応。不要なら「特になし」)
```

- `sentenceCount` は■要約パートの文数のみを指定する (■伝えたいこと/
  ■アクションは常に1文程度の固定長)。既定は2文、要約シートの「詳しく
  要約」メニューから約10文の詳細版を選べる (段落分けを許可し、時系列
  順に詳しく書く指示に切り替わる)。
- 出力は `SummaryOutputSanitizer.sanitize(_:)` を必ず通してから返す —
  生成された文字列から最初の完全な3パートブロックだけを抽出し、それ
  以降 (ラベルの反復、指示文の断片のリーク) を切り落とす防御的な後処理。
  指示文側の対策 (出力形式の厳格な指定・具体例の提示) と合わせた二段
  構えの防御。
- 差出人・宛先の名前を出力中の主語・行為者にすることを禁止し、常に
  「この返信」を主語にするよう指示している (新規本文の宛名を送信者名と
  取り違えるハルシネーションへの対策)。
- 新規本文に実際に書かれていない内容を推測・一般化で補うことを明示的に
  禁止している。

## 引用の分離 (QuoteStripper) — 要約対象は新規本文のみ

**要約の対象は「このメールが新しく書いた部分」だけであり、引用された
過去のやり取りの内容そのものはモデルに一切渡さない。**

1. **`QuoteStripper` (`OtegamiCore`)**: 純関数、Linux 互換
   (WebKit/NSAttributedString 不使用)。本文中の引用マーカー (Gmail の
   `gmail_quote`/`gmail_attr` div、Apple Mail/Thunderbird の
   `<blockquote>`、Outlook の `divRplyFwdMsg` id、Yahoo Mail の
   `yahoo_quoted`、ProtonMail の `protonmail_quote`、クラス名を持たない
   `border-left`/`border-top` スタイルの引用 div、プレーンテキストの
   `> ` 引用行、「On ... wrote:」「-----Original Message-----」
   「〜さんは書きました」「差出人: .../送信日時: ...」ヘッダブロック等)
   のうち最も早い位置を検出し、`SeparatedText { newText, quotedText }`
   として新規部分と引用部分を分離する
   (`separatingQuotedText(fromHTML:)`/`separatingQuotedText(fromPlainText:isReply:)`)。
   マーカーが見つからない、または打ち切り後の本文が40文字未満(フォール
   バック — 「転送だけして新規コメントなし」のようなメールで要約対象が
   空になるのを防ぐ) の場合は `quotedText` が空文字列になり `newText` に
   全文が入る。
   - `isReply` (呼び出し元は `message.inReplyTo != nil` で判定) が
     `true` のときだけ、確証の薄い追加パターン (「wrote:」を欠いた
     「On ... <address>」行、裸の「From: Name <address>」行等) を有効化
     する — 返信だと確定できていない本文に適用すると地の文を誤検知する
     リスクがあるため。
   - `separatingQuotedText(plainText:html:isReply:)`: `plainText` 側で
     マーカーが見つからなければ `html` 側でも試す救済フォールバック
     (mailcore2 由来の合成 `plainText` がマーカー検出パターンと一致しない
     ケースへの対応)。`MessageView.sourceTextForSummary()` が使う。
2. **`SummaryInputBuilder` (`OtegamiCore`)**: `QuoteStripper` が検出した
   結果を要約入力へ組み立てる純関数。**引用が実際に存在したかどうか
   (`Bool`) だけを受け取り、引用テキストの内容自体は一切受け取らない**
   —引用が存在する場合、新規本文の前に固定の注記1行
   `(この返信は過去のやり取りへの返信。引用本文は省略している)`
   (`SummaryInputBuilder.quotedContextNoteLine`) を置くだけで、実際の
   引用文はモデルの入力に一度も現れない。引用が無い場合は新規本文
   (`newText`) がそのまま入力になる。
   - **この設計に至った経緯**: 当初は引用部分を「文脈」としてラベル付き
     で入力に含め (文字数上限・時系列順・語彙禁止などのプロンプト
     チューニングで) 要約対象から除外しようとしていたが、実機で
     「モデルに引用の内容を見せている限り、何らかの確率でそこから何かを
     拾ってしまう」ことが繰り返し確認された。根治策として発想を転換し、
     引用の内容自体を一切モデルに渡さない構造に変更した — 何も渡って
     いなければ、拾いようがない。
3. **`summarizeInstructions`/`summarizePlainInstructions`** は上記の注記
   行の意味 (「これは過去のやり取りへの返信であることを示すだけで、
   過去のやり取り自体の内容は入力に含まれていない」) をモデルに説明し、
   注記行自体を要約対象・出力に含めないよう指示する。
4. **適用範囲は要約のみ**: `sourceTextForTranslation()` (翻訳・本文
   表示が共有) は変更しない — 翻訳・本文表示は受信した通りの全文
   (引用込み) を扱う。

## スレッド全体の AI 要約

複数メッセージのスレッドをアコーディオン表示しているとき、
`ThreadDetailView` から「スレッド全体を要約する」を実行できる (1通の
メッセージの要約とは独立した別のボタン・状態・シート)。

- 時系列順に並んだ各メッセージについて、`QuoteStripper` で新規本文を
  抽出し (単一メッセージ要約の `SummaryInputBuilder` は使わない —
  引用の有無を注記するだけのラッパーはここでは不要)、
  `TranslationService.summarizeThreadEntry` で「削らずに書き出す」事実
  抽出 (圧縮ではない — 決定事項・依頼/質問・数値・日付・固有名詞を
  一切省略しない) を1メッセージ1回ずつ行う。差出人名を主語にしない
  ルールは維持しつつ、「この返信では〜が述べられている」のような説明調
  (メタ言及) を避け、事実を直接・断定的に書くよう指示している。
  `ThreadEntryMetaCommentaryStripper` (`OtegamiCore`) がこの指示への
  後処理の保険として、自己参照の主語で始まる文だけを狭くスコープして
  書き換える。
- 出力は各メッセージの `"[日時] 差出人: 抽出結果"` という行を、空行
  区切りで時系列に**そのまま並べるだけ**。モデルによる要約の要約 (2段目
  以降の圧縮・統合パス) は行わない — 複数段のモデル呼び出しを重ねると
  情報損失・ハルシネーション (指示文の例文の題材が出力に漏れる、入力に
  無い後続アクションを作り出す等) が繰り返し実機で確認されたため、
  最終的に「per-message の事実抽出結果をそのまま時系列に並べる」という
  最もシンプルな形に収束した。ラベル (■経緯/■現状 等) は使わない。
- 進捗表示: メッセージ数が多いスレッドほどモデル実行回数が増えるため、
  「n/m 通目を要約中…」を表示する。
- `ThreadDigestGroundingCheck` (`OtegamiCore`): 生成結果が入力に接地して
  いるか (数値・カタカナ語・ラテン文字語が入力に実在するか) を検証する
  軽量ヒューリスティックとして実装されているが、**現在は呼び出し元が無い**
  — 複数段パイプラインを撤去した際に不要になったため。将来「モデルに
  もう一段何かを書かせる」設計が必要になった場合の再利用に備えて型・
  テストは残してある。

## ガードレール誤発動の寛容化

Apple Foundation Models にはコンテンツの安全性ガードレールがあり、
実際には問題のない文面 (マーケティングメールのセールス文句、怒った
顧客からのクレームメールなど) でも誤って `guardrailViolation` を返す
ことがある (Apple 既知の挙動で、アプリ側で無効化する API はない)。
これに対する現在の緩和策:

1. **チャンク単位でガードレール発動を検知**: `FoundationModelsTranslationService
   .mapEngineError` が `LanguageModelError.guardrailViolation`
   (iOS/macOS 27+) と `LanguageModelSession.GenerationError.guardrailViolation`
   (26+, deprecated in 27+) の両方を `TranslationServiceError.contentBlocked`
   にマップする。
2. **ブロックされたチャンクだけ文単位で再試行**: `MessageTranslator
   .retryBlockedChunkBySentence` が、ガードレールに引っかかったチャンク
   を `SentenceSplitter` で文単位に分割し、1文ずつ再試行する。ガード
   レールが実際に反応する文だけが原文のまま残り、同じチャンク内の無害な
   文は救済される。再帰は1段まで — 文単位で再びブロックされても、それ
   以上 (単語・節単位) へは分割しない。
3. **部分ブロックは失敗にしない**: 1文でも翻訳できていれば、そのチャンク
   /段落は「部分的にブロックされた」扱いで成功パスに乗る
   (`TranslatedParagraph.wasBlocked`)。全チャンクが1文も翻訳できなかった
   場合だけメッセージ全体を `.failed` (`TranslationServiceError
   .contentBlocked`) にする。UI 側は全体が成功かつ一部ブロックされた
   場合、赤い失敗表示ではなく控えめな注記で「一部の文は翻訳できません
   でした」を出す (スキップされた段落は原文のまま表示)。
4. **診断ログ**: どのチャンク/文が `.contentBlocked` になったか (本文
   そのものではなく先頭20文字のみ、プライバシー配慮) を OSLog に記録
   する — ガードレールの誤発動条件は Apple 側が公開しておらず再現性が
   低いため、実機ログから後追いで切り分けるための計装。

## サポートする言語

翻訳は**英語→日本語の一方向専用**に固定されている
(`TranslationLanguage` enum は `.english`/`.japanese` の2ケースのみ)。
言語ペアの対応可否・ダウンロード要否は `Translation.LanguageAvailability
.status(from:to:)` (英語↔日本語ペア) で判定し、未ダウンロードならシステム
のダウンロード誘導 UI をトリガーする。翻訳ボタン自体は言語データの
ダウンロード状態に関係なく常時有効 — 未ダウンロードは「押した結果の
エラー文言」として表面化する。

要約 (`FoundationModelsTranslationService`) は出力言語 (`targetLanguage`)
を引数に取れる作りだが、実際の呼び出し元はすべて日本語出力のみを使用
している。

## 既知の制限: iOS Simulator の `.app` プロセスからの呼び出し

**Foundation Models (要約) を iOS Simulator 上のアプリ `.app` プロセス
から呼び出すと、一貫して次のエラーで失敗する:**

```
FoundationModels.LanguageModelError error -1.
```

同じホスト機・同じタイミングで `swift test --filter
FoundationModelsTranslationServiceTests` (サンドボックス化されていない
プレーンな macOS プロセス) を実行すると、同じ呼び出しコード・プロンプト
で毎回成功する。可用性チェック (`SystemLanguageModel.default.availability`)
自体は両方の実行方式で `.available` を返す — 可用性チェックやコードの
不具合ではなく、**サンドボックス化された Simulator の `.app` プロセスから
Apple の on-device 推論ブローカーへの通信が、何らかの権限/セッション
要件を満たせていない**、Simulator/ツールチェーン固有の制限と判断して
いる。`docs/verify.md`/`docs/ci.md` が記録する他の「simulator/toolchain
固有の不具合」と同じ性質のものであり、アプリ側の不具合とは切り離して
扱う。

- 翻訳 (Apple `Translation` フレームワーク) の実エンジン部分も自動テスト
  不可であり、同じ「シミュレータ既知不調」領域に該当する可能性が高いと
  判断しているが、Foundation Models の `error -1` ほど明確な形では個別に
  確認できていない。
- **この制限が UI 検証に与える影響**: 翻訳・要約ボタンをタップした際の
  エラー表示・「再試行」ボタン自体は Simulator 上でも正しく動作する
  (失敗パスの UI は検証できる)。翻訳・要約が実際に成功した状態の画面は、
  Simulator では確認できない。自動化されたスクリーンショット検証は
  `OTEGAMI_UITEST_FAKE_TRANSLATION=1` (launch environment) で
  `FakeTranslationService` に差し替えて行う (実際の Foundation
  Models/Translation フレームワークの出力品質は検証対象外になる)。
  検証の一般的な考え方・他の既知不調は `docs/verify.md` を参照。

## プライバシー

翻訳・要約はすべてオンデバイスで完結する (`LanguageModelSession`/
`TranslationSession` はどちらもネットワークを使わない)。メール本文が
外部サーバーに送信されることはなく、この点は「複数アカウント横断」と
並ぶ本アプリの差別化要素として重要 — 特にメールという個人情報・機密
情報を含みやすいデータに対して、翻訳・要約のために外部の翻訳 API/
クラウド LLM にテキストを送る必要が一切ない設計になっている。

## テスト

- `OtegamiTranslationTests`: `FakeTranslationService` の状態遷移、
  `ParagraphSplitter`/`SentenceSplitter`/`TranslationChunker` の分割
  ロジック、`MessageLanguageDetector`、`HybridTranslationService`
  (翻訳/要約それぞれが対応するエンジンだけに委譲されること)。
- `OtegamiTranslationAppleTests`: `TranslationLanguage.locale` の
  マッピング、`AppleTranslationService.mapEngineError` の分類ロジック
  (実エンジンは実機依存のため自動テスト不可)。
- `OtegamiTranslationFoundationModelsTests`: 実機のオンデバイスモデルに
  対する結合テスト（可用性に応じて自動スキップ）。
- `TranslationEngineTests`: `MessageTranslator` のキャッシュヒット/
  ミス、エンジン識別子が変わった場合の再翻訳、失敗時の状態、
  `invalidate()`、チャンク分割後の段落再結合、ガードレール誤発動チャンク
  の寛容化 (部分スキップ成功・全滅時失敗)、文単位リトライ。
- `OtegamiCoreTests`: `QuoteStripperTests` (各種引用マーカー・分離・
  フォールバック)、`SummaryOutputSanitizerTests` (3ラベル構造の反復・
  リーク除去)、`ThreadEntryMetaCommentaryStripperTests`、
  `ThreadDigestGroundingCheckTests`。
- `SyncEngineTests`（`BodyFetcherTests`）: 本文取得時に
  `message.detectedLanguage` が正しく設定されることの検証。
- `OtegamiStoreTests`（`AppDatabaseTests`）: `messageTranslation` テーブル
  ・`message.detectedLanguage` 列のマイグレーションとレコードの
  ラウンドトリップ。
