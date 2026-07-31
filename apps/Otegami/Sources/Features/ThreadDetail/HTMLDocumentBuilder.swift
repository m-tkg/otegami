import Foundation

/// The full HTML document loaded into the web view: wraps the message's
/// body-only HTML (`MessageBodyContent.html`, from MailCore2's
/// `htmlBodyRendering()`) with a minimal reset so it reads legibly in both
/// light and dark mode without the message's own styling fighting the
/// app's chrome (plan: "背景透過・文字色継承・max-width: 100%・画像縮小").
///
/// 実機フィードバック第3弾 (B): a marketing/notification HTML mail (参考画像1)
/// rendered at desktop width — a large logo cropped, text pushed off the
/// right edge — despite this file already carrying a viewport `<meta>` and
/// `max-width: 100% !important` on images/tables *before* this fix. See
/// `extractBodyContent(from:)`'s doc comment for the actual root cause this
/// traced to.
///
/// fit-to-width (実機フィードバック — 楽天銀行のような幅600-800px級の固定幅
/// テーブルHTMLメールが等倍描画され、右端がクリップ・文字が巨大に見える):
/// 上の`table { width: auto !important; }`等の CSS リセットだけでは、
/// `white-space: nowrap`が指定されたセル (幅寄せのための隣接ラベル/値など、
/// 固定幅前提のテンプレートで頻出) の**描画内容**がボックス自体の幅制約を
/// 無視してはみ出す実際のケースをカバーしきれない — ボックスの幅は
/// `max-width: 100%!important`で正しく制約されていても、そのボックスから
/// 中身が視覚的にはみ出すのは別の話 (はみ出た分は`overflow-x: hidden`で
/// クリップされるだけで、縮小はされない)。Spark 等の参考実装と同じ
/// "fit-to-width" — 実際に必要な幅 (`scrollWidth`) を計測し、ビューポート幅
/// を超えていれば `transform: scale()` でページ全体を視覚的に縮小する —
/// で解決する。`wrap(bodyHTML:)`が本文を`#otegami-fit-outer`/
/// `#otegami-fit-inner`の入れ子`div`で包むのはこのための足場: `outer`は
/// `overflow: hidden`を持つ固定サイズのコンテナ (縮小後の見た目の寸法に
/// JS側で明示的に合わせる — `transform`はペイント時の視覚効果でしかなく
/// レイアウト上のボックスサイズを変えないため、`outer`側で明示しないと
/// 縮小後も元の大きな高さ分だけ下に空白が残ってしまう)、`inner`が実際に
/// `scale()`される対象。JS 本体は `HTMLWebViewCoordinator
/// .fitToWidthScript`/`applyFitToWidth(to:)` — `didFinish`(ページ読み込み
/// 完了)後に評価される。ページ自身のスクリプトは`allowsContentJavaScript
/// = false`で無効化済みだが、ホスト側 (Swift) からの`evaluateJavaScript`
/// 呼び出しはこの設定と独立に動作する (WebKit の一般的な仕様: `allowsContentJavaScript`
/// が制限するのはページ自身が埋め込むスクリプト/イベントハンドラ/
/// `javascript:` URLであり、アプリ自身が能動的に呼ぶ`evaluateJavaScript`
/// はこの制限を受けない) — 同じ仕組みを1i の HTML レイアウト保持翻訳
/// (`HTMLTranslationController`) も流用する。
///
/// HTML 表示の高さ問題 (B の直後の実機フィードバック): B のこの `extractBodyContent`
/// が、実在するマーケティング/通知テンプレートが `<head>` にごく普通に含む
/// **MSO (Outlook) 条件付きコメント** (`<!--[if mso]> ... <![endif]-->`、
/// 別レンダリングエンジン向けのフォールバックを丸ごと埋め込むのが一般的な
/// パターン) の中にたまたま `<body`/`</body>` という文字列が含まれていた場合
/// (例: コメント内のフォールバック骨格 `<html><body>...</body></html>` や、
/// デバッグ用に埋め込まれた完全なコピー)、それを本物のタグと誤認して本文の
/// 大半を切り捨てていた — `stripHTMLComments(from:)` で HTML コメントを丸ごと
/// 除去してからタグ探索する形に修正済み (コメントはブラウザ上も非表示なので
/// 除去しても見た目に影響しない)。閉じタグ側も `.backwards` で「文書中最後の
/// `</body>`」を探すよう変更 — 開始タグ検出は最初の `<body` のままで正しい
/// (コメント除去済みなので、もう `<head>` 内の紛れ込みを拾わない)。
/// 実機スクリーンショット (WebView の表示エリアが画面の半分程度で頭打ちに
/// なり、本文が途中で切れ、その下に大きな空白が残る) から発見。
/// `extractHeadStyles(from:)` も参照 — 同じ B の変更が本文抽出と一緒に元
/// `<head>` の `<style>` ブロックも丸ごと捨てていた副作用の修正。
///
/// **Task #205 (実機報告: Redis の実メンテナンス通知メールで幅・高さ両方が
/// おかしい)**: `wrap(bodyHTML:)`の `<style>` の `*:not(img) { max-width:
/// 100% !important; ... }`/`table { width: auto !important; }` が、img 向け
/// に既に対策済みだった「著者の明示指定を踏み潰す」バグ (Task #56 の
/// `img:not([style*="max-width" i])`/`img[style*="max-width" i]`ペア参照)
/// を img 以外の要素・table では放置していた。実メールは
/// `<table style="width:100%; max-width:700px;" align="center">` という
/// 「幅いっぱいに広がるが700pxで頭打ち」の現代的なレスポンシブテーブルを
/// 使っていたが、この `!important` 上限がその著者指定 (`max-width:700px`)
/// を「100%＝ビューポート幅」で上書きし、かつ内側の `width="100%"`の
/// モジュールテーブル群 (フッターの濃色帯を含む) は逆に `width: auto
/// !important`で著者の「幅いっぱいに」という指定自体を無効化していた —
/// 結果、フッターの帯が (700pxにも、ビューポート幅にも一致しない)
/// 中途半端な内容依存の幅に縮み、右側に白い余白が残った (実機報告の
/// 「フッターの濃い帯が途中で切れ、右側に白い領域が残る」)。ローカルの
/// WKWebView 計測スクリプトで実メール構造の再現データを使い、900px
/// ビューポートで再現 → 修正後に700px幅へ収まりセンター寄せされることを
/// 確認済み。修正は img と同じ「著者の明示指定がある要素は非`!important`
/// のフォールバックに倒す」形へ揃え、`table[width="100%"]`/`table[style*=
/// "width:100%" i]`を明示的に100%へ戻す行を追加した — 詳細は下の各ルール
/// のコメント、経緯は `docs/design-system.md` の Task #205 節参照。
enum HTMLDocumentBuilder {
    /// Task #45「ダークモードで文字が読めない」→ Task #51 で条件を絞り
    /// 込んだ経緯:
    ///
    /// Task #45 の初版は、メール自身が`mailDeclaresOwnDarkModeSupport
    /// (bodyHTML:)`で判定する自前のダークモード対応を持たない限り
    /// **常に**`#otegami-fit-inner`へ`filter: invert(1) hue-rotate
    /// (180deg)`(古典的な「反転」手法、NetNewsWire 等と同方式) を適用して
    /// いた。だがこれは「色指定を一切持たないメール」を壊す実機退行を
    /// 生んだ: そのようなメールは元々このファイル自身の CSS リセット
    /// (`:root { color-scheme: light dark; }` + `color: CanvasText`) の
    /// おかげで、ダークモード中は WebKit が自動的に明るい文字色を解決
    /// して正しく読めていた — そこへ無条件の反転がかかると、その明るい
    /// `CanvasText`が暗い文字色へ逆変換されてしまい、透明な (＝アプリの
    /// ダーク背景がそのまま透ける) 背景の上でほぼ読めなくなる。反転が
    /// 本当に必要なのは「メールが明示的にライト配色 (明るい背景) を
    /// 描画するよう指定している」場合だけで、「メールが何も指定して
    /// いない」場合は逆効果というのが実機の教訓。
    ///
    /// **Task #51 での修正**: 静的なタグ検査 (`mailDeclaresOwnDarkModeSupport`
    /// だけ) で invert するかどうかを決めるのをやめ、ページ読み込み後に
    /// JS で**実測**する方式に変えた。`wrap(bodyHTML:autoAdjustColorsInDarkMode:)`
    /// が行うのは「反転を検討してよいか」(`autoAdjustColorsInDarkMode`が
    /// true、かつメールが自前のダーク対応を持たない) を判定し、条件を
    /// 満たす場合だけ CSS のクラス (`.otegami-invert-for-dark`、下記) と、
    /// JS 側が実測結果を書き込む対象を示す `data-otegami-invert-check`
    /// 属性を仕込むところまで。**実際に invert するかどうかの最終判断は
    /// `HTMLWebViewCoordinator.fitToWidthScript`が画像読み込み完了後に
    /// 行う** — `body`/`#otegami-fit-inner`/本文中で最大面積を占める
    /// 背景要素の`getComputedStyle(...).backgroundColor`と、代表的な
    /// テキストノード数点の`color`を実際に読み取り、実効背景の輝度
    /// (WCAG 相対輝度、0.5 を閾値) が高い場合に限って`.otegami-invert-
    /// for-dark`クラスを`#otegami-fit-inner`へ付与する。背景が最後まで
    /// 透明で確定しない (＝色指定を一切持たないメール) 場合は**何も
    /// しない**(安全側のデフォルト) — これが今回の退行ケースを直す。
    /// 詳細な計測ロジックは `fitToWidthScript`のdoc comment参照。
    ///
    /// `img`/`picture`/`video`と、インライン`style`に`background-image`を
    /// 持つ要素には同じフィルタをもう一度適用して打ち消す (二重反転で
    /// 元の色に戻る) — 写真・ロゴが色反転して不自然にならないようにする
    /// ため。ブランドカラー (テキスト色・アクセント色) は反転後も概ね保た
    /// れる (色相環上で180度回転するため、青系統は青系統のまま程度の変化
    /// に留まることが多い)。
    ///
    /// メール自身が既にダークモード対応済みの場合は何もしない (二重に
    /// 反転させると壊れるため) — Spark/Gmail と同じ「メールが対応済みなら
    /// 尊重する」方針。実測はこの判定より**後**には効かない — 自前対応が
    /// あると分かった時点で`shouldConsiderDarkModeHandling`自体が false に
    /// なり、JS側の実測は一切走らない。
    ///
    /// **Task #80 でのさらなる変更 (実機動画 f012→f015 — MakerWorld 等の
    /// ライトデザインメールで「初期描画は正しいライト → 読み込み後に反転
    /// が後がけされて暗転する」チラつき + 反転アーティファクトの報告)**:
    /// 上の実測ロジック自体 (実効背景色/文字色の測定、Task #56 の「背景
    /// なし+暗文字」拡張分岐含む) はそのまま — 変わったのは**実測が
    /// 「介入が要る」と判定したときにどちらの対処をするか**。
    /// `autoAdjustColorsInDarkMode`の既定が ON→OFF に変わったのに伴い、
    /// 既定 (OFF) では**反転せずメール本来のライト配色のまま見せる**
    /// (`.otegami-keep-light-active`、下記) — 反転は明示的に ON にした
    /// ユーザー向けのオプトインになった。判定自体 (`shouldConsiderDark
    /// ModeHandling`) はこの設定値と無関係に常に行う (`autoAdjustColorsIn
    /// DarkMode`はもう判定条件に含めない) — 実際にどちらの対処になるかは
    /// `data-otegami-prefer-invert`属性経由でJSに伝わる。色指定を一切
    /// 持たないメールが「介入不要」判定に落ち着く (＝ダークネイティブの
    /// まま) のは従来どおり変わらない。
    ///
    /// **Task #98**: 「背景なし+暗文字」拡張分岐 (Task #56、上記) 自体の
    /// 実測ロジックをさらに一段拡張 — `HTMLWebViewCoordinator
    /// .explicitDarkTextIsMajority`のdoc comment参照。この関数 (`wrap`) 自体
    /// に変更はない (Swift側は相変わらず「介入を検討してよいか」までしか
    /// 決めない)。
    ///
    /// **Task #104**: このファイル自身が注入する3つの`<style>`タグに
    /// `data-otegami-base-style="1"`を付けるようになった (下記) — JS側の
    /// `collectExplicitColorSelectors`がメール自身の`<style>`ブロックだけを
    /// 走査し、このファイル自身のCSSルールを「著者の明示指定」と誤認しない
    /// ようにするための目印。判定ロジック自体 (「介入を検討してよいか」まで
    /// しか決めない、実際の判定はJS側) という役割分担は変わらない。
    static func wrap(bodyHTML: String, autoAdjustColorsInDarkMode: Bool, forceLightBackground: Bool = false, bottomContentInset: CGFloat = 0) -> String {
        let innerBody = extractBodyContent(from: bodyHTML)
        let originalHeadStyles = extractHeadStyles(from: bodyHTML)
        // Task #51: この時点ではまだ「介入 (反転 or ライト維持) を検討して
        // よいか」までしか決めない — 実際にどちらの対処を行うか (あるいは
        // 何もしないか) は実測 (`fitToWidthScript`の`decideDarkInversion`)
        // 任せ。変数名を旧来の`shouldInvertForDarkMode`から変えたのはこの
        // 意味の変化を明示するため。
        //
        // Task #80: `autoAdjustColorsInDarkMode`はもうここでの分岐条件に
        // 含めない — 「介入してよいか」自体は常に判定する (対処が要ると
        // 分かったときにどちらの対処 (ライト維持 or 反転) を選ぶかだけを
        // 左右する、下の`fitOuterAttributes`の`data-otegami-prefer-invert`
        // 経由でJSに伝える値になった)。これにより新既定
        // (`autoAdjustColorsInDarkMode == false`) でも「実効的にライト
        // デザインのメールをライトのまま見せる」判定自体は動く。
        //
        // Task #71 (「メールの背景を常に白に」): `forceLightBackground`が
        // 真なら、この判定自体を検討する余地を最初から無くす — 下の
        // `forceLightBackgroundStyle`がこの文書自体を無条件でライト固定
        // にするので、判定対象がそもそも存在しない (Gmailの「ライト表示」
        // 相当、色指定のないメールも含め常にライト)。
        let shouldConsiderDarkModeHandling = !forceLightBackground && !mailDeclaresOwnDarkModeSupport(html: bodyHTML)
        // Task #71: `:root`の`color-scheme: light dark;`(下の基本`<style>`)
        // と、メール自身の`<style>`(`originalHeadStyles`、この文書の`<head>`
        // 内でこの後に続く) が持ちうる`color-scheme`宣言の両方に確実に勝つ
        // よう`!important`。`html, body`の背景も同様に白へ固定 — メール
        // 自身の`<style>body{background:...}`が非`!important`のライト背景
        // を指定していればそのまま活きる (この状況では無害) が、万一暗い
        // 背景を指定していた場合や、何も指定していない場合 (このファイル
        // 自身の`background: transparent`のままだとアプリのダーク背景が
        // 透けてしまう) にも確実にライト表示になるようにするための保険。
        let forceLightBackgroundStyle = forceLightBackground ? """
        <style data-otegami-base-style="1">
          :root { color-scheme: light !important; }
          html, body { background-color: #ffffff !important; }
        </style>
        """ : ""
        let darkModeInvertStyle = shouldConsiderDarkModeHandling ? """
        <style data-otegami-base-style="1">
          @media (prefers-color-scheme: dark) {
            /* Task #45/#51: ライト前提で書かれたメールをダークモードでも
               読めるようにする「反転」手法 — Task #80 でこの手法を選ぶのは
               「ダークモードで配色を自動調整」トグルを明示的に ON にした
               ユーザーだけになった (新既定は下の `otegami-keep-light-for-dark`
               を使う)。実際にこのクラスが付くかどうかは JS の実測
               (`fitToWidthScript`) 任せ — ここではクラスが付いたときの
               見た目だけを用意する。#otegami-fit-inner は fit-to-width の
               scale(transform) も受けうる同じ要素だが、filter と
               transform は独立したペイント/コンポジット効果同士で、
               レイアウト計算 (scrollWidth/scrollHeight) には互いに影響
               しない。 */
            #otegami-fit-inner.otegami-invert-for-dark {
              filter: invert(1) hue-rotate(180deg);
            }
            /* 画像・動画・背景画像は反転を打ち消してもう一度反転 (＝
               元の色に戻す) — 写真やロゴの色が不自然に変わらないように
               する。`[style*="background-image"]` は CSS ではクラス経由の
               background-image までは拾えないが、「やり過ぎない範囲で」
               という方針どおり、インライン style で背景画像を指定する
               頻出パターンだけを対象にした現実的な範囲。 */
            #otegami-fit-inner.otegami-invert-for-dark img,
            #otegami-fit-inner.otegami-invert-for-dark picture,
            #otegami-fit-inner.otegami-invert-for-dark video,
            #otegami-fit-inner.otegami-invert-for-dark [style*="background-image"] {
              filter: invert(1) hue-rotate(180deg);
            }
            /* 実機フィードバック (MakerWorld 比較 — 右端に縦の白帯・セクション
               間の色ムラ): `.otegami-invert-for-dark`のフィルタは
               `#otegami-fit-inner`とその子孫にしかかからないため、メール
               自身の `<style>body{background:#fff}`のようなルール
               (`extractHeadStyles`がこのファイル自身の `background:
               transparent` の後に差し込むので、非`!important`同士なら
               後勝ちでそちらが実際に採用される) はそのまま`body`の実ペイント
               色として残ってしまい、`body`のpadding分の余白 (左右12px) や、
               要素どうしの隙間で本来のライト背景色がそのまま透けて見えて
               いた — 「反転された本文の中に反転されていない帯が残る」の
               正体。`html.otegami-invert-active`はJS側 (`decideDarkInversion`)
               が実際に反転を決めたときだけ付与するクラスで、その間だけ
               `body`/`html`自身の背景を強制的に透明化する — 反転しない
               メール (ダークモード対応済み・元から暗背景等) の見た目は
               一切変えない。`body`本来の背景色は同じJSが`#otegami-fit-inner`
               自身へ移し替える (下記コメント) ので、キャンバス色そのものは
               失われず、フィルタの対象内に収まる。 */
            html.otegami-invert-active,
            html.otegami-invert-active body {
              background-color: transparent !important;
            }
            /* 実機フィードバック (MakerWorld ロゴが暗背景に沈む): 透過PNGの
               ロゴ (黒い線画、背景なし) は上の img 二重反転ルールで「元の
               色 (黒)」に戻る一方、ページ側は反転済みで暗背景になるため、
               黒の線画が暗い背景にほぼ同化して見えなくなる — Gmail のダーク
               表示が小さい透過ロゴにやっているのと同じ対処 (白系の背景
               チップを敷いて元の配色のまま読めるようにする) を採る。
               どの画像が「透過ロゴ」かをCSS/DOMだけから確実に判定するのは
               難しいため、`decideDarkInversion`が実測した画像の内在サイズ
               (`naturalWidth`/`naturalHeight`) が両方 200px 以下という
               実用的なヒューリスティクスで対象を絞る (写真本体は大抵もっと
               大きいので誤爆しにくい、という判断 — 詳細は`docs/design-system.md`
               参照)。対象の画像だけに `otegami-invert-logo-chip` クラスが
               付く。 */
            #otegami-fit-inner.otegami-invert-for-dark img.otegami-invert-logo-chip {
              background-color: rgba(255, 255, 255, 0.94);
              border-radius: 6px;
              padding: 4px;
            }
            /* Task #80 (新既定 — チラつき+反転アーティファクトの実機
               フィードバックを受けた変更): 「ダークモードで配色を自動
               調整」が OFF (既定) のとき、`decideDarkInversion`が「介入が
               要る」と判定したメール (実効的にライトデザイン — 明背景を
               実測、または背景なし+暗い文字色を実測、Task #56 の
               「背景が解決しない」拡張分岐と同じ判定) には、反転ではなく
               こちらを使う — メール本来の配色のまま (白カード) 見せる。
               反転と違い画像・ロゴの色には一切手を加えない (元々ライトな
               ページにライトな画像がそのまま乗っているだけなので、色を
               打ち消す必要がない — `decideLogoChips`もこの経路では呼ば
               ない)。`html`自身に`color-scheme: light`を強制するのは、
               このサブツリー内で著者が明示指定していない部分が誤って
               `CanvasText`等のダーク側システム色に解決されるのを防ぐ
               ため。`html`/`body`の背景を白へ強制するのは
               `forceLightBackgroundStyle`と同じ保険 — メール自身が
               `body`へ明示的な背景を指定していればそれがそのまま活きる
               (非`!important`同士でこのルールより前に来るので無害) が、
               指定が要素の隙間などで途切れている場合や、介入判定が
               「背景なし+暗文字」経由だった場合 (背景色はそもそも透明の
               まま) にも確実にライト表示になるようにする。 */
            html.otegami-keep-light-active,
            html.otegami-keep-light-active body {
              color-scheme: light !important;
              background-color: #ffffff !important;
            }
          }
        </style>
        """ : ""
        // Task #51: `#otegami-fit-outer`にこの属性を付けておくと、
        // `fitToWidthScript`側は Swift の状態を別途受け渡されなくても
        // 「このドキュメントは介入 (反転 or ライト維持) を検討してよいか」
        // をDOMから直接読める — `didFinish`直後・1.5秒後の遅延呼び出し・
        // 1i翻訳後の再適用のどの呼び出し経路でも同じ1本のスクリプトが
        // 自己完結して動く。
        //
        // Task #80: `data-otegami-prefer-invert`は「介入が要ると分かった
        // ときに反転 (旧既定・オプトイン) を選ぶか、ライト維持 (新既定)
        // を選ぶか」をJSに伝える — `autoAdjustColorsInDarkMode`が true の
        // ときだけ付与する。この属性が無い (== false) 場合の既定は
        // ライト維持。
        let fitOuterAttributes = shouldConsiderDarkModeHandling
            ? " data-otegami-invert-check=\"1\"" + (autoAdjustColorsInDarkMode ? " data-otegami-prefer-invert=\"1\"" : "")
            : ""
        // Task #56 (実機フィードバック: 要約/翻訳フローティングボタンが
        // HTML本文に被る): プレーンテキスト側の `.contentMargins(.bottom:)`
        // と同じ効果を、この文書自身の末尾に高さ分の空 `<div>` を1つ足す
        // ことで実現する — `#otegami-fit-outer`の*兄弟*として`body`直下に
        // 置く (中に入れない) のがポイント: fit-to-width
        // (`HTMLWebViewCoordinator.fitToWidthScript`) は`#otegami-fit-inner`
        // の`scrollWidth`/`scrollHeight`だけを測って`outer`のtransform/
        // サイズを決めるので、この spacer をその外に置けば scale 計算には
        // 一切影響しない (スケールされたメール本文の下に、常にスケール
        // されていない一定の高さの余白が残る)。`bottomContentInset <= 0`
        // (フローティングボタンが1つも出ない設定の場合など) なら何も足さず
        // 従来どおり — `MessageView.floatingButtonsReservedBottomInset`が
        // 既に同じ「出ないときは0」ガードを持っている。
        let bottomInsetSpacer = bottomContentInset > 0
            ? "<div id=\"otegami-bottom-inset-spacer\" style=\"height: \(Int(bottomContentInset.rounded(.up)))px; flex-shrink: 0;\"></div>"
            : ""
        // Task #104 (実機フィードバック: Readdle Documents のニュースレター等、
        // `<style>` ブロックの CSS クラスで文字色を指定するメールがダーク
        // ネイティブのまま読めなかった — Task #98 の `explicitDarkTextIsMajority`
        // はインライン `style` の `color` しか見ておらず、クラス経由の
        // 明示指定を見落としていた): 3つの `<style>` タグ (この基本リセット、
        // 下の `darkModeInvertStyle`、`forceLightBackgroundStyle`) すべてに
        // `data-otegami-base-style="1"` を付け、`fitToWidthScript`側の
        // `collectExplicitColorSelectors` がこの属性を持つ `<style>` を
        // 「アプリ自身の注入スタイル」として除外できるようにする —
        // `originalHeadStyles` (メール自身が持っていた `<style>` ブロック、
        // すぐ下で差し込む) だけがマークされずに残るので、そちらだけが
        // 「メール著者が明示指定した色」の走査対象になる。この属性が無いと
        // このファイル自身の `a { color: LinkText; }` のようなルールまで
        // 「著者の明示指定」に誤カウントしてしまう。
        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=yes">
        <meta charset="utf-8">
        <style data-otegami-base-style="1">
          :root { color-scheme: light dark; }
          html, body {
            margin: 0;
            padding: 0;
            background: transparent;
            color: CanvasText;
            font: -apple-system-body;
            -webkit-text-size-adjust: 100%;
            word-wrap: break-word;
            overflow-wrap: break-word;
            overflow-x: hidden;
          }
          body { padding: 8px 12px; }
          /* Task #56: `img` はこの `*` の対象から除外し、専用ルール群
             (下、`img { box-sizing: border-box; ... }` 以降) で個別に扱う
             — 理由はそちらのコメント参照 (この `!important` が著者の
             インライン `max-width` を問答無用で踏み潰していた実機バグの
             修正)。
             Task #205 (実機報告: 実メール — Redis のメンテナンス通知 — で
             フッターの濃い帯が右端で途切れ白い余白が残る): `img`と全く
             同じ理由でこの `*:not(img)` 自体にも同じ「著者の明示指定を
             踏み潰す」バグがあった。著者が `<table style="width:100%;
             max-width:700px;">` のように自前で上限を指定しているのに、
             この行の無条件 `max-width: 100% !important` がそれを (ビュー
             ポート幅がその上限より広いとき) 100%＝ビューポート幅まで
             上書きしてしまい、本来700px止まりであるべきテーブルが際限なく
             広がっていた — `img`向けの`img:not([style*="max-width" i])`/
             `img[style*="max-width" i]`ペア (下記) と同じ「著者が独自の
             `max-width`を持たない要素だけに`!important`の100%上限をかけ、
             持つ要素には非`!important`のフォールバックだけを与える」形に
             揃えて修正 — ローカルの WKWebView 計測スクリプトで、900px
             ビューポートに対しこの700px上限テーブルの実際のレンダリング
             幅が900pxになってしまうこと (修正前) / 700pxに収まりセンター
             寄せされること (修正後) を確認済み。 */
          *:not(img):not([style*="max-width" i]) { max-width: 100% !important; box-sizing: border-box; }
          *:not(img)[style*="max-width" i] { max-width: 100%; box-sizing: border-box; }
          /* Task #205: `table`は下の`table { width: auto !important; }`
             以降の専用ルール群で幅を扱うため、ここでは高さのリセットだけ
             残す (以前はここで`max-width: 100% !important`も掛けていたが、
             それは上の`*:not(img)`と重複するうえ、そちらが著者の`max-width`
             を尊重するようになったのを`table`だけ迂回して踏み潰してしまう
             ため、`table`をこの行の対象から外した)。 */
          video, iframe { max-width: 100% !important; height: auto !important; }
          table { height: auto !important; }
          /* Task #56「画像の巨大化禁止」(実機フィードバック: TestFlight
             通知メールのアプリアイコン ~120px 画像が画面幅いっぱいに
             引き伸ばされていた): 原因は責任分解の失敗 — メール側は
             「画面に合わせて縮むが上限は120px」という業界標準のレスポン
             シブ画像手法 (`width` 属性 + `style="width:100%;
             max-width:120px;"` の併用、Litmus/Email on Acid 等が推奨する
             定石) を使っていたのに、この `<style>` の `img` 向けリセットが
             `max-width: 100% !important` を無条件にかけていたため、著者の
             `max-width: 120px` (`!important` 無し) を、`!important` 同士
             なら詳細度を問わず勝つという CSS のカスケード規則により問答
             無用で上書きしていた — 結果「上限なし」＝コンテナ幅いっぱい
             まで拡大 (実機ログ・再現手順は `docs/design-system.md` の
             Task #56 節参照。ローカルの WKWebView 計測スクリプトで複数の
             実装候補を比較のうえ選定した)。
             著者が独自の `max-width` をインライン `style` に持たない画像
             だけへ `!important` の100%上限をかけ
             (`img:not([style*="max-width" i])`)、独自の `max-width` を
             持つ画像には非`!important`のフォールバック上限だけを与える
             (`img[style*="max-width" i]`) — これなら CSS の詳細度
             (インライン `style` が最優先) により著者側のより小さい値が
             自然に勝つ。著者が `max-width` を極端に大きく指定していた
             場合でも、ページ全体の fit-to-width
             (`HTMLWebViewCoordinator.fitToWidthScript`) がページ全体を
             縮小する安全網としてなお機能する (下の固定幅テーブル対策と
             同じ考え方)。 */
          img { box-sizing: border-box; height: auto !important; }
          img:not([style*="max-width" i]) { max-width: 100% !important; }
          img[style*="max-width" i] { max-width: 100%; }
          /* 拡大禁止の残り半分: `width` 属性もインライン `style` の
             `width` も持たない画像は常に自然サイズ (`width: auto`) で
             描画する — これが無いと、著者の `<style>` ブロック側で
             `img { width: 100% !important; }` のような汎用リセットが
             仕込まれていた場合 (これもテンプレートで頻出) にそれがその
             まま採用され、結局自然サイズより拡大されてしまう。`width`
             属性/インライン `style` で明示指定がある画像はこの対象から
             除外し、その指定をそのまま尊重する — 拡大方向にだけ効く
             他のルールと違い、こちらは `!important` を使っても
             フィットスケール以外に副作用がない (対象を明示指定なしの
             画像だけに絞っているため)。 */
          img:not([width]):not([style*="width" i]) { width: auto !important; }
          /* Task #205: `fitToWidthScript`の`handleImageLoadFailure`が読み込み
             失敗時に付与するクラス — WebKit既定の壊れたアイコン単体より
             「元々ここに画像があった」ことが伝わるよう、薄い背景と破線枠を
             敷く。埋め込んだプレースホルダ SVG 自体は `object-fit: contain`
             で著者指定のサイズ (幅固定の広告バナー等) の中に収める — 拡大
             せず中央に小さく収まる。開封トラッキング用の1x1透明画像 (実物の
             Redis メールにも実在 — `width="1" height="1"`) にまでこの装飾を
             敷くと、本来完全に不可視であるべきものが小さな破線ボックスとして
             急に「見える化」してしまう副作用があるため、`width`/`height`
             属性が数px以下と明示されている画像は対象から除外する (2px以下
             という閾値は実際のトラッキングピクセルが1x1・稀に2x2で来る
             実例に基づく実用的な線引き)。 */
          img.otegami-image-load-failed { object-fit: contain; }
          img.otegami-image-load-failed:not([width="0"]):not([width="1"]):not([width="2"]):not([height="0"]):not([height="1"]):not([height="2"]) {
            background-color: color-mix(in srgb, CanvasText 8%, transparent);
            border: 1px dashed color-mix(in srgb, CanvasText 25%, transparent);
            box-sizing: border-box;
            padding: 4px;
          }
          /* 幅固定のマーケティングHTML (width="600"のテーブル等) 対策:
             max-width: 100% だけだと table-layout: auto のセル内容が要求
             する幅次第でテーブル自体がなおコンテナ幅を超えうる。width: auto
             でテーブル自身の希望幅を「内容に合わせる」側に倒し、頻出する
             spacerセルの min-width 属性も無効化する — table-layout: fixed
             (テーブル全体を強制的に均等割りする、もっと強い手段) は列比率が
             崩れて見た目が壊れるケースがあるため見送った (「やり過ぎない
             範囲で」という指示どおりの選択)。 */
          table { width: auto !important; }
          /* Task #205: この行だけだと、著者が明示的に `width="100%"`/
             `style="width:100%"` を指定して「利用可能な幅いっぱいに
             広がってほしい」意図で作ったテーブル (レスポンシブなメール
             テンプレートの定石 — 直上の `max-width:700px` のセルより
             さらに内側にネストする `width="100%"` の各モジュールテーブル
             など) まで一律 `auto` (＝内容に応じた縮小フィット幅) にして
             しまい、`table-layout: fixed` と組み合わさるとブラウザが
             セル内容から一見無関係などっちつかずの幅を導出することがある
             (実機/ローカル計測で確認: 700px超のコンテナ内で653px相当に
             縮み、右側に白い余白が残った)。`width="100%"`/`style="width:
             100%"` を持つテーブルだけ明示的に100%へ戻す — 直上の固定幅
             テーブル対策 (幅を持たない/`px`指定のテーブルを`auto`に倒す)
             とは互いに排他的な条件なので競合しない。 */
          table[width="100%"], table[style*="width:100%" i], table[style*="width: 100%" i] { width: 100% !important; }
          td, th { min-width: 0 !important; }
          a { color: LinkText; }
          pre, code { white-space: pre-wrap; }
          /* fit-to-width の足場 (`HTMLWebViewCoordinator.fitToWidthScript`
             が JS から実際に幅・transform を設定する) — #otegami-fit-outer
             に `overflow: hidden` が要るのは、`transform: scale()` が
             `#otegami-fit-inner`の*レイアウト上の*ボックスサイズ (＝縮小前の
             元の大きな幅・高さ) を変えないため。JS 側が `outer` の
             width/height を縮小後の見た目の寸法に明示的に合わせても、
             `overflow: hidden` が無いと `inner` の (縮小前のままの)
             レイアウト上のボックスが `outer` をはみ出して結局スクロール
             領域が縮小前の大きいままになってしまう。 */
          #otegami-fit-outer { overflow: hidden; }
        </style>
        \(originalHeadStyles)
        \(darkModeInvertStyle)
        \(forceLightBackgroundStyle)
        </head>
        <body><div id="otegami-fit-outer"\(fitOuterAttributes)><div id="otegami-fit-inner">\(innerBody)</div></div>\(bottomInsetSpacer)</body>
        </html>
        """
    }

    /// Task #45: whether `html` (the *original*, unwrapped message HTML —
    /// checked before `extractBodyContent`/`extractHeadStyles` run, so this
    /// sees the original `<head>` regardless of whether it survives
    /// extraction) already declares its own dark-mode support, in which case
    /// `wrap(bodyHTML:autoAdjustColorsInDarkMode:)` leaves it untouched
    /// rather than risking a double-inversion. Two real-world signals,
    /// either one sufficient:
    /// - `<meta name="color-scheme" content="...">` (the HTML-level opt-in
    ///   most mail-authoring tools emit alongside a dark-mode stylesheet).
    /// - A `prefers-color-scheme` media query anywhere in the message's own
    ///   markup (almost always inside a `<style>` block — the actual dark-
    ///   mode color overrides live behind it).
    /// Plain case-insensitive substring search, not a real CSS/HTML parser —
    /// consistent with this file's existing pragmatic approach elsewhere
    /// (`stripHTMLComments(from:)`'s doc comment makes the same tradeoff).
    /// A false positive (text that happens to contain one of these strings
    /// without it actually governing color) just means this app trusts the
    /// message's own dark-mode handling instead of applying its own — the
    /// safe direction to be wrong in, same as leaving a message's colors
    /// alone entirely would be.
    private static func mailDeclaresOwnDarkModeSupport(html: String) -> Bool {
        let lowercased = html.lowercased()
        return lowercased.contains("prefers-color-scheme") || lowercased.contains("name=\"color-scheme\"") || lowercased.contains("name='color-scheme'")
    }

    /// MailCore2's `MCOMessageParser.htmlBodyRendering()` hands back
    /// whatever the message's own `text/html` MIME part actually contained
    /// — for a great many real senders (marketing/notification templates
    /// especially) that's a **complete** `<html><head>...</head><body>...
    /// </body></html>` document, not a bare fragment, and that original
    /// `<head>` commonly carries its own `<meta name="viewport">` and/or a
    /// `<style>` block written for a desktop-width preview pane. The
    /// pre-fix version of this function did `<body>\(bodyHTML)</body>` —
    /// nesting that entire second document *inside* this file's own
    /// `<body>` tag. Per the HTML5 parsing algorithm a `<head>` start tag
    /// encountered while already "in body" insertion mode is dropped, and a
    /// bare `<meta>`/`<style>` that follows gets inserted as ordinary body
    /// content instead of governing the page the way it would from a real
    /// `<head>` — in practice, real WebKit builds have been observed
    /// treating the *second*, malformed `<meta viewport>` as authoritative
    /// anyway once it's present anywhere in the document, silently
    /// overriding this file's own correctly-placed one and putting the
    /// whole page back into desktop-width layout. Extracting just the
    /// original document's own `<body>...</body>` content (falling back to
    /// the input unchanged when there's no `<body>` tag to find — the
    /// already-a-fragment case, still the common one for plainer mail)
    /// guarantees this file's `<head>` is the *only* one WebKit ever
    /// parses, so its viewport meta and CSS reset can't be shadowed by
    /// whatever the original message happened to ship.
    private static func extractBodyContent(from html: String) -> String {
        // HTML 表示の高さ問題の修正: comment-stripped first (see
        // `stripHTMLComments(from:)`'s doc comment) — a real marketing
        // template's `<head>` commonly contains an MSO/Outlook conditional
        // comment holding a whole fallback skeleton, which can itself
        // contain the literal text `<body`/`</body>`. Scanning the raw
        // (comment-including) string let that spurious occurrence win,
        // truncating almost the entire real message body.
        let sanitized = stripHTMLComments(from: html)
        guard let bodyTagRange = sanitized.range(of: "<body", options: [.caseInsensitive]),
              let bodyTagCloseIndex = sanitized[bodyTagRange.lowerBound...].firstIndex(of: ">")
        else {
            return html
        }
        let contentStart = sanitized.index(after: bodyTagCloseIndex)
        // `.backwards`: the *real* closing tag is always the last one in a
        // well-formed document (it closes the one `<body>` element whose
        // opening tag was just located above) — searching backwards is a
        // second, independent safety net against any stray `</body>`-like
        // text elsewhere in `<head>` that comment-stripping alone didn't
        // happen to catch (e.g. inside a `<script>`/`<style>` string
        // literal rather than an HTML comment).
        let contentEnd = sanitized.range(of: "</body>", options: [.caseInsensitive, .backwards])?.lowerBound ?? sanitized.endIndex
        guard contentStart <= contentEnd else { return html }
        return String(sanitized[contentStart..<contentEnd])
    }

    /// HTML 表示の高さ問題の修正: B (`extractBodyContent(from:)`) が
    /// 元ドキュメントの `<body>...</body>` だけを取り出す一方で、その
    /// `<head>` に書かれていた `<style>` ブロック (クラス経由でしか本文の
    /// 見た目を制御していないマーケティングテンプレートは珍しくない) を
    /// 完全に捨ててしまっていた副作用の修正。抽出したスタイルは `wrap
    /// (bodyHTML:)` でこのファイル自身の `<style>` (viewport/幅の
    /// `!important` リセット) の**後**に差し込む — CSS の cascade では
    /// `!important` は宣言順を問わず勝つので、元テンプレートの `width:
    /// 600px` のような非 `!important` 宣言に上書きされる心配はなく、色や
    /// 余白のような非競合スタイルだけが素直に復元される。
    /// `stripHTMLComments(from:)` を先に通すのは `extractBodyContent(from:)`
    /// と同じ理由 (MSO 条件付きコメント内の `<style>` は Outlook 専用の
    /// フォールバックであって、WebKit でそのまま適用すべきものではない) —
    /// コメントごと除去することで自然に除外される。
    private static func extractHeadStyles(from html: String) -> String {
        let sanitized = stripHTMLComments(from: html)
        guard let headOpenRange = sanitized.range(of: "<head", options: [.caseInsensitive]),
              let headCloseRange = sanitized.range(of: "</head>", options: [.caseInsensitive]),
              headOpenRange.lowerBound < headCloseRange.lowerBound
        else {
            return ""
        }
        let headSection = sanitized[headOpenRange.lowerBound..<headCloseRange.upperBound]
        var result = ""
        var searchStart = headSection.startIndex
        while let openRange = headSection.range(of: "<style", options: [.caseInsensitive], range: searchStart..<headSection.endIndex),
              let openTagCloseIndex = headSection[openRange.lowerBound...].firstIndex(of: ">") {
            let styleContentStart = headSection.index(after: openTagCloseIndex)
            guard let closeRange = headSection.range(of: "</style>", options: [.caseInsensitive], range: styleContentStart..<headSection.endIndex) else {
                break
            }
            result += String(headSection[openRange.lowerBound..<closeRange.upperBound])
            result += "\n"
            searchStart = closeRange.upperBound
        }
        return result
    }

    /// Removes every `<!-- ... -->` HTML comment from `html` — comments
    /// never render (browsers treat them as inert), so stripping them
    /// before `extractBodyContent(from:)`/`extractHeadStyles(from:)` scan
    /// for tags never changes anything visible; it only stops literal
    /// tag-like text *inside* a comment (an MSO/Outlook conditional
    /// fallback skeleton is the common real-world case — see
    /// `extractBodyContent(from:)`'s doc comment) from being mistaken for
    /// a real tag. `.dotMatchesLineSeparators` so a multi-line comment
    /// (the norm for these conditional blocks) is matched as one unit
    /// rather than stopping at the first newline. Falls back to the input
    /// unchanged if the regex itself somehow fails to compile (a fixed,
    /// valid pattern — should never happen, but this is display code, not
    /// somewhere worth crashing over).
    private static func stripHTMLComments(from html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<!--.*?-->", options: [.dotMatchesLineSeparators]) else {
            return html
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }
}
