enum UITestHTMLFixtures {
    /// Task #45 — see the `OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE` block in
    /// `AppEnvironment`. A 1x1-ish placeholder PNG (the same tiny fixture image
    /// `dev/mailstack/seed/fixtures/16-cid-inline-image.eml` and friends
    /// use, base64-reencoded as a `data:` URI) stands in for the logo/
    /// avatar images the real `.eml` fixture loads via `cid:`.
    private static let uitestFakeHTMLMessagePlaceholderImage = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAAH0lEQVR42mN4USVHFcQwatCoQaMGjRo0atCoQQNvEAD6qmAurCoQRgAAAABJRU5ErkJggg=="

    /// Task #111 (実機報告: 「ソースを表示」をタップすると画面が空白 — 数十
    /// KB級の実メールで再現、シェアシートからの`.eml`書き出しは正常。原因は
    /// `MessageSourceView`の表示側 (`SwiftUI`の`Text`を`ScrollView`に
    /// ネストして巨大な文字列を渡すとCore Graphicsのテクスチャサイズ上限
    /// 相当に達し無言で空白になる、既知の挙動) だった): この定数はその
    /// 再現・検証用の合成データ — ユーザー提供の実メール (実名の宛先
    /// アドレス・購読解除トークンを含む、約54KB) は`docs/`規約により
    /// リポジトリへコミットできないため、同程度のサイズ級を作れる意味の
    /// ない引用チェーン (長く育った返信スレッドで実際によく見る形 —
    /// 何段にも重なった`>`引用行) で代替する。`uitestFakeHTMLMessages[0]`
    /// (html-0シナリオ) の生ソースにだけ足される
    /// (`OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE`挿入ブロック参照) —
    /// `message-source`シナリオ (`scripts/verify-screen.sh`) が常にこの
    /// index 0を開くため。
    static let uitestFakeLargeRawSourceQuotedHistory: String = {
        let line = "> このダミー引用行はメールソース表示のパフォーマンス検証 (Task #111) 用に生成した合成テキストです。実データは一切含みません。"
        return Array(repeating: line, count: 500).joined(separator: "\r\n")
    }()

    /// Task #123 (Spark 参考「引用履歴をメッセージ単位に分解して時系列
    /// 表示」): `OTEGAMI_UITEST_INSERT_FAKE_QUOTED_PLAIN_MESSAGE`'s body — a
    /// three-level-deep, top-posted Japanese Gmail-style reply chain (same
    /// shape/fictional names `QuoteStripperTests`/`QuoteHistoryParserTests`
    /// already use: 山田太郎 <yamada@example.com> / 田中花子
    /// <tanaka@example.com>). Each level's attribution line ("YYYY年M月D日
    /// (曜) H:MM 名前 <addr>:") lands one `>` shallower than that level's
    /// own body, mirroring exactly how a real top-posting client's quoting
    /// nests (see `QuoteHistoryParser`'s doc comment for why nesting depth
    /// alone recovers chronological order) — `scripts/verify-screen.sh
    /// quote-history` opens this fixture to screenshot
    /// `QuoteHistorySectionView`'s card with real (if fictional) multi-
    /// message content instead of a placeholder.
    static let uitestFakeQuotedPlainMessageBody = """
        田中さん

        資料のご確認ありがとうございます。来週の定例はオンラインで問題ありません。ご都合の良い候補日を2〜3つ、水曜までに教えていただけますと助かります。

        > 2026年7月28日(火) 10:15 田中花子 <tanaka@example.com>:
        > > 山田さん
        > >
        > > 明日の打ち合わせですが、資料を先にお送りしておきますね。会議室ではなくオンラインに変更しても大丈夫でしょうか。
        > >
        > > > 2026年7月25日(土) 09:03 山田太郎 <yamada@example.com>:
        > > > > 田中さん
        > > > >
        > > > > 承知しました、来週の打ち合わせの件、日程調整ありがとうございます。会議室の予約は私の方で進めておきます。
        > > > >
        > > > > > 2026年7月20日(月) 16:47 田中花子 <tanaka@example.com>:
        > > > > > > 山田さん
        > > > > > >
        > > > > > > お世話になっております。次回の定例ミーティングの日程について、来週のどこかでお時間いただけますでしょうか。
        """

    /// 実機フィードバック (MakerWorld実メールとの比較報告): 完全に透明な
    /// 背景の上に不透明な黒だけを描いた120x40のPNG (ロゴの線画部分を模した
    /// 単純な矩形3つ) — 上の `uitestFakeHTMLMessagePlaceholderImage` (ほぼ
    /// 1x1、装飾目的のダミー) と違い、この画像自体の見た目 (透過部分がある
    /// こと、黒い部分の実サイズが小さいこと) がテスト対象そのもの:
    /// 「反転フィルタを打ち消すために img がもう一度反転される→透過PNGの
    /// 黒いロゴがそのまま黒で残る→反転後の暗い背景に沈んで読めなくなる」
    /// という実機報告と、その対策 (`decideLogoChips`によるロゴサイズの
    /// 画像への白系チップ背景) を実際に目視確認できるようにするための
    /// 実物。`dev/mailstack/seed/fixtures/34-white-canvas-transparent-logo.eml`
    /// と同じPNGバイト列 (手で同期を保つ理由は
    /// `uitestFakeHTMLMessageBodySecurityNotice`のdoc comment参照)。
    private static let uitestFakeHTMLMessagePlaceholderTransparentLogo = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAHgAAAAoCAYAAAA16j4lAAAAeUlEQVR4nO3aMQ6AIBAAQTT+/8vaWdkacJ0pabhkQ0FgDAAAAPiP7WHtnLTvKvun7LMH4F0CxwkcJ3CcwHHH7AEWdI7vu28JTnCcwHECxwkcJ3CcwHECxwkcJ3CcwHECxwkc57Eh/p3HCY4TOE7gOIHjBAYAAGD8yAV2jAM3LCTYZQAAAABJRU5ErkJggg=="

    /// Task #51/#56: one entry per dark-mode/HTML-rendering regression
    /// scenario (`docs/design-system.md`'s Task #51/#56 節), inserted as
    /// separate seeded messages so `OtegamiSecurityNoticeDarkModeUITests`
    /// can open and screenshot all of them in one run instead of needing
    /// one separate env-var-gated code path per case:
    /// - `securityNotice` (case b): explicit white background + dark text,
    ///   no self-declared dark support — the *original* Task #45 fixture;
    ///   still needs the invert to stay readable in dark mode.
    /// - `noColors` (case a): zero color declarations anywhere — the
    ///   Task #51 regression case itself (see `HTMLDocumentBuilder.wrap
    ///   (bodyHTML:autoAdjustColorsInDarkMode:)`'s doc comment); must NOT
    ///   be inverted, since it already renders correctly via this app's
    ///   own `color-scheme`/`CanvasText` CSS reset alone.
    /// - `selfDarkAware` (case c): declares its own `prefers-color-scheme`
    ///   handling, so `HTMLDocumentBuilder.wrap` should skip inversion
    ///   consideration entirely regardless of what the JS measurement would
    ///   have found — proves the "mail already handles its own dark mode"
    ///   gate still wins over the newer measured-inversion logic.
    /// - `betaTestingNotice` (Task #56): no background at all *and* an
    ///   explicit dark text color (`#444444`) — the case neither `b` nor
    ///   `a` above covers (background genuinely unresolved, but unlike `a`
    ///   the text isn't relying on `CanvasText`). Also exercises the
    ///   "responsive but capped" image technique (`width` attribute +
    ///   `style="width:100%; max-width:120px;"`) that the image-enlargement
    ///   fix targets.
    /// - `makerWorldLikeNotice` (実機フィードバック、MakerWorld実メールとの
    ///   比較報告): `body`自身が`background-color`を明示指定するテンプレート
    ///   (findEffectiveBackgroundの最優先候補) と、透過PNGの小さいロゴ画像
    ///   の組み合わせ — ダーク反転時の「右端の白帯・セクション間の色ムラ・
    ///   透過ロゴが暗背景に沈む」の3点を確認する。
    /// - `calendarInviteRealisticNotice` (Task #98、実機報告: Google カレン
    ///   ダー招待メールがダークモードでほぼ読めない): `uitestFakeCalendarInviteHTML`
    ///   (Task #84、`calendar-invite`シナリオ) 自体は既に「背景なし+過半数
    ///   ラベルが`#5f6368`系」のケースを再現しているが、そちらは本文冒頭
    ///   から即座にラベル (`#5f6368`) が始まるため、
    ///   `representativeTextLuminance`の「最初の6テキストノードの平均」
    ///   だけでも実は既に閾値未満に落ちて正しく判定できてしまっていた
    ///   (Task #84 時点で確認済み)。実機報告の実際のメールはタイトル見出し
    ///   や「〜さんが招待しました」といった色未指定の前置きテキストが本文
    ///   冒頭に複数行あり、そちらが平均を0.5超まで押し上げて「介入不要」に
    ///   誤って倒れる — その取りこぼしそのものを再現するのがこのケース
    ///   (色未指定のテキストを冒頭に3つ挟み、6サンプル平均を0.5超で固定
    ///   しつつ、全体としては明示的な暗〜中間色テキストが文字数で過半を
    ///   占める構造)。`explicitDarkTextIsMajority`(Task #98) が無いとこの
    ///   ケースは白カード化されず、暗地に暗〜中間色文字のまま残る。
    /// - `styleBlockGrayTextNotice` (Task #104、実機報告: Readdle Documents
    ///   のニュースレター等が Task #98 対策後もダークネイティブのまま
    ///   読めない): 上の`calendarInviteRealisticNotice`と違い、文字色を
    ///   **インライン`style`ではなく`<head>`の`<style>`ブロックの CSS
    ///   クラス**で指定するニュースレターテンプレートを再現する
    ///   (`.headline`/`.body-text`/`.footer-text`が`color`を持つクラス、
    ///   本文側は`class="body-text"`のようにクラス名を書くだけでインライン
    ///   `style`を一切持たない)。背景は本文中どこにも指定せず (青い
    ///   ヒーロー画像は`<img>`のみで背景色を持つ要素ではない — CTAボタンの
    ///   背景色だけが唯一の候補になるが `inner`の30%未満なのでTask #84の
    ///   足切りに掛かりnullのまま)、文書冒頭に色未指定の前置き文を2行
    ///   置いて`representativeTextLuminance`の6サンプル平均を0.5超で固定
    ///   しつつ、クラス経由の暗〜中間グレー本文が文字数で過半を占める —
    ///   `explicitDarkTextIsMajority`がインライン`style`しか見ていなければ
    ///   (Task #98時点の実装) この過半を検出できず「介入不要」に誤って
    ///   倒れる、その取りこぼしを再現するケース。
    /// - `whiteCardHeroNotice` (Task #112、ユーザー提供の実メール
    ///   `readdle.eml`で再現・修正 — 上の6件と違う点が肝心): 上のケースは
    ///   すべて`findEffectiveBackground`が`null`を返す「背景なし」の構造
    ///   だったため、`explicitDarkTextIsMajority`(Task #98/#104)は
    ///   `decideDarkInversion`の`else`枝 (背景なしフォールバック) からしか
    ///   呼ばれないという実装のまま気づかれずにいた。実際の readdle.eml は
    ///   `body`が明示的に白背景を持つ「背景あり」の構造 (ニュースレターとして
    ///   ごく普通) で、この場合`decideDarkInversion`は`if (background)`枝の
    ///   `representativeTextLuminance`(先頭6テキストノードの平均) だけしか
    ///   見ておらず、`explicitDarkTextIsMajority`には一度も到達していな
    ///   かった — Task #104 の対策が実際には多くの実メールで効いていな
    ///   かった根本原因。このフィクスチャは`body`に明示的な白背景を持たせ
    ///   た上で、文書冒頭にヒーロー領域 (背景画像+白文字の短い見出し2行、
    ///   Gmail限定の`u+.body`セレクタ — このWKWebViewでは絶対にマッチしない
    ///   ため無害 — による`mix-blend-mode`ハックも実物同様に含む) を置き、
    ///   その後に本文カード (クラス経由の`#111111`/`rgb(51, 51, 51)`系の
    ///   暗〜中間グレー文字を複数段落) を続ける — 先頭6サンプルがヒーロー
    ///   側の明るい文字に偏って「介入不要」に落ち着いた後、本文の暗色
    ///   段落が文字数で過半を占める構造を`explicitDarkTextIsMajority`側の
    ///   フォールバックが拾えることを確認する。冒頭の隠しプリヘッダ
    ///   (`display:none`/`visibility:hidden`/`font-size:0`と、実物同様の
    ///   大量の不可視結合文字) も含めてあり、これが`explicitDarkText
    ///   IsMajority`の分母を水増ししない (`isVisuallyHiddenText`) ことも
    ///   同時に確認できる。色指定は実物の`#333333`/`rgb(51, 51, 51)`混在を
    ///   模して両記法を使う。
    struct UITestFakeHTMLMessage {
        let subject: String
        let snippet: String
        let html: String
        /// Task #128: `nil` (the default — every pre-existing fixture) seeds
        /// the row with no `detectedLanguage` at all, same as a message this
        /// app has never opened before. `uitestFakeHTMLMessageBodySSONotice`
        /// below is the one fixture that sets this to a deliberately *wrong*
        /// non-`nil` value — see its own doc comment for why.
        var detectedLanguage: String? = nil
    }

    static let uitestFakeHTMLMessages: [UITestFakeHTMLMessage] = [
        UITestFakeHTMLMessage(
            subject: "セキュリティ通知",
            snippet: "あなたは otegami に Example アカウントのデータの一部へのアクセスを許可しました",
            html: uitestFakeHTMLMessageBodySecurityNotice
        ),
        UITestFakeHTMLMessage(
            subject: "色指定なしのシンプルなお知らせ (UITest)",
            snippet: "このメールは背景色・文字色のどちらも一切指定していません。",
            html: uitestFakeHTMLMessageBodyNoColors
        ),
        UITestFakeHTMLMessage(
            subject: "自前ダーク対応済みのお知らせ (UITest)",
            snippet: "このメールは prefers-color-scheme で自前のダークモード対応を宣言しています。",
            html: uitestFakeHTMLMessageBodySelfDarkAware
        ),
        UITestFakeHTMLMessage(
            subject: "AppSample 2.1 (45) is ready to test on iOS. (UITest)",
            snippet: "AppSample 2.1 (45) is ready to test on iOS.",
            html: uitestFakeHTMLMessageBodyBetaTestingNotice
        ),
        UITestFakeHTMLMessage(
            subject: "A boost token is about to expire (UITest)",
            snippet: "Your boost token is nearing expiration. Kindly utilize it to boost your preferred model and win points reward.",
            html: uitestFakeHTMLMessageBodyMakerWorldLikeNotice
        ),
        UITestFakeHTMLMessage(
            subject: "四半期計画会議 (Quarterly Planning Sync) (UITest)",
            snippet: "otegami calendar organizer さんがあなたを招待しました",
            html: uitestFakeHTMLMessageBodyCalendarInviteRealisticNotice
        ),
        UITestFakeHTMLMessage(
            subject: "FakeDocs Weekly Update (UITest)",
            snippet: "共同編集がさらに高速になりました",
            html: uitestFakeHTMLMessageBodyStyleBlockGrayTextNotice
        ),
        UITestFakeHTMLMessage(
            subject: "ScribbleSync is now SOC 2 certified. (UITest)",
            snippet: "ScribbleSync が SOC 2 認証を取得しました",
            html: uitestFakeHTMLMessageBodyWhiteCardHeroNotice
        ),
        // Task #128 (実機報告「英語メールなのに翻訳ボタンが押せない」— Okta の
        // サインオン通知メール、hypothesis (2)): `detectedLanguage: "fr"` は
        // 実際にはフランス語のメールではなく、古いビルドが誤った言語を検出
        // して保存してしまったケースの再現 — 修正前の
        // `backfillDetectedLanguageIfNeeded`は`detectedLanguage != nil`な
        // ら常にスキップしていたので、この誤った値が永久に固定化し、
        // 明らかに英語の本文でも翻訳バー/ボタンが二度と現れなかった。
        // `MessageView.load()`が本文読み込み直後に呼ぶ再判定 (修正後) が
        // 本文から"en"を再検出し、この誤った"fr"を上書きすることを検証する。
        UITestFakeHTMLMessage(
            subject: "New sign-in to Example App (UITest)",
            snippet: "We noticed a new sign-in to your Example App account. If this was you, no action is needed.",
            html: uitestFakeHTMLMessageBodySSONotice,
            detectedLanguage: "fr"
        ),
        // Task #133 (実機報告「引用折りたたみがHTMLメールで効かない」):
        // `html-9` — see `uitestFakeHTMLMessageBodyGmailQuoteHistory`'s doc
        // comment for what this checks (HTML branch's quote-history
        // toggle+card, newHTML-only WKWebView rendering).
        UITestFakeHTMLMessage(
            subject: "ご予約について (UITest)",
            snippet: "承知しました、21日の11時でお願いします。",
            html: uitestFakeHTMLMessageBodyGmailQuoteHistory
        ),
        // Task #205 (実機報告 — ユーザー提供の実メール、内容は伏せて構造だけ
        // 再現): `html-10` — `uitestFakeHTMLMessageBodyResponsiveTableFooterNotice`
        // のdoc comment参照 (幅いっぱいの `width="100%"` テーブル + `http:`
        // 外部画像2枚 + 濃色背景フッター、というこのメールの実際の骨格)。
        UITestFakeHTMLMessage(
            subject: "Scheduled maintenance for subscription #0000000 (UITest)",
            snippet: "Service maintenance for subscription #0000000 is now complete.",
            html: uitestFakeHTMLMessageBodyResponsiveTableFooterNotice
        ),
        // 実機報告 (ユーザー提供の実メール rakuten.eml、内容は伏せて構造だけ
        // 再現): `html-11` — `uitestFakeHTMLMessageBodyFundPriceNotificationTallTable`
        // のdoc comment参照 (背景が最後まで解決しない一覧テーブル+縦長の
        // データ行、というこのメールの実際の骨格)。
        UITestFakeHTMLMessage(
            subject: "投信基準価額メール (UITest)",
            snippet: "基準価額のお知らせ",
            html: uitestFakeHTMLMessageBodyFundPriceNotificationTallTable
        )
    ]

    /// See the doc comment above `uitestFakeHTMLMessagePlaceholderImage`.
    /// Structurally identical to `31-security-notice-dark-mode.eml`'s
    /// `text/html` part (white card background + explicit dark text, no
    /// `color-scheme`/`prefers-color-scheme` of its own, a `<hr>` with two
    /// body paragraphs + a CTA button below it, and a `white-space: nowrap`
    /// footer line that deterministically forces fit-to-width's scale path)
    /// — kept in sync by hand since a UITest-only Swift string literal can't
    /// `include` the `.eml` fixture file.
    fileprivate static let uitestFakeHTMLMessageBodySecurityNotice = """
    <!doctype html>
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <style type="text/css">
      body { margin: 0; padding: 0; background-color: #f2f2f2; font-family: 'Helvetica Neue', Arial, sans-serif; }
      .card { max-width: 480px; margin: 24px auto; background-color: #ffffff; border: 1px solid #dadce0; border-radius: 8px; overflow: hidden; }
      .card-inner { padding: 40px 40px 32px 40px; text-align: center; }
      h1 { font-size: 20px; line-height: 26px; color: #202124; font-weight: 400; margin: 24px 0 16px 0; }
      .account-row { font-size: 14px; color: #3c4043; margin: 0 0 24px 0; }
      hr { border: none; border-top: 1px solid #e8eaed; margin: 0 0 24px 0; }
      .body-text { font-size: 14px; line-height: 20px; color: #3c4043; text-align: left; margin: 0 0 16px 0; }
      .cta { display: inline-block; background-color: #1a73e8; color: #ffffff; font-size: 14px; font-weight: 500; padding: 10px 24px; border-radius: 4px; text-decoration: none; margin: 8px 0 24px 0; }
      .footer { max-width: 480px; margin: 0 auto; padding: 0 40px 24px 40px; font-size: 11px; line-height: 16px; color: #70757a; }
      .nowrap-disclaimer { white-space: nowrap; }
    </style>
    </head>
    <body>
    <div class="card">
      <div class="card-inner">
        <img src="\(uitestFakeHTMLMessagePlaceholderImage)" width="120" height="40" alt="Example">
        <h1>あなたは otegami に Example アカウントのデータの一部へのアクセスを許可しました</h1>
        <p class="account-row">
          <img src="\(uitestFakeHTMLMessagePlaceholderImage)" width="24" height="24" style="border-radius:50%;vertical-align:middle;" alt="">
          user@example.com
        </p>
        <hr>
        <p class="body-text">otegami に Example アカウントのデータの一部へのアクセスを許可していない場合は、第三者が Example アカウントのデータにアクセスしようとしている可能性があります。</p>
        <p class="body-text">今すぐアカウント アクティビティを確認し、アカウントを保護してください。</p>
        <a class="cta" href="https://example.com/security-checkup">アクティビティを確認</a>
      </div>
    </div>
    <div class="footer">
      <p>otegami に付与したあなたのデータへのアクセス権は、Example アカウントでいつでも変更できます。</p>
      <p class="nowrap-disclaimer">このメールは security-noreply@example.com からの重要なお知らせのため配信停止の対象外です。返信はできません。</p>
    </div>
    </body>
    </html>
    """

    /// Task #51 の退行ケースそのもの — `dev/mailstack/seed/fixtures/
    /// 32-plain-html-no-colors.eml` と同内容 (背景色・文字色を一切
    /// 指定しない、最も単純な HTML メール)。ダークモードで開いても
    /// `HTMLDocumentBuilder`の CSS リセット (`color-scheme: light dark`)
    /// だけで元々正しく読めるはずで、`.otegami-invert-for-dark`が
    /// 付いてはいけない (実測が「背景が確定しない」と判定し、無変換の
    /// ままになることを確認する)。
    fileprivate static let uitestFakeHTMLMessageBodyNoColors = """
    <html>
    <body>
    <p>こんにちは、otegami です。</p>
    <p>このメールは背景色・文字色のどちらも一切指定していません。ダークモードで開いたとき、アプリの CSS リセット (color-scheme: light dark) だけに任せて自動的に明るい文字色で表示されるはずです。</p>
    <p>Task #51: ここに「反転」を無条件に適用すると、本来すでに正しく読めていたはずのこのメールが暗地に暗文字になり読めなくなる回帰があった — その再現ケース。</p>
    </body>
    </html>
    """

    /// メール自身が`<meta name="color-scheme">`と`prefers-color-scheme`
    /// メディアクエリの両方で自前のダークモード対応を宣言しているケース
    /// — `HTMLDocumentBuilder.mailDeclaresOwnDarkModeSupport(html:)`が
    /// true を返すため、`wrap(bodyHTML:autoAdjustColorsInDarkMode:)`は
    /// 反転を検討する対象からそもそも除外する (`data-otegami-invert-check`
    /// 属性すら付かない)。ライトモードでは白背景+濃色文字、ダーク
    /// モードでは自前の暗背景+明文字に自分で切り替わる想定で、
    /// どちらのモードでもアプリ側の反転が絶対にかかっていないことを
    /// 目視確認する。
    fileprivate static let uitestFakeHTMLMessageBodySelfDarkAware = """
    <!doctype html>
    <html>
    <head>
    <meta name="color-scheme" content="light dark">
    <style type="text/css">
      body { margin: 0; padding: 0; background-color: #ffffff; color: #202124; font-family: 'Helvetica Neue', Arial, sans-serif; }
      .card { max-width: 480px; margin: 24px auto; padding: 24px; }
      @media (prefers-color-scheme: dark) {
        body { background-color: #1e1e1e; color: #e8eaed; }
      }
    </style>
    </head>
    <body>
    <div class="card">
      <p>このメールは prefers-color-scheme で自前のダークモード対応を宣言しています。</p>
      <p>otegami はこのメールに対して「反転」処理を一切適用しません — ライト・ダークどちらの外観でも、この HTML 自身が指定した配色のまま表示されるはずです。</p>
    </div>
    </body>
    </html>
    """

    /// Task #56 (実機フィードバック: TestFlight通知メールで「1. 画像の
    /// 巨大化」「2. 背景なし+濃色文字が読めない」「3. 高さ切れ」「4. 要約/
    /// 翻訳フローティングボタンが本文に被る」の4点が同時発生) — 見出しの
    /// doc comment参照。`dev/mailstack/seed/fixtures/
    /// 33-beta-testing-notice.eml`と同内容 (cid: 画像をこのファイルの
    /// data: URI プレースホルダに置き換えただけ) — 手で同期を保つ理由は
    /// `uitestFakeHTMLMessageBodySecurityNotice`のdoc comment参照。
    /// 背景色を一切指定せず (1で使う`autoAdjustColorsInDarkMode`の
    /// 「背景が解決しない」経路を踏む)、`color:#444444`を明示指定
    /// (CanvasText由来ではない「著者が明示した暗い文字色」であることが
    /// この再現の肝 — 32番フィクスチャの retention と区別する実測ロジック
    /// の対象)、画像は `width`属性 + `style="width:100%;
    /// max-width:120px;"`という「レスポンシブだが上限あり」手法 (Apple/
    /// 主要ESPのテンプレートで頻出、これが無条件`max-width:100%
    /// !important`に上限を踏み潰されて拡大していた実機バグの再現条件)、
    /// リンク数本、複数段落 — 罫線こそ持たないが31番同様に段落が複数
    /// あるぶん、高さ計測 (3) の回帰確認にも使える。
    fileprivate static let uitestFakeHTMLMessageBodyBetaTestingNotice = """
    <!doctype html>
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <meta name="viewport" content="width=device-width">
    <title>AppSample 2.1 (45) is ready to test on iOS.</title>
    </head>
    <body style="margin:0; padding:0; font-family: -apple-system, Helvetica, Arial, sans-serif; color:#444444;">
    <div style="max-width:480px; margin:0 auto; padding:24px;">
      <p style="color:#444444; font-size:15px; line-height:22px; margin:0 0 24px 0;">AppSample 2.1 (45) is ready to test on iOS.</p>
      <div style="text-align:center; margin:0 0 24px 0;">
        <img src="\(uitestFakeHTMLMessagePlaceholderImage)" width="120" height="120" alt="AppSample" style="width:100%; max-width:120px; height:auto; display:block; margin:0 auto; border-radius:22px;">
      </div>
      <p style="color:#444444; font-size:16px; line-height:24px; text-align:center; margin:0 0 24px 0;">AppSample 2.1 (45) is ready to test on iOS.</p>
      <p style="color:#444444; font-size:14px; line-height:20px; margin:0 0 16px 0;">To test this app, open <a href="https://beta.otegami.test/link/">Otegami Beta</a> on your iOS device using iOS 26.0 or later and install the update.</p>
      <p style="color:#444444; font-size:14px; line-height:20px; margin:0 0 16px 0;">You can stop testing and manage notifications in the <a href="https://beta.otegami.test/app">Otegami Beta app</a>.</p>
      <p style="color:#444444; font-size:14px; line-height:20px; margin:0 0 16px 0;">To be removed from this developer's list of potential testers, <a href="https://beta.otegami.test/contact">contact the developer</a>.</p>
      <p style="color:#444444; font-size:12px; line-height:18px; margin:24px 0 0 0;">To learn more about installation, testing, sending feedback, supported OS versions and the use of your data, visit <a href="https://beta.otegami.test/">beta.otegami.test</a>.</p>
    </div>
    </body>
    </html>
    """

    /// 実機フィードバック (MakerWorld実メールとの比較報告): ダークモードの
    /// スマート反転で (1) 右端に縦の白帯、(2) セクション間の色ムラ、(3)
    /// 透過PNGロゴが暗背景に沈む、の3点が同時発生した実例を再現する構造 —
    /// `dev/mailstack/seed/fixtures/34-white-canvas-transparent-logo.eml`と
    /// 同内容 (cid: 画像をこのファイルの
    /// `uitestFakeHTMLMessagePlaceholderTransparentLogo`に置き換えただけ)。
    /// `body`自身に`background-color:#ffffff`を明示指定 (`findEffectiveBackground`
    /// が最優先で見つける「body自身の背景」のテストケース — これが
    /// `#otegami-fit-inner`の外、bodyのpaddingの範囲でそのまま透けて残って
    /// いたのが「右端の白帯・色ムラ」の実体)、中央寄せの透過PNGロゴ、薄
    /// グレーの角丸カード、緑のCTAボタン、という組み合わせ。
    fileprivate static let uitestFakeHTMLMessageBodyMakerWorldLikeNotice = """
    <!doctype html>
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <meta name="viewport" content="width=device-width">
    <title>A boost token is about to expire (UITest)</title>
    <style>
      body { background-color: #ffffff; margin: 0; padding: 0; }
      .otegami-fixture-card { background-color: #f3f3f5; border-radius: 8px; }
    </style>
    </head>
    <body>
    <div style="max-width:520px; margin:0 auto; padding:24px; text-align:center;">
      <img src="\(uitestFakeHTMLMessagePlaceholderTransparentLogo)" width="120" height="40" alt="MakerWorld" style="display:block; margin:0 auto 24px auto;">
      <hr style="border:none; border-top:1px solid #e0e0e0; margin:0 0 24px 0;">
      <p style="color:#222222; font-size:15px; line-height:22px; text-align:left; margin:0 0 24px 0;">Your boost token is nearing expiration. Kindly utilize it to boost your preferred model and win points reward.</p>
      <div class="otegami-fixture-card" style="padding:20px; margin:0 0 24px 0; text-align:left;">
        <p style="color:#7b3fe4; font-size:18px; font-weight:bold; margin:0 0 8px 0;">Boost Token</p>
        <p style="color:#666666; font-size:13px; margin:0 0 4px 0;">Expires on</p>
        <p style="color:#222222; font-size:14px; margin:0;">2026-08-03 10:27 UTC</p>
      </div>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px 0;">
        <tr><td style="background-color:#34a853; color:#ffffff; font-size:15px; font-weight:bold; text-align:center; padding:14px 0; border-radius:4px;">Boost to model</td></tr>
      </table>
      <p style="color:#999999; font-size:12px; line-height:18px; text-align:left; margin:0;">If you wish to unsubscribe, or change notification settings: <a href="https://example.test/unsubscribe">Click here</a></p>
    </div>
    </body>
    </html>
    """

    /// Task #98 (実機報告: Google カレンダー招待メールがダークモードでほぼ
    /// 読めない) — 上の`UITestFakeHTMLMessage`配列のdoc comment
    /// (`calendarInviteRealisticNotice`項) 参照。`uitestFakeCalendarInviteHTML`
    /// (Task #84) と同じラベル/値の構造 (`#5f6368`のラベル+`#3c4043`の値、
    /// 背景指定なし) を土台に、実機の実際のメールが持つ「タイトル見出し」
    /// 「〜さんが招待しました、という色未指定の前置き」を本文冒頭に追加
    /// した — この2行 + CTAボタンの白文字で、文書順で見つかる最初の
    /// 6テキストノードのうち3つが明るい色 (見出し/前置きはCanvasText由来、
    /// ボタンは明示的な`#ffffff`) になり、`representativeTextLuminance`の
    /// 単純平均だけでは0.5をわずかに超えて「介入不要」に落ちる
    /// (`explicitDarkTextIsMajority`が無いと再現する回帰)。
    fileprivate static let uitestFakeHTMLMessageBodyCalendarInviteRealisticNotice = """
    <!doctype html>
    <html>
    <body style="font-family:Roboto,Arial,sans-serif; margin:0; padding:0;">
    <h2 style="margin:16px 24px 4px 24px; font-size:18px; font-weight:400;">四半期計画会議 (Quarterly Planning Sync)</h2>
    <p style="margin:0 24px 16px 24px; font-size:14px;">otegami calendar organizer さんがあなたを招待しました</p>
    <div style="margin:0 24px;">
    <table role="presentation" cellpadding="0" cellspacing="0" style="background-color:#1a73e8; border-radius:4px;">
    <tr><td style="padding:12px 24px;"><a href="https://meet.otegami.test/abc-defg-hij" style="color:#ffffff; font-size:14px; font-weight:bold; text-decoration:none;">Google Meet に参加する</a></td></tr>
    </table>
    <p style="color:#5f6368; font-size:12px; margin:16px 0 2px 0;">会議のリンク</p>
    <p style="color:#3c4043; font-size:14px; margin:0 0 16px 0;">meet.otegami.test/abc-defg-hij</p>
    <p style="color:#5f6368; font-size:12px; margin:0 0 2px 0;">日時</p>
    <p style="color:#3c4043; font-size:14px; margin:0 0 16px 0;">2026/08/03 (月曜日) &middot; 15:00 &ndash; 16:00 (日本標準時)</p>
    <p style="color:#5f6368; font-size:12px; margin:0 0 2px 0;">ゲスト</p>
    <p style="color:#3c4043; font-size:14px; margin:0;">Otegami Organizer - 主催者</p>
    <p style="color:#3c4043; font-size:14px; margin:0 0 16px 0;">Fake Calendar Invite</p>
    <p style="color:#5f6368; font-size:12px; margin:0;">このメールへの返信、またはアプリの「承諾」「辞退」「未定」ボタンで出欠をお知らせください。</p>
    </div>
    </body>
    </html>
    """

    /// Task #104 (実機報告: Readdle Documents のニュースレター等が Task #98
    /// 対策後もダークモードでほぼ読めない) — 上の`UITestFakeHTMLMessage`配列
    /// のdoc comment (`styleBlockGrayTextNotice`項) 参照。文字色をインライン
    /// `style`ではなく`<head>`の`<style>`ブロックのクラス (`.headline`/
    /// `.body-text`/`.footer-text`) で指定する点が、同じ「背景なし+
    /// 中間グレー文字」構造の`calendarInviteRealisticNotice`(Task #98) との
    /// 違い — あちらは全部インライン`style`で色指定していたため、Task #98
    /// 時点の`explicitDarkTextIsMajority`(インライン限定) でも検出できて
    /// いた。冒頭の2行 (色未指定、CanvasText由来で明るく解決) + CTA
    /// ボタンの白文字 (`.cta`、明示的だが明るい色) で最初の6テキストノード
    /// の平均を0.5超に保ちつつ、`.headline`/`.body-text`×2/`.footer-text`
    /// (すべてクラス経由の暗〜中間グレー) が文字数で過半を占める。CTA
    /// ボタン自身の`background-color`はTask #84の30%カバレッジ要件未満
    /// (`inner`に対して小さいボタン1つだけ) のため`findEffectiveBackground`
    /// は`null`のまま — カレンダー招待フィクスチャと同じ「背景なし」
    /// フォールバック経路をたどる。
    fileprivate static let uitestFakeHTMLMessageBodyStyleBlockGrayTextNotice = """
    <!doctype html>
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <meta name="viewport" content="width=device-width">
    <title>FakeDocs Weekly Update (UITest)</title>
    <style type="text/css">
      body { margin: 0; padding: 0; font-family: -apple-system, Helvetica, Arial, sans-serif; }
      .content { padding: 0 24px; }
      .headline { color: #202124; font-size: 16px; font-weight: bold; margin: 0 0 12px 0; }
      .body-text { color: #5f6368; font-size: 14px; line-height: 20px; margin: 0 0 16px 0; }
      .cta { display: inline-block; background-color: #1a73e8; color: #ffffff; font-size: 14px; font-weight: bold; padding: 10px 24px; border-radius: 4px; text-decoration: none; }
      .footer-text { color: #80868b; font-size: 11px; line-height: 16px; margin: 24px 0 0 0; }
    </style>
    </head>
    <body>
    <p style="margin:16px 24px 4px 24px;">FakeDocs Weekly Update (UITest)</p>
    <p style="margin:0 24px 16px 24px;">FakeDocs をご利用いただきありがとうございます</p>
    <div style="text-align:center; padding:8px 0 24px 0;">
      <img src="\(uitestFakeHTMLMessagePlaceholderImage)" width="320" height="120" alt="FakeDocs">
    </div>
    <div class="content">
      <p class="headline">共同編集がさらに高速になりました</p>
      <p class="body-text">FakeDocs の最新アップデートでは、複数人での同時編集時の反映速度が大幅に改善されました。大きなドキュメントでもストレスなく共同作業を進めていただけます。</p>
      <p class="body-text">今回のアップデートには、コメント通知まわりの改善やモバイル版での表示速度向上も含まれています。詳しい変更点は以下のリンクからご確認いただけます。</p>
      <a class="cta" href="https://example.com/fakedocs-updates">アップデートの詳細を見る</a>
      <p class="footer-text">このメールは FakeDocs アカウントをお持ちの方にお送りしている週刊ニュースレターです。配信停止をご希望の場合は<a href="https://example.com/fakedocs-unsubscribe" style="color:#80868b;">こちら</a>から手続きできます。</p>
    </div>
    </body>
    </html>
    """

    /// Task #112 — see the `UITestFakeHTMLMessage`配列のdoc comment
    /// (`whiteCardHeroNotice`項) 参照。ユーザー提供の実メール `readdle.eml`
    /// の構造 (白背景の本文カード、Gmail限定`u+.body`セレクタによる無害な
    /// `mix-blend-mode`ハック、不可視の結合文字を含む隠しプリヘッダ、
    /// インライン`style`と`<style>`ブロックの両方に混在する`#333333`/
    /// `rgb(51, 51, 51)`系の低輝度文字色) を、架空ブランド・
    /// `example.com`のみで再現したもの。実物とちがい `body`自身に明示的な
    /// 白背景を与えている — `findEffectiveBackground`が
    /// `opaqueBackgroundOf(document.body)`を最優先で信頼する
    /// (`HTMLMessageView.swift`の`fitToWidthScript`参照) ので、実物のように
    /// 面積30%ルールに賭けなくても確実に「背景あり」経路
    /// (`decideDarkInversion`の`if (background)`枝) に入ることを保証できる。
    fileprivate static let uitestFakeHTMLMessageBodyWhiteCardHeroNotice = """
    <!doctype html>
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <meta name="viewport" content="width=device-width">
    <title>ScribbleSync is now SOC 2 certified. (UITest)</title>
    <style type="text/css">
      u+.body .gmail-screen { background: #000; mix-blend-mode: screen; }
      u+.body .gmail-difference { background: #000; mix-blend-mode: difference; }
      body { margin: 0; padding: 0; font-family: -apple-system, Helvetica, Arial, sans-serif; background-color: #ffffff; }
      .card { max-width: 480px; margin: 0 auto; padding: 0 24px 24px 24px; }
      .headline { color: #111111; font-size: 16px; font-weight: bold; margin: 0 0 12px 0; }
      .body-text { color: rgb(51, 51, 51); font-size: 14px; line-height: 20px; margin: 0 0 16px 0; }
      .footer-text { color: #333333; font-size: 11px; line-height: 16px; margin: 24px 0 0 0; }
    </style>
    </head>
    <body class="body" style="margin:0;padding:0;background-color:#ffffff;">
    <span style="display:none !important;font-size:0px;line-height:0;color:#ffffff;visibility:hidden;opacity:0;height:0;width:0;">ScribbleSync が SOC 2 認証を取得しました。詳しくは本文をご覧ください ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌</span>
    <div style="background-image:url(\(uitestFakeHTMLMessagePlaceholderImage)); background-color:#0d1b2a; padding:50px 24px;">
      <span class="gmail-screen"><span class="gmail-difference" style="color:#ffffff; font-size:14px;">What's new</span></span>
      <h1 style="color:#ffffff; font-size:26px; margin:8px 0 0 0;">ScribbleSync is now SOC 2 certified</h1>
    </div>
    <div class="card">
      <p class="headline">セキュリティに関する重要なお知らせ</p>
      <p class="body-text">ScribbleSync は第三者機関による監査を経て、SOC 2 Type II 認証を取得しました。お客様のデータは引き続き高い水準で保護されており、今回の認証はその取り組みを第三者の立場から裏付けるものです。</p>
      <p class="body-text">認証の詳細および監査レポートの請求方法については、以下のリンクからご確認いただけます。ご不明な点がございましたらサポートまでお問い合わせください。</p>
      <a href="https://example.com/scribblesync-soc2" style="display:inline-block;background-color:#128cfc;color:#ffffff;font-size:14px;font-weight:bold;padding:10px 24px;border-radius:4px;text-decoration:none;">詳しく見る</a>
      <p class="footer-text">このメールは ScribbleSync アカウントをお持ちの方にお送りしています。配信停止をご希望の場合は<a href="https://example.com/scribblesync-unsubscribe" style="color:#333333;">こちら</a>から手続きできます。</p>
    </div>
    </body>
    </html>
    """

    /// Task #128 (実機報告「英語メールなのに翻訳ボタンが押せない」— Okta の
    /// サインオン通知メール, scratchpad/signon.eml — 実アドレス入りのため
    /// コミット不可): 実物と同じ「英語のみ・テーブルベースの構造化レイアウト・
    /// SSO/認証プロバイダ系の通知テンプレート」という形を、架空ブランド名
    /// (Example App / IdP) だけで再現したもの。実物の文面・ロゴ・宛先は一切
    /// 含まない — このフィクスチャ自体は翻訳ボタンの表示条件バグ (この上の
    /// `uitestFakeHTMLMessages`配列でこのフィクスチャに付けている
    /// `detectedLanguage: "fr"`が本題) を再現するための入れ物で、HTML の
    /// 構造そのもの (どこかで抽出/接続が壊れるような特殊なマークアップ) を
    /// 疑う調査は本タスクの範囲では実機ログでしか確定できなかった
    /// (`MessageView.translationGateLogger`のdoc comment参照) ため、ここでは
    /// 「一見して英語だと分かる、ごく普通のテーブルベースSSO通知」という
    /// 現実的な最小形にとどめている。
    fileprivate static let uitestFakeHTMLMessageBodySSONotice = """
    <!doctype html>
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <meta name="viewport" content="width=device-width">
    <title>New sign-in to Example App (UITest)</title>
    </head>
    <body style="margin:0;padding:0;background-color:#f4f4f4;font-family:Helvetica,Arial,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#f4f4f4;">
    <tr><td align="center" style="padding:32px 16px;">
    <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="background-color:#ffffff; border-radius:4px;">
    <tr><td style="padding:24px; border-bottom:1px solid #e0e0e0;">
      <span style="color:#1c1c1c; font-size:18px; font-weight:bold;">Example App</span>
    </td></tr>
    <tr><td style="padding:24px;">
      <p style="color:#1c1c1c; font-size:16px; margin:0 0 16px 0;">New sign-in to Example App</p>
      <p style="color:#4a4a4a; font-size:14px; line-height:20px; margin:0 0 16px 0;">We noticed a new sign-in to your Example App account. If this was you, no action is needed.</p>
      <table role="presentation" cellpadding="0" cellspacing="0" style="width:100%; margin:0 0 16px 0;">
        <tr><td style="color:#767676; font-size:13px; padding:4px 0;">Browser</td><td style="color:#1c1c1c; font-size:13px; padding:4px 0;" align="right">Example Browser</td></tr>
        <tr><td style="color:#767676; font-size:13px; padding:4px 0;">Location</td><td style="color:#1c1c1c; font-size:13px; padding:4px 0;" align="right">Example City, Example Country</td></tr>
        <tr><td style="color:#767676; font-size:13px; padding:4px 0;">Date</td><td style="color:#1c1c1c; font-size:13px; padding:4px 0;" align="right">August 3, 2026, 9:00 AM UTC</td></tr>
      </table>
      <p style="color:#4a4a4a; font-size:14px; line-height:20px; margin:0 0 16px 0;">If you don't recognize this activity, please secure your account immediately by resetting your password.</p>
      <a href="https://example.com/account/security" style="display:inline-block;background-color:#0066cc;color:#ffffff;font-size:14px;font-weight:bold;padding:10px 24px;border-radius:4px;text-decoration:none;">Secure my account</a>
    </td></tr>
    <tr><td style="padding:16px 24px; border-top:1px solid #e0e0e0;">
      <p style="color:#9a9a9a; font-size:11px; line-height:16px; margin:0;">This is an automated message from Example App. Please do not reply to this email.</p>
    </td></tr>
    </table>
    </td></tr>
    </table>
    </body>
    </html>
    """

    /// Task #133 (実機報告「引用折りたたみがHTMLメールで効かない」— #123の
    /// 折りたたみはプレーンテキスト表示限定だったが、実際のGmailはほぼ全部
    /// HTML付きでHTML表示が優先されるため実機で機能しなかった、ユーザー提供
    /// の実メール`yoyaku.eml`で再現・修正): `html-9`シナリオ (index 8はTask #128の
    /// SSO通知フィクスチャがすでに使用中のため、9から採番) — 実物と同じ
    /// Gmail HTML の引用構造 (`<div class="gmail_quote">` が
    /// `<div class="gmail_attr">`(帰属行) と入れ子の
    /// `<blockquote class="gmail_quote" style="...border-left...">`を包む、
    /// 2段ネスト) を持つが、内容は実物と無関係な架空の予約確認シナリオ・
    /// 架空名・example.com アドレスに差し替えた匿名フィクスチャ (実物は
    /// 機微データのためコミット禁止 — `docs/design-system.md`のTask #133
    /// 節「検証」参照。実物での確認はシミュレータへの一時注入で別途行い、
    /// 確認後にコードをrevertした)。
    /// `HTMLMessageView`には新規部分のHTMLだけが渡り、引用履歴 (2段) は
    /// `QuoteHistorySectionView`のトグル+カードに折りたたまれることを
    /// スクリーンショットで確認する用途。
    fileprivate static let uitestFakeHTMLMessageBodyGmailQuoteHistory = """
    <div dir="ltr"><div dir="auto">田中さん</div><div dir="auto">承知しました、21日の11時でお願いします。</div><div dir="auto">当日はよろしくお願いいたします。</div><div><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">2026年7月20日(月) 15:00 田中花子 &lt;<a href="mailto:hanako@example.com">hanako@example.com</a>&gt;:</div><blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex"><div dir="auto">ご予約ありがとうございます。</div><div dir="auto">21日11時でお取りできます。</div><div dir="auto">前日までにお店へご確認のお電話をお願いいたします。</div><div><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">2026年7月20日(月) 14:30 佐藤太郎 &lt;<a href="mailto:taro@example.com">taro@example.com</a>&gt;:</div><blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex"><div dir="auto">はじめまして、佐藤です。</div><div dir="auto">7月21日の11時に予約をお願いしたいのですが、空いていますでしょうか。</div><div dir="auto">よろしくお願いいたします。</div></blockquote></div></div></blockquote></div></div></div>
    """

    /// Task #205 (実機報告: `~/Downloads/` の実メール — サブスクリプション
    /// メンテナンス完了通知、送信元はメール配信サービス — で「画像が出ない」
    /// 「幅・高さが崩れる」「ソースを表示が空白」の3件が同時に報告された):
    /// このフィクスチャは**その実メールの内容ではなく、症状の再現に必要な
    /// 構造だけを架空の内容で書き起こしたもの** (実名・実メールアドレス・
    /// 実サービス名は一切含まない — `CLAUDE.md`の実名混入禁止事項)。
    ///
    /// 再現に必要だった構造上の特徴 (3点とも実際にこの構造で再現・修正
    /// 確認済み — `docs/design-system.md`のTask #205節参照):
    /// 1. **画像2枚とも `https` ではなく `http`** (ロゴ画像 + 開封トラッキング
    ///    用の1x1透明画像)、ホストは実在しない `.test` ドメイン (RFC 2606 —
    ///    DNS解決が確実に失敗する、実ネットワークに依存しないフィクスチャに
    ///    するため)。修正前の実機では、`http`の平文通信をこのアプリの
    ///    Info.plist が ATS 例外を持たず既定でブロックしていたため
    ///    「リモート画像を自動で読み込む」(既定 ON) であっても実際には
    ///    読み込みに失敗し壊れたアイコンになる一方、「画像を表示」バナーは
    ///    (このアプリ自身の`WKContentRuleList`は`allowsExternalContent==
    ///    true`なので効いておらず) 出ない、という実機報告と一致する状態
    ///    だった — この`.test`ドメインの構成では失敗の理由こそ ATS では
    ///    なく DNS 解決不能だが、`<img>`の`error`イベントが発火して
    ///    `fitToWidthScript`のプレースホルダ差し替え (Task #205) が働く
    ///    という見た目は同じで、それ単体の確認には十分。ATS 例外
    ///    (`NSAllowsArbitraryLoadsInWebContent`) 自体が実際に効くかの確認は
    ///    実機/実ネットワーク越しの別途確認が必要 — `docs/design-system.md`
    ///    のTask #205節参照。
    /// 2. **`<table width="100%" ...>`** (ネストした複数階層) **と、その内側
    ///    に `style="width:100%; max-width:700px;"` で上限を掛けた1枚** —
    ///    「幅いっぱいに広がるが700pxで頭打ち」という現代的なレスポンシブ
    ///    メールテーブルの定石。
    /// 3. **濃色背景の `<td style="background-color:...">` を持つフッター
    ///    テーブル** — 2の`width="100%"`テーブルの内側にネストしており、
    ///    2の幅計算が壊れるとこのフッターの帯だけが中途半端な幅に縮み、
    ///    右側に白い余白が残る (実機報告「フッターの濃い帯が途中で切れ、
    ///    右側に白い領域が残る」の再現条件)。
    fileprivate static let uitestFakeHTMLMessageBodyResponsiveTableFooterNotice = """
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
    <html>
    <body>
    <center class="wrapper" bgcolor="#FFFFFF">
    <table cellpadding="0" cellspacing="0" border="0" width="100%" class="wrapper" bgcolor="#FFFFFF">
    <tr><td valign="top" bgcolor="#FFFFFF" width="100%">
    <table width="100%" role="content-container" align="center" cellpadding="0" cellspacing="0" border="0">
    <tr><td width="100%">
    <table width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr><td>
    <table width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; max-width:700px;" align="center">
    <tr><td style="padding:0px; color:#000000; text-align:left;" bgcolor="#ffffff" width="100%" align="left">
    <table width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr><td style="padding:20px 0px 10px 40px;" valign="top" align="left">
    <img border="0" style="display:block;" width="120" height="38" alt="Example" src="http://cdn.otegami.test/logo/240x75.png">
    </td></tr>
    </table>
    <table width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr><td style="padding:0px 0px 1px 0px;" bgcolor="#b5babd" height="1"></td></tr>
    </table>
    <table width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr><td style="padding:10px 40px 10px 40px; line-height:32px;" valign="top"><span style="font-size:28px;">Example Maintenance Service</span></td></tr>
    </table>
    <table width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr><td style="padding:10px 40px 10px 40px; line-height:18px;" valign="top"><span style="font-size:14px;">Hi,<br><br>Service maintenance for subscription #0000000 (ExampleEcosystem) in account production is now complete.<br><br>Thank you,<br>Example</span></td></tr>
    </table>
    <table width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr><td style="padding:20px 40px 20px 40px; line-height:12px; background-color:#091A23;" valign="top" bgcolor="#091A23">
    <div style="text-align:center;"><span style="font-size:9px; color:#7f7f7f;">&copy; 2026 Example, Inc. All Rights Reserved.</span></div>
    <div style="text-align:center;"><span style="font-size:9px; color:#7f7f7f;">If you no longer wish to receive these emails, you may unsubscribe at any time (<a href="https://unsub.otegami.test/abc"><span style="color:#7f7f7f;"><u>Access Management</u></span></a>).</span></div>
    </td></tr>
    </table>
    </td></tr>
    </table>
    </td></tr>
    </table>
    </td></tr>
    </table>
    </td></tr>
    </table>
    </td></tr>
    </table>
    </center>
    <img src="http://track.otegami.test/wf/open?upn=uitest-fake" alt="" width="1" height="1" border="0" style="height:1px !important;width:1px !important;">
    </body>
    </html>
    """

    /// 実機報告 (ユーザー提供の実メール rakuten.eml — 証券会社の投信基準
    /// 価額通知、内容は伏せて構造だけ再現): 「ダークモードで色がおかしい」
    /// 「macOSでスクロールできない」の2件を再現する構造 — `body`自身は
    /// `text-align:center`だけで背景色を一切指定せず、複数の`<table>`に
    /// 分かれた本文のうち一覧テーブルの見出し行だけが`background-color:
    /// #e1edf3`(薄い水色)を明示指定、データ行自体は背景色指定なしで文字は
    /// 全体を包む最初の`<tr style="color:#333;...">`からの継承のみ、という
    /// 「背景が最後まで解決しない (`findEffectiveBackground`がnullを返す)
    /// が、文字色は暗いグレーを明示的に継承している」ケース。ロゴ画像
    /// (`600x92`) と10行超のデータ行を持つ縦長の表がテーブル本体の大半を
    /// 占める — 展開時の固定高さバジェット (`ThreadDetailView
    /// .expandedMessageHeight(in:)`) を優に超える長さで、macOS版の
    /// `HTMLWebViewRepresentable`にiOS版と同じ内部スクロール無効化/高さ
    /// 実測がなかった問題を再現する。
    static let uitestFakeHTMLMessageBodyFundPriceNotificationTallTable = """
    <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
    <html lang="ja">
    <head>
    <meta http-equiv="Content-Language" content="ja">
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    </head>
    <body style="text-align:center">
    <div style="width:600px;">
    <table style="border-collapse:collapse;">
    <tr style="line-height:1.4em;color:#333;font-size:12px;"><td>
    <h1 style="margin:0 0 15px 0;">
    <img src="http://cdn.otegami.test/logo/fund-price-notice-600x92.gif" alt="投信基準価額メール" width="600" height="92"></h1>
    <p style="margin:0 0 10px 0;">基準価額のお知らせ</p>
    <p style="margin:0 0 10px 0;">◆基準価額メール対象ファンド一覧</p>
    </td></tr></table>
    <table style="width:600px;border-collapse:collapse;font-size:15px;text-align:right;">
    <tr style="background-color:#e1edf3;margin:3px 4px 1px 4px;line-height:12.0pt;text-align:center;">
    <th width="35%" style="border:solid 1px #c3c3c3;font-weight:normal;">ファンド名(委託会社)</th>
    <th width="20%" style="border:solid 1px #c3c3c3;font-weight:normal;">基準価額</th>
    <th width="20%" style="border:solid 1px #c3c3c3;font-weight:normal;">前週比較<br>金額(%)</th>
    <th width="35%" style="border:solid 1px #c3c3c3;font-weight:normal;">リターン(年率)</th>
    </tr>
    <tr><td style="border:solid 1px #c3c3c3;text-align:left;">Example グローバル債券オープン(毎月決算型)<br><font size=-2>(Exampleアセットマネジメント)</font></td>
    <td style="border:solid 1px #c3c3c3;">5,119円</td>
    <td style="border:solid 1px #c3c3c3;">-45円<br>(-0.87%)</td>
    <td style="border:solid 1px #c3c3c3;">31.09%</td></tr>
    <tr><td style="border:solid 1px #c3c3c3;text-align:left;">Example Slim 新興国株式インデックス<br><font size=-2>(三井Example アセットマネジメント)</font></td>
    <td style="border:solid 1px #c3c3c3;">25,394円</td>
    <td style="border:solid 1px #c3c3c3;">-2,267円<br>(-8.2%)</td>
    <td style="border:solid 1px #c3c3c3;">49.12%</td></tr>
    <tr><td style="border:solid 1px #c3c3c3;text-align:left;">Example Slim 全世界株式(オール・カントリー)<br><font size=-2>(三井Example アセットマネジメント)</font></td>
    <td style="border:solid 1px #c3c3c3;">37,521円</td>
    <td style="border:solid 1px #c3c3c3;">-722円<br>(-1.89%)</td>
    <td style="border:solid 1px #c3c3c3;">32.81%</td></tr>
    <tr><td style="border:solid 1px #c3c3c3;text-align:left;">Example Slim 米国株式(S&P500)<br><font size=-2>(三井Example アセットマネジメント)</font></td>
    <td style="border:solid 1px #c3c3c3;">43,950円</td>
    <td style="border:solid 1px #c3c3c3;">-719円<br>(-1.61%)</td>
    <td style="border:solid 1px #c3c3c3;">30.79%</td></tr>
    <tr><td style="border:solid 1px #c3c3c3;text-align:left;">ExampleNEXT FANG+インデックス<br><font size=-2>(大和Example アセットマネジメント)</font></td>
    <td style="border:solid 1px #c3c3c3;">91,805円</td>
    <td style="border:solid 1px #c3c3c3;">-1,757円<br>(-1.88%)</td>
    <td style="border:solid 1px #c3c3c3;">23.85%</td></tr>
    <tr><td style="border:solid 1px #c3c3c3;text-align:left;">ExamplePlus 世界トレンド・テクノロジー株(Zテック20)<br><font size=-2>(大和Example アセットマネジメント)</font></td>
    <td style="border:solid 1px #c3c3c3;">13,862円</td>
    <td style="border:solid 1px #c3c3c3;">-578円<br>(-4%)</td>
    <td style="border:solid 1px #c3c3c3;">37.96%</td></tr>
    <tr><td style="border:solid 1px #c3c3c3;text-align:left;">example・プラス・S&P500インデックス・ファンド<br><font size=-2>(exampleグループ投資顧問)</font></td>
    <td style="border:solid 1px #c3c3c3;">19,556円</td>
    <td style="border:solid 1px #c3c3c3;">-319円<br>(-1.61%)</td>
    <td style="border:solid 1px #c3c3c3;">30.77%</td></tr>
    <tr><td style="border:solid 1px #c3c3c3;text-align:left;">example・プラス・オールカントリー株式インデックス・ファンド<br><font size=-2>(exampleグループ投資顧問)</font></td>
    <td style="border:solid 1px #c3c3c3;">19,344円</td>
    <td style="border:solid 1px #c3c3c3;">-361円<br>(-1.83%)</td>
    <td style="border:solid 1px #c3c3c3;">32.73%</td></tr>
    <tr><td style="border:solid 1px #c3c3c3;text-align:left;">example・全米株式インデックス・ファンド<br><font size=-2>(exampleグループ投資顧問)</font></td>
    <td style="border:solid 1px #c3c3c3;">44,465円</td>
    <td style="border:solid 1px #c3c3c3;">-717円<br>(-1.59%)</td>
    <td style="border:solid 1px #c3c3c3;">31.08%</td></tr>
    <tr><td style="border:solid 1px #c3c3c3;text-align:left;">年金積立 J グロース<br><font size=-2>(アモーヴィア・アセットマネジメント)</font></td>
    <td style="border:solid 1px #c3c3c3;">73,161円</td>
    <td style="border:solid 1px #c3c3c3;">-934円<br>(-1.26%)</td>
    <td style="border:solid 1px #c3c3c3;">43.2%</td></tr>
    </table>
    <table style="border:white 0px solid;width:600px;border-collapse:collapse;">
    <tr style="text-align:left;line-height:1.4em;width:600;color:#333;margin-left:auto;font-size:12px;margin-right:auto">
    <td>
    <p style="text-align:left;margin:0 0 10px 0;padding:0;">
    ・本メールは、投資信託の基準価額について、下記の条件を満たすお客様にお送りしております。<br>
    &nbsp;&nbsp;・当該ファンドを保有されているお客様<br>
    &nbsp;&nbsp;・基準価額メールを設定されたお客様<br>
    ・基準価額は営業日時点の数値を表示しております。<br>
    ・リターン(年率)は、直近1年間の分配金込みの基準価額変動率を表示しております。<br>
    </p>
    </td></tr></table>
    <table style="border:white 0px solid;width:600px;border-collapse:collapse;">
    <tr style="text-align:left;line-height:1.4em;width:600px;color:#333;margin-left:auto;font-size:12px;margin-right:auto">
    <td>
    <p style="text-align:left;margin:0 0 10px 0;padding:0;">本メールはシステムにより自動配信されています。ご返信いただいてもお答えできませんのでご了承ください。</p>
    </td></tr></table>
    </div>
    </body>
    </html>
    """

    // MARK: - Task #66 (カレンダー招待メール対応) UITest fixture

    /// `OTEGAMI_UITEST_INSERT_FAKE_CALENDAR_INVITE`'s `text/calendar`
    /// content — same event as `dev/mailstack/seed/fixtures/
    /// 36-calendar-invite-google.eml`'s `METHOD:REQUEST` part, so a
    /// screenshot taken via this escape hatch and one taken against the
    /// real dev mailstack (once IMAP-in-Simulator is reliable, or on a
    /// physical device) show the identical invite.
    static let uitestFakeCalendarInviteICS = """
    BEGIN:VCALENDAR
    PRODID:-//Google Inc//Google Calendar 70.9054//EN
    VERSION:2.0
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    DTSTART:20260803T060000Z
    DTEND:20260803T070000Z
    DTSTAMP:20260728T000000Z
    ORGANIZER;CN=Otegami Organizer:mailto:organizer@otegami.test
    UID:uitest-fake-calendar-invite-event@otegami.test
    ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Fake Calendar Invite:mailto:uitest-fake-calendar-invite@example.com
    CREATED:20260728T000000Z
    DESCRIPTION:四半期の計画会議です。事前に資料をご確認ください。
    LAST-MODIFIED:20260728T000000Z
    LOCATION:会議室A / Conference Room A
    SEQUENCE:0
    STATUS:CONFIRMED
    SUMMARY:四半期計画会議 (Quarterly Planning Sync)
    TRANSP:OPAQUE
    END:VEVENT
    END:VCALENDAR
    """

    /// Task #84: real-device report (screenshot) showed a genuine Google
    /// Calendar invite's HTML rendering with washed-out light-gray text on
    /// the app's dark canvas — this reproduces that mail's actual shape
    /// (no `background-color` anywhere, secondary labels in `#5f6368`,
    /// primary values in `#3c4043`, matching `dev/mailstack/seed/fixtures/
    /// 37-calendar-invite-nested-alternative.eml`'s `text/html` part) so
    /// `scripts/verify-screen.sh calendar-invite`'s screenshot can show
    /// whether the dark-mode "keep light" heuristic (`HTMLDocumentBuilder
    /// .wrap`/`fitToWidthScript`'s `decideDarkInversion`, Task #80) actually
    /// fires for this content.
    static let uitestFakeCalendarInviteHTML = """
    <html><body style="font-family:Roboto,Arial,sans-serif;">
    <table role="presentation" cellpadding="0" cellspacing="0" style="background-color:#1a73e8; border-radius:4px;">
    <tr><td style="padding:12px 24px;"><a href="https://meet.otegami.test/abc-defg-hij" style="color:#ffffff; font-size:14px; font-weight:bold; text-decoration:none;">Google Meet に参加する</a></td></tr>
    </table>
    <p style="color:#5f6368; font-size:12px; margin:16px 0 2px 0;">会議のリンク</p>
    <p style="color:#3c4043; font-size:14px; margin:0 0 16px 0;">meet.otegami.test/abc-defg-hij</p>
    <p style="color:#5f6368; font-size:12px; margin:0 0 2px 0;">日時</p>
    <p style="color:#3c4043; font-size:14px; margin:0 0 16px 0;">2026/08/03 (月曜日) &middot; 15:00 &ndash; 16:00 (日本標準時)</p>
    <p style="color:#5f6368; font-size:12px; margin:0 0 2px 0;">ゲスト</p>
    <p style="color:#3c4043; font-size:14px; margin:0;">Otegami Organizer - 主催者</p>
    <p style="color:#3c4043; font-size:14px; margin:0 0 16px 0;">Fake Calendar Invite</p>
    <p style="color:#5f6368; font-size:12px; margin:0;">このメールへの返信、またはアプリの「承諾」「辞退」「未定」ボタンで出欠をお知らせください。</p>
    </body></html>
    """
}
