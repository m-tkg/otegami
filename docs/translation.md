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

### HTML/プレーンテキストのフォールバック判定 (Task #203)

**症状**: 一部のメール (実機報告: Okta のサインオン通知メール) で
「翻訳元の言語を判定できませんでした」、あるいは `detectedLanguage` が
判定できず翻訳ボタンの自動起動が働かない。

**調査で分かったこと**: 判定本体
(`OtegamiTranslation.MessageLanguageDetector.detect`) の呼び出し元は
2箇所 (`SyncEngine.BodyFetcher`、`MessageView
.backfillDetectedLanguageIfNeeded`) あり、どちらも本タスク以前から
「`plainText` があればそれを、無ければ HTML を `HTMLTextExtractor` で
テキスト化したものを」判定にかけていた — つまり**候補は1つしか試して
いなかった**。多くのメールは `multipart/alternative` で `text/plain` と
`text/html` の両方を持つが、選ばれた側のテキストが荒れていて
`NLLanguageRecognizer` が確信を持てない (`nil`)、あるいは Task #159
(下記) と同様に確信ありげに誤判定するケースがあっても、もう一方の
候補を試すことがなかった。

**対処**: `MessageLanguageDetector.detectWithFallback(plainText:html:)`
を新設し、両呼び出し元をこれに統一した。

- **既定は `plainText` を先に試し、`html` にフォールバックする**。
  理由: 本物の MIME `text/plain` パートはデコード済みの生テキストで
  劣化の余地が無いのに対し、HTML 由来のテキストは常に1段階余分な
  変換 (タグ除去) を経ており、この変換自体が過去に2回問題を起こして
  いる ── `MailCoreIMAPSession+Mapping.html(from:)` の doc comment
  (mailcore2 の HTML 描画バグが本文中に脈絡のない改行を混入させた話)
  と、`HTMLTextExtractor` 自身 (正規のパーサではない、線形スキャナ)。
  両呼び出し元がこのタスク以前から同じ優先順位を採っていた既存の判断
  を、一発勝負の選択から実際のリトライへ一般化した形。
- **文字種比率によるノイズ足切り**: 診断画面の文字種比率
  (`letters=NN% digits=NN% ...`) が実際に使える指標だと判断し、
  `MessageLanguageDetector.isTooNoisyToTrust`/`minLetterRatio` として
  取り込んだ。空白を除いた文字のうち「文字 (letter)」の割合が
  30% 未満の候補は、`NLLanguageRecognizer` に確信ありげな結果を返され
  ても信用しない。閾値 0.3 の根拠: 実機で報告された壊れた HTML 抽出
  サンプルの比率が `letters=14%` だったのに対し、通常の英語/日本語の
  文面は経験的に 6〜9 割が文字であるため、その中間で失敗サンプルより
  十分高い値を選んだ。`detect` 自身の `nil` 判定だけに頼らない理由:
  Task #159 (実機報告「明らかに英語の Okta 通知メールが
  `NLLanguageRecognizer` に `pl` (ポーランド語) と誤判定される」) の
  失敗は `nil` の逆 ── 確信ありげな誤判定だった。ノイズ量そのものを
  `detect` に渡す前に足切りすることで、この種の誤判定も防げる。
- **診断画面での可視化**: 「設定 → メールビューア → 翻訳の診断」に
  「直近の言語判定 (最大5件)」セクションを追加し
  (`TranslationDiagnosticsStore.LanguageDetectionAttempt`)、
  メールを開くたびに再判定した際の `plainText`/`html` 各候補の文字種
  比率と、どちら (あれば) が採用されたかを記録する。F15 の趣旨どおり
  本文そのものは一切保持しない。`SyncEngine.BodyFetcher` 側の初回
  フェッチ時判定はこの画面には記録しない (SyncEngine は UI 向け
  診断ストアに依存しない設計のため) が、`MessageView` 側が毎回の
  メール表示時に再判定・自己修復する既存の仕組み (Task #128) がある
  ため、問題のメールを開いてからこの画面を確認すれば十分切り分けが
  できる。

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

## セッション供給の直列化 (`SupplyGatedRequestQueue`) と Task #202

`Translation.TranslationSession` は公開イニシャライザを持たず、
`.translationTask(_:action:)` という SwiftUI 専用の view modifier からしか
得られない。`AppleTranslationService`/`MessageTranslator` は素の `async`
API を要求するため、`TranslationSessionCoordinator` (`@MainActor`) が
両者を橋渡しする — `apps/Otegami/Sources/Features/ThreadDetail
/TranslationSessionHostView.swift` (アプリのルートに1つだけマウント) が
`coordinator.configuration` を読んで `.translationTask` に渡し、SwiftUI が
新しい `TranslationSession` を渡してくるとホストビューが
`coordinator.attach(_:ticket:)` で送り返す、という一往復の非同期ハンド
シェイクになっている。

この橋渡し自体が、2026-07-30 の1日で3回連続の実機退行を経ている
(いずれも実機フィードバック駆動で特定・修正、詳細は
`TranslationSessionCoordinator.swift`/`SupplyGatedRequestQueue.swift`の
doc comment参照):

1. **ホストビュー未マウント**: 元々「翻訳の診断」画面だけがホストビューを
   保持しており、他の画面から翻訳すると供給元が永久に現れなかった →
   ホストビューをアプリのルートへ移設。
2. **`Configuration` の値としての等価性**: `.translationTask(id:action:)`
   は`.task(id:)`と同じ意味論で、`id`が「変化」した時だけクロージャを
   再発火する。`TranslationSession.Configuration(source:target:)`を毎回
   新規に作っていたが、同じ言語ペアなら独立した2つの値は`==`で等価と
   判定される (実SDK検証済み) — 2回目以降のリクエストで再発火しなかった。
   → 既存`configuration`があれば`target`を書き換えてから`invalidate()`を
   呼ぶ方式に変更 (`invalidate()`後は`==`で不一致になることを実SDKで確認)。
3. **キューイング遅延がタイムアウト予算を食う**: 本文翻訳は段落/チャンク
   ごとに`translate`を順次呼ぶため、複数リクエストが立て続けにキューへ
   積まれる。タイムアウトの時計を「`perform`が呼ばれた瞬間」から回して
   いたため、後の方のリクエストはキューで待たされた時間の分だけ持ち時間
   を消費され、自分の番が来る前に (あるいは来た直後に) タイムアウトして
   いた。→ タイムアウトの起点を「実際に`requestSupply`が呼ばれた瞬間」
   (`drainIfNeeded()`内) へ移動。

**Task #202 (実機フィードバック「一度成功した後は必ず翻訳が失敗する」)**
はこれらとは別の、4件目のバグだった。診断画面の記録: 同じ58文字の件名
テキストが最初の1回だけ成功し、以後は「設定要求N回/セッション供給N回、
いずれも今回のリクエストには届きませんでした」で毎回タイムアウト —
要求した数だけ供給は起きているのに、その供給が**要求した本人には一度も
届かない**という記録だった。

根本原因: `SupplyGatedRequestQueue.supply(_:)`(旧シグネチャ) は、届いた
`Session`が「今まさにキューが待っている項目」宛だという保証を一切検証
せずに受け取っていた。`TranslationSessionHostView`の`.translationTask`
クロージャは`Task.isCancelled`を一度もチェックしていないため、SwiftUI
から見て「もう古い」とマークされたクロージャの実行自体は止まらない —
Appleのセッション確立に実機で数秒かかることは珍しくなく、その間に当の
項目自身のタイムアウトが先に尽きてキューが次の項目へ進んでいることは
十分あり得る。その「もう誰も待っていないはずの」古いクロージャが後から
`supply(_:)`を呼ぶと、次の (無関係な) 項目の`pendingOperation`をそのまま
実行してしまい、次の項目からすれば「要求はしたのに自分宛の供給が一度も
届かない」ことになる。以後も同じ理由でずれ続けるため、アプリ起動後
最初の1回 (先行する古いクロージャが存在しない) だけが成功し、それ以降は
恒常的に失敗し続ける、という実機の観測と正確に一致する。

**修正**: `SupplyGatedRequestQueue`に`Ticket`(項目ごとに単調増加する不透明
な識別子) を導入した。`drainIfNeeded()`が項目をキューから取り出すたびに
新しい`Ticket`を発行して`requestSupply(target:ticket:)`で外部の供給元へ
渡し、`supply(_:for:)`はその`ticket`が**現在**`pendingOperation`が待って
いるものと一致する場合にのみ処理する。一致しなければ (=古い項目からの
遅延応答) 何にも触れずに安全に無視する — 「タイムアウト後の遅延応答は
無視する」という既存の安全策を、「タイムアウトはまだ起きていないが別の
項目に取って代わられた」ケースにも一般化したもの。
`TranslationSessionHostView.body`は`configuration`と`coordinator
.pendingTicket`を同じ`body`評価の中で一緒に読み取り (`requestQueue`の
`requestSupply`クロージャが両方を同じ瞬間に書き込むため対応が保証される)、
`.translationTask`のクロージャが実際に発火した時にその`ticket`を
`attach(_:ticket:)`へ渡す。

`SupplyGatedRequestQueueTests`の
`lateSupplyForSupersededTicketDoesNotStealNewerItem`(単発の再現) と
`manyItemsSurviveStraySuppliesUnderLoad`(多数項目・負荷下でのストレス版)
が、Fakeな`Target`/`Session` (`String`/`Int`) でこのレースを直接固定
している。既存の`concurrentRequestsBothEventuallyComplete`は、2つの
`async let`がこのキューへ到達する順序をSwiftが保証しないことに起因する
既知のflakiness (declaration順を仮定した assertion が原因、ローカルで
約1/15の頻度で失敗を確認) があったため、実際の到達順を動的に検出して
検証する形に書き直した。

**2026-08-06 (実機フィードバック — Task #202 修正後もなお同じ診断文言で
再発)** は 5 件目のバグだった。macOS 実機で「設定要求N回/セッション供給
N回、いずれも今回のリクエストには届きませんでした」が再発 (`translate` /
`translateParagraphs` とも全滅)。今回の原因は Ticket 照合ではなく、
**タイムアウトの掃除コードと `supply` の後始末が drain スロットを二重
解放する**こと: 「supply 到着〜operation 完了」がその項目自身の
`timeoutSeconds` (10秒) を跨ぐと、(1) 項目 A のタイムアウトが発火して
次項目 B を drain し、(2) その後 A の operation が完了した時点で
`supply` 側の後始末 (`isDraining = false` + `drainIfNeeded()`) が B の
drain 状態を無条件に踏み潰して C を drain する。以降 B は「要求済みなのに
受け手のいない」孤児になり、B のタイムアウト掃除がまた C を潰して D を
drain … と供給と要求が恒久的に 1 つずつズレ続ける (要求数と供給数は
一致したまま全リクエストがタイムアウトする、Task #202 と同じ見た目)。
引き金の「10秒跨ぎ」は、長文メールのバッチ翻訳 (実機記録: 48要素/3685
文字) や `prepareTranslation()` の言語パックダウンロード確認で普通に
起きる。

修正: タイムアウトが計るのは**供給待ちの時間だけ**とし、供給が届いて
operation が走り始めた項目のタイムアウトは何もしない (`armTimeout` が
自分の `Ticket` を受け取り、発火時に `pendingTicket` と照合して supersede
済みなら即 return)。drain スロットの解放は `supply` の後始末に一本化。
副次効果として、長時間の operation (長文バッチ翻訳) が 10 秒で不当に
タイムアウトすることもなくなった。トレードオフ: operation 自体が返らない
場合の有限時間保証は失われたが、operation は実際には Apple の
`TranslationSession` API (自前のエラーで返る) であり、この型本来の保証
「供給元が現れない場合に無限待機しない」は変わらず有効。診断画面には
「供給の不一致破棄」行 (`attachDiscardedCount`) を追加 — 「供給は来て
いるのに全部捨てられている」症状をスクリーンショット 1 枚で切り分け
られる。`SupplyGatedRequestQueueTests` の
`suppliedOperationOutlivingTimeoutStillReturnsItsResult` (単発) と
`operationOutlivingItsOwnTimeoutDoesNotDesyncLaterItems` (連鎖の再現) が
退行を固定 — 修正前のコードではどちらも失敗することを確認済み。

**エラー表示**: このタイムアウトが投げていたエラーメッセージ (`設定要求
N回/セッション供給N回…`という診断向けカウンタ入りの文字列) は
`TranslationServiceError.failed(message:)`経由で**そのまま利用者向けの
帯 (`MessageDetailFooterToolbar`) にも表示されていた** — 長すぎて画面外
へはみ出し、末尾の数文字しか見えない実機バグの直接原因になっていた。
`TranslationServiceError.sessionUnavailable(detail:)`という専用ケースを
追加し、`detail`(カウンタ入り、診断画面/`errorDescription`/ログ向け) と
`userFacingMessage`(固定の短い定型文「時間をおいて再試行してください」
— `TranslationUnavailableReason.other`と同じ文言を意図的に再利用) を
分離した。あわせて`MessageDetailFooterToolbar.translateFootnoteCaption`
の呼び出し元にあった裸の`.fixedSize()`(両軸ともideal sizeを要求する
指定) を削除した — `.overlay(alignment: .top)`はデフォルトで土台の
アイコン (44pt) 相当の狭い幅しか提案してこないため、この裸`.fixedSize()`
が「幅200ptで頭打ち」という内側の`.frame(maxWidth:)`指定を無効化して
いた (提案幅を無視して単一行の自然な幅を要求してしまうため)。実機の
「画面右外にはみ出し末尾しか見えない」という症状は、`ImageRenderer`で
同じ modifier chain を実際にレンダリングして再現・確認済み — 修正後は
`.frame(minWidth: 140, maxWidth: 190)`(狭い提案を底上げしつつ長い文言は
折り返す) で画面内に収まる。詳細な検証手順・残存リスク (翻訳ボタンが
ツールバーの最端に来た場合のわずかな余地) は`MessageDetailFooterToolbar
.translateFootnoteCaption`のdoc comment参照。

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
  (実エンジンは実機依存のため自動テスト不可)。`SupplyGatedRequestQueueTests`
  は`TranslationSession`に一切依存しない (`Target`/`Session`をFakeな
  `String`/`Int`にできる) 汎用キュー型として、供給が一切来ないケース・
  二重resumeが起きないこと・並行リクエストが両方とも必ず終わること・
  Task #202で見つかった「タイムアウト後に古い項目宛の遅延応答が新しい
  項目を奪う」レースが再発しないことを直接検証する
  (上の「セッション供給の直列化」節参照)。
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
