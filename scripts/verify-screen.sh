#!/usr/bin/env bash
# Task #60 (シミュレータ検証基盤の整備): tap-free スクリーンショット取得の
# 標準手段。
#
# docs/verify.md の「シミュレータ検証の既知の不調」参照 — このシミュレータ/
# ツールチェーンでは (1) IMAP接続不能 (MailCoreErrorDomain error 1)、
# (2) XCUITestのタップ不達 (特に一覧行→本文遷移)、(3) 連絡先権限ダイアログの
# 非決定的な出現、(4) Foundation Modelsのサンドボックスエラー -1、の4つが
# 繰り返し検証を妨げてきた。このスクリプトは (2)(3) を迂回する「タップ不要」
# 経路だけを使い、XCUITestランナー (`xcodebuild test`) そのものを一切起動
# しない:
#
#   1. `xcodebuild build` (`build-for-testing`ではない — テストバンドルは
#      不要) でアプリだけをビルド。
#   2. `xcrun simctl install` でシミュレータへインストール。
#   3. `xcrun simctl launch` で起動。フィクスチャ選択は `AppEnvironment
#      .init()`のDB直接注入フラグ (`OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE`
#      等) を**環境変数**として、画面遷移は`-uiTestsAutoAdvanceToContent`/
#      `-uitestsOpenSettingsDirectly`を**起動引数**として与える。`simctl
#      launch`自体には環境変数を渡すフラグが無く、呼び出し元シェルの
#      `SIMCTL_CHILD_<NAME>`プレフィクス付き環境変数だけが子プロセスへ
#      引き継がれる (`xcrun simctl launch --help`の最終行に明記) — この
#      スクリプトが `SIMCTL_CHILD_OTEGAMI_UITEST_...` という形で export
#      しているのはそのため。
#   4. 数秒待ってから `xcrun simctl io screenshot`。
#
# `OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES=1` (Task #60で追加) を既定で常に
# 付与する — 連絡先/Google/Gravatar/企業ロゴのアバター解決を全部スキップし、
# 上記(3)の連絡先権限ダイアログが原理的に発生し得ないようにする。
#
# 同じ理由で `OTEGAMI_UITEST_DISABLE_NOTIFICATION_PERMISSION_REQUEST=1`
# (Task #60で追加、`BadgeCenter.requestAuthorizationIfNeeded()`参照) も既定
# で付与する — アカウントが1件でもあれば起動直後にOSの「通知を送信する
# ことを許可しますか」ダイアログが出て最初のスクリーンショットを埋めて
# しまう。`simctl privacy grant notifications`はこの開発機のランタイムでは
# `Operation not permitted`で使えなかったため、アプリ側にエスケープハッチを
# 追加した。
#
# Usage:
#   scripts/verify-screen.sh <scenario> [output-filename.png]
#
# Scenarios:
#   html-0 / html-security-notice      31番相当のフィクスチャ本文画面
#                                       (白背景+濃色文字、ダークモードで反転対象)
#   html-1 / html-no-colors            32番相当 (色指定なし、反転させない)
#   html-2 / html-self-dark-aware      自前ダーク対応宣言あり (反転させない)
#   html-3 / html-beta-testing-notice  33番相当 (背景なし+#444文字+cid画像、
#                                       高さ切れ修正のTask #58/#59対象)
#   html-4 / html-makerworld-like       34番相当 (body自身が白背景を明示+
#                                       透過PNGロゴ+薄グレーのカード+緑
#                                       ボタン — 実機報告のMakerWorld比較:
#                                       ダーク反転時の右端白帯/セクション間
#                                       色ムラ/透過ロゴが暗背景に沈む、の
#                                       3点の確認用)
#   html-5 / html-calendar-invite-realistic  Task #98 (実機報告: Google
#                                       カレンダー招待メールがダークモード
#                                       でほぼ読めない): 背景なし+ラベルは
#                                       白背景前提の中間グレー(#5f6368等)
#                                       明示指定という`calendar-invite`
#                                       シナリオと同じ土台に、実機メール
#                                       同様のタイトル見出し/前置き文 (色
#                                       未指定) を本文冒頭に足し、6サンプル
#                                       平均だけの旧判定だと見落とす退行
#                                       ケースを再現する — 白カードで読める
#                                       ことの確認用 (`explicitDarkTextIsMajority`)。
#   html-6 / html-style-block-gray-text  Task #104 (実機報告: Readdle
#                                       Documents のニュースレター等が
#                                       Task #98 対策後もダークネイティブ
#                                       のまま読めない): html-5と同じ
#                                       「背景なし+色未指定の前置き2行+
#                                       中間グレー本文」構造だが、文字色を
#                                       インライン`style`ではなく`<style>`
#                                       ブロックのCSSクラスで指定する点が
#                                       違う — スタイルシート経由の明示色を
#                                       見ていなかった旧`explicitDarkText
#                                       IsMajority`(Task #98版) だと検出漏れ
#                                       する退行ケース。白カードで読める
#                                       ことの確認用。
#   html-7 / html-white-card-hero      Task #112 (実機報告続報 — ユーザー
#                                       提供の実メール readdle.eml で再現・
#                                       修正): html-5/html-6 と違い body
#                                       自身が明示的な白背景を持つ「背景
#                                       あり」構造 — decideDarkInversion の
#                                       `if (background)`枝 (先頭6テキスト
#                                       ノード平均だけの representativeText
#                                       Luminance) にしか到達せず、Task #98/
#                                       #104で追加した explicitDarkTextIs
#                                       Majority (背景なしの`else`枝からしか
#                                       呼ばれていなかった) が一度も効いて
#                                       いなかった実際の根本原因を再現する。
#                                       文書冒頭の白文字ヒーロー見出しに
#                                       6サンプル平均が引っ張られた後でも、
#                                       本文カードの暗〜中間グレー文字
#                                       (#111111/rgb(51,51,51)混在) が文字数
#                                       で過半を占めることを検出できるかの
#                                       確認用。不可視の結合文字を含む隠し
#                                       プリヘッダも実物同様に含み、それが
#                                       過半判定の分母を水増ししないこと
#                                       (isVisuallyHiddenText) も併せて確認
#                                       する。白カードで読めることの確認用。
#   html-9 / html-gmail-quote-history  Task #133 (実機報告「引用折りたたみが
#                                       HTMLメールで効かない」— #123の折り
#                                       たたみはプレーンテキスト表示限定
#                                       だったが、実際のGmailはほぼ全部HTML
#                                       付きでHTML表示が優先されるため実機で
#                                       機能しなかった。ユーザー提供の実メール
#                                       yoyaku.emlで再現・修正)。番号が8を
#                                       飛ばして9なのは、`uitestFakeHTMLMessages`
#                                       のindex 8はTask #128がすでに使って
#                                       いる(SSOサインイン通知、`detectedLanguage`
#                                       誤検出の再現用 — このスクリプトの
#                                       シナリオとしては未公開、
#                                       `OtegamiHTMLTranslationUITests`が
#                                       直接indexを指定して使う)ため。実物と同じ
#                                       Gmail HTML引用構造 (gmail_quote +
#                                       gmail_attr + 入れ子blockquote、2段)
#                                       だが内容は架空の予約確認シナリオに
#                                       差し替えたフィクスチャ
#                                       (`AppEnvironment
#                                       .uitestFakeHTMLMessageBodyGmailQuoteHistory`)
#                                       — WKWebViewには新規部分のHTMLだけが
#                                       渡り、引用履歴2段が下のネイティブ
#                                       トグル+カード(#123と同じ
#                                       `QuoteHistorySectionView`)に折り
#                                       たたまれることの確認用。
#   html-10 / html-responsive-table-footer  Task #205 (実機報告: ユーザー
#                                       提供の実メールで「画像が出ない」
#                                       「幅・高さが崩れる」「ソースを表示
#                                       が空白」の3件): `http:` 外部画像2枚
#                                       (ATS 例外なしでは既定ブロックされ
#                                       壊れたアイコンになっていた) +
#                                       `width="100%"`のネストしたレスポン
#                                       シブテーブル (幅計算が壊れると内側の
#                                       濃色フッターだけ中途半端な幅に縮み
#                                       右に白余白が残っていた) という実物の
#                                       骨格を、内容は架空のメンテナンス
#                                       通知に差し替えて再現するフィクス
#                                       チャ (`AppEnvironment
#                                       .uitestFakeHTMLMessageBodyResponsive
#                                       TableFooterNotice`)。画像/幅の見た目
#                                       確認用。
#   calendar-invite                    Task #66: カレンダー招待メールの
#                                       招待カード (36番フィクスチャ相当 —
#                                       タイトル/日時/場所/主催者 +
#                                       「承諾」「辞退」「未定」ボタン)
#   quote-history                      Task #123 (Spark 参考「引用履歴を
#                                       メッセージ単位に分解して時系列
#                                       表示」): 3段ネストの引用チェーンを
#                                       持つプレーンテキストメール
#                                       (`AppEnvironment
#                                       .uitestFakeQuotedPlainMessageBody`)
#                                       を直接遷移で開く —「履歴を表示/
#                                       非表示」トグル(既定表示)+ 角丸カード
#                                       内にメッセージ単位で分解された各段
#                                       (差出人太字/日時/本文) の見た目確認用。
#   message-source                     Task #103: 「ソースを表示」— 生
#                                       RFC822ソースのモノスペース表示
#                                       (`MessageSourceView`)。html-0
#                                       フィクスチャのメッセージを開き、
#                                       キャッシュファイルに直接書き込んだ
#                                       (プリウォーム済みの) 生ソースを
#                                       タップ無しで表示する。
#   thread-list                        Task #136 (実機フィードバック「スレッド
#                                       表示 ON の本文画面をアコーディオンに
#                                       戻してほしい」): 3通の合成スレッド
#                                       (`OTEGAMI_UITEST_INSERT_FAKE_MULTI_
#                                       MESSAGE_THREAD`) を一覧に挿入するだけ
#                                       で直接遷移はしない — 一覧行の日時の
#                                       下の「スレッドアイコン + 件数」バッジ
#                                       の見た目確認用。
#   thread-accordion                   Task #136: ↑と同じ3通スレッドを直接
#                                       開く — `ThreadDetailView`のアコー
#                                       ディオン (最新メッセージが展開済み、
#                                       他2通は折りたたみ行) の見た目確認用。
#                                       プレーンテキスト1通+HTML2通の混成
#                                       (展開/折りたたみを跨ぐ複数WKWebView
#                                       インスタンスの高さ再計測確認も兼ねる)。
#   thread-accordion-scroll            Task #146 (実機フィードバック「下の
#                                       方の折りたたみ行を展開したとき気づき
#                                       にくい」): ↑と同じスレッドを開いた後、
#                                       一番下 (最古) の行をタップ無しで展開
#                                       — `accordionScrollTarget`の自動
#                                       スクロールでその行のヘッダが画面上部
#                                       に来ていることの確認用。
#   list                                統合受信トレイの一覧画面 (fakeメッセージ5件)
#   list-fab-expanded                   Task #131 (一覧FABのspeed-dial化):
#                                       ↑と同じ一覧画面を、
#                                       `-uitestsExpandFabDirectly`
#                                       (`MailScreenView.isFabExpanded`の
#                                       初期値として読む「タップ不要の直接
#                                       遷移」引数) で右下speed-dial FABが
#                                       展開済みの状態のまま直接screenshot
#                                       する — 「新規作成」「検索」2ボタンが
#                                       「…」の上に縦に積まれ、「…」自体が
#                                       「×」に変わっていることの確認用。
#   list-2accounts                      Task #77: fake HTML アカウント +
#                                       fake Gmail アカウントの2つを注入
#                                       (`OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE`
#                                       +`OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT`
#                                       の組み合わせ、どちらもDBへの直接注入
#                                       でネットワーク不要) — ヘッダに「アカウ
#                                       ントでグループ化」トグルが現れること
#                                       (単一アカウントでは出ない) の確認用。
#                                       トグル自体はOFFのまま。
#   list-grouped / account-digest       Task #77→#92→#99: ↑と同じ2アカウント
#                                       構成で、`-uitestsOpenAccountDigestDirectly`
#                                       (タップ不要の直接遷移引数)により
#                                       `isGroupByAccount`をONにし、一覧領域
#                                       の中身をアカウントダイジェスト表示
#                                       (`AccountDigestView`が`MailScreenView
#                                       .content`に埋め込まれる形、ヘッダは
#                                       通常どおり — アカウント色罫線+表示名+
#                                       未読/件数バッジ+直近プレビュー2行、が
#                                       2アカウント分)にして直接screenshot
#                                       する。Task #92 時点ではこれがプッシュ
#                                       遷移(戻るボタン付き)だったが、Task #99
#                                       でトグル表示に変更した。Task #92 以前
#                                       は`-listDisplay.groupByAccount 1`で
#                                       一覧自体をインラインのSectionに分割
#                                       していた(廃止済み) — シナリオ名
#                                       `list-grouped`は後方互換のエイリアス
#                                       として残し、新しい`account-digest`と
#                                       同じ動作にした。
#   list-pinned-only                    Task #142 (一覧ヘッダの「フラグ付きの
#                                       み表示」トグル): ピン留め済み1件+
#                                       未ピン1件を注入
#                                       (`OTEGAMI_UITEST_INSERT_FAKE_PINNED_MESSAGE`)
#                                       した上で、トグルをタップせず
#                                       `OTEGAMI_UITEST_FORCE_PINNED_ONLY=1`
#                                       (`AppEnvironment.init()`が実際の`Bool`
#                                       を`UserDefaults.standard`へ書く —
#                                       素の`-listDisplay.pinnedOnly 1`launch
#                                       argumentだと`persistedBool`の厳密な
#                                       `as? Bool`キャストがStringを弾いて
#                                       効かないため、専用フックにした。同じ
#                                       doc comment参照)で直接ONにする —
#                                       ヘッダのトグルアイコンが塗り
#                                       (`pin.fill`) になっていること、一覧に
#                                       ピン留め済みの1件だけが残ること
#                                       (未ピンの1件は消えていること) の確認用。
#   list-all-mail                        Task #141 実機フィードバック:
#                                       `-uitestsSelectAllMailDirectly`で
#                                       「すべてのメール」をタップ無しで
#                                       直接選択 — ヘッダタイトルが「すべて
#                                       のすべてのメール」に二重化していない
#                                       ことの確認用。
#   archived-message-detail             Task #151 (「アーカイブ済みの
#                                       可視化」): `list-all-mail`と同じ
#                                       fake Gmail アカウントの「本当に
#                                       アーカイブ済み」メッセージを直接
#                                       開く — `MessageHeaderCompactView`
#                                       の`ArchivedBadge`表示の確認用。
#   duplicate-thread-detail              Gmail 二重ラベルによるスレッド内
#                                       メッセージ重複バグ (実機報告):
#                                       `archived-message-detail`と同じ
#                                       fake Gmail アカウントの「INBOX/All
#                                       Mail の両方に同じ`gmailMessageId`で
#                                       重複したメッセージ」スレッドを直接
#                                       開く — アコーディオンに1通だけ
#                                       表示され、2通に重複していないことの
#                                       確認用。
#   settings                            設定画面 (SettingsSheetView)
#   menu                                 ハンバーガーメニュー (FolderListSheet
#                                       — 左下floatingSettingsButtonの
#                                       アクセント塗り確認用)
#   menu-expanded                        Task #110 (フォルダセクションの
#                                       挙動変更: 見出し行タップ=統合ビュー
#                                       選択、シェブロンだけが折りたたみ
#                                       開閉): 2アカウント (fake HTML + fake
#                                       Gmail) を注入し、`-uitestsExpandFolder
#                                       MenuSectionsDirectly`で全セクション
#                                       展開状態のまま直接screenshotする —
#                                       「すべての受信トレイ」等の専用行が
#                                       セクション内から消え、見出し行+右端
#                                       シェブロンの構成になっていることの
#                                       確認用。
#   general-settings                     Task #189: 設定→一般 (iCloud 同期
#                                       トグルが「アカウントの設定」から
#                                       ここへ移設されたことの確認用)
#   account-settings                    Task #72: 設定→アカウントの設定
#                                       (fake Gmail アカウント1件を挿入、
#                                       一覧行の色ドットを確認)
#   account-edit                        Task #72: ↑からさらに1画面 (先頭
#                                       アカウントの編集画面 — ラベル色の
#                                       グリッドピッカーを確認)
#   push-settings                       Task #171/#173: 設定→アカウントの
#                                       設定→「プッシュ通知」を直接開く —
#                                       登録シークレット・リレー URL とも
#                                       ビルド時埋め込み方式 (それぞれ
#                                       RelayRegistrationSecretConfig/
#                                       RelayURLConfig 参照) になり、この
#                                       画面がユーザー入力を一切求めない
#                                       (「有効にする」ボタンのみ) ことの
#                                       確認用 (iOS 専用画面)。押す前の
#                                       未有効化状態のみ — 有効化後の状態は
#                                       push-settings-watches 参照。
#   push-settings-watches               Task #173: push-settings と同じ
#                                       画面を、アカウント別 watch 状態
#                                       (`PushWatchStatusSection`) が
#                                       populated な状態で開く —
#                                       登録済み/停止(認証失敗)/未登録/
#                                       対象外(Gmail) の4状態を1画面に
#                                       並べたフィクスチャ (実リレー接続は
#                                       使わない、`AppEnvironment
#                                       .fetchPushWatchSummaries()`の
#                                       `OTEGAMI_UITEST_FIXED_PUSH_WATCH_
#                                       SUMMARIES`分岐参照)。
#   push-diagnostics                    Task #213: push-settings からさらに
#                                       「プッシュ通知の診断」を開く —
#                                       記録が空の状態の表示確認用
#                                       (シミュレータでは実際の
#                                       NotificationService 実行が無い)。
#   push-diagnostics-populated          同じ画面を、固定フィクスチャ
#                                       (成功1件・Yahooの[LIMIT]レート
#                                       制限失敗1件) が populated な状態で
#                                       開く。
#   toolbar-customize                   Task #100: 設定→メールビューア→
#                                       「ツールバーのカスタマイズ」
#                                       (`MessageToolbarSettingsView`) を
#                                       直接開く — 表示/非表示トグル・
#                                       ドラッグ並び替えリストと、常時
#                                       グレーアウト固定の「その他」行の
#                                       見た目確認用。
#   search                               Task #86 (検索画面再構成): 検索画面
#                                       を空状態 (履歴タブ) で直接開く —
#                                       トップバー (角丸フィールド+星+丸い
#                                       閉じるボタン) と「履歴」「保存済み」
#                                       タブの見た目確認用。
#   search-active                       Task #86: ↑と同じ検索画面を、
#                                       `OTEGAMI_UITEST_SEARCH_PRESET_QUERY`
#                                       でクエリ入力済み (結果表示中) の状態
#                                       にして開く — チップ列 (絞り込み/
#                                       アカウント) と結果一覧の見た目確認用。
#                                       `list`と同じfakeメッセージ (件名に
#                                       "UITest"を含む) がヒットする。
#   composer-richtext                    Task #129→#161 (作成画面リッチ
#                                       テキスト化): `-uitestsOpenComposerDirectly`
#                                       (`OtegamiApp`の`.task`ブロック参照)
#                                       で新規作成Composerをタップ無しで
#                                       直接開く — Task #161の下部バー
#                                       Spark準拠再構成後の「閉」状態
#                                       (書式バー非表示、下部に「T」+添付+
#                                       テンプレートの操作行だけが見える)。
#                                       `list`と同じfake HTMLアカウントを
#                                       挿入しておく (Fromピッカーに実際の
#                                       アカウントが出る状態にするため)。
#   composer-richtext-open               上記と同じ画面を「開」状態
#                                       (`-uitestsShowFormattingBarDirectly`
#                                       で`RichTextFormattingBar`をタップ
#                                       無しで開いた状態にする) で開く —
#                                       太字/イタリック/下線/打ち消し線/
#                                       フォントサイズ/文字色/ハイライト/
#                                       リスト/引用/インデント/リンク/書式
#                                       クリアの全コントロールの見た目確認用。
#   composer-signature                    Task #162 (実機フィードバック「署名が
#                                       本文に混ざって編集しづらい」):
#                                       `OTEGAMI_UITEST_INSERT_FAKE_SIGNATURE`
#                                       (`AppEnvironment`の doc comment参照)
#                                       で fake アカウントに署名を1件登録し
#                                       (かつそれを`defaultSignatureId`にする
#                                       ので新規作成で自動選択される)、新規作成
#                                       Composerを直接開く — 署名行のラベルが
#                                       「署名: <名前>」形式になっていること、
#                                       その下にグレーの読み取り専用プレビュー
#                                       (署名本文) が出ること、本文欄自体には
#                                       何も挿入されていないことの見た目確認用。
#   composer-recipient-suggestion        Task #200 (Composer 宛先サジェスト):
#                                       `OTEGAMI_UITEST_INSERT_FAKE_MULTI_
#                                       MESSAGE_THREAD`で田中花子/佐藤次郎
#                                       の履歴を投入した新規作成Composerを
#                                       開く。タップ不要経路では宛先欄への
#                                       入力自体はできないため、これは
#                                       「候補ドロップダウンが出た状態」
#                                       ではなく「空の宛先欄がレイアウト
#                                       崩れなく描画されること」の確認用
#                                       — 候補表示自体の確認は
#                                       `docs/design-system.md`のTask #200節
#                                       (macOSで実クリック確認済み) 参照。
#
# 上10個の`html-*`は `AppEnvironment.uitestFakeHTMLMessages`の0〜7番目・
# 9番目・10番目 (`OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX`の値と対応、
# 8番目だけ抜けているのは`html-9`の項目のdoc comment参照) — 0〜4番目の
# 実体は`dev/mailstack/seed/fixtures/31/32/33/34-*.eml`と同内容のSwift
# 文字列リテラル (自前ダーク対応は.emlフィクスチャなし、AppEnvironment内
# にのみ存在)。5番目 (Task #98)・6番目 (Task #104)・7番目 (Task #112)・
# 9番目 (Task #133)・10番目 (Task #205) も .emlフィクスチャなし、
# AppEnvironment内にのみ存在。
#
# Env:
#   IOS_SIMULATOR    Simulator name (default: iPhone 17 Pro Max)
#   SCREENSHOT_DIR   Where to write PNGs (default: /tmp/otegami-verify)
#   BUNDLE_ID        App bundle id (default: com.mtkg.otegami)
#   APPEARANCE       light|dark — `simctl ui ... appearance`をlaunch前に
#                    設定する。未指定ならシミュレータの現在値のまま。
#   DISABLE_AVATAR_SOURCES  0にするとアバターdisableフラグを付けない
#                           (連絡先権限ダイアログの実際の見た目を確認したい
#                           ときだけ; 既定 1)
#   SKIP_BUILD       1 = ビルド/インストールをスキップし、既にインストール
#                    済みのビルドをそのまま使う (`list`/`settings`など
#                    フィクスチャ挿入を伴わない/1回で足りるシナリオの
#                    繰り返し確認向け高速化用)。**注意**: `html-*`は
#                    フィクスチャ挿入が「同じ install内で1回だけ」しか
#                    効かない (下記) ので、`SKIP_BUILD=1`で別の
#                    `OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX`へ切り替え
#                    ても直接遷移は発火せず一覧のままになる — 別indexを
#                    試すときは`SKIP_BUILD=0`(既定)のままにすること。
#   ERASE_SIMULATOR  1 = 起動前に `simctl erase` (シミュレータ全体を真っさら
#                    にする、既定は0)。`SKIP_BUILD=0`(既定)の通常経路は
#                    ビルドのたびに`simctl uninstall`→`install`でアプリの
#                    GRDBも毎回まっさらにする (下記) ので、`html-*`の直接
#                    遷移だけが目的ならこれは通常不要 — Springboard自体の
#                    初回ブート待ちが余分にかかるだけ遅い。真に「初回起動」
#                    の見た目 (通知許可ダイアログを敢えて見る等) を確認
#                    したいときだけ使う。
#   LOCALE           Task #170 (言語設定の総点検): ja | en — 指定すると
#                    `-AppleLanguages (xx)` `-AppleLocale xx_XX` を launch
#                    引数に追加し、シミュレータ本体の言語設定を変えずに
#                    このアプリのプロセスだけをその言語で起動する (Xcode の
#                    スキーム編集画面の「Application Language」と同じ、
#                    アプリ単位の言語上書き)。未指定ならシミュレータの
#                    現在の言語設定のまま。
#   WAIT_SECONDS     起動〜スクリーンショットまでの待ち時間 (default: 4)。
#                    `ERASE_SIMULATOR=1`の直後は初回ブートでSpringboard/
#                    アプリの初期化が普段より遅く、4秒では足りないことが
#                    あった (実測: 10秒で安定) — `ERASE_SIMULATOR=1`と
#                    併用するときは`WAIT_SECONDS=10`以上を指定すること。
#
# 既存の `OTEGAMI_UITEST_*` launch-environment flags のうち、このスクリプト
# が使わないもの (`rg 'OTEGAMI_UITEST_' apps/Otegami/Sources/AppEnvironment.swift`
# で棚卸し済み — 各詳細はそのファイル自身のドキュメントコメント参照。他の
# `scripts/verify-ios-*.sh`/`OtegamiUITests`が個別の目的で使う):
#   OTEGAMI_UITEST_MOVE_CREDENTIALS_TO_LEGACY_KEYCHAIN_SERVICE
#   OTEGAMI_UITEST_RELOCATE_CREDENTIAL_TO_ORPHAN_ACCOUNT_ID
#   OTEGAMI_UITEST_SKIP_DUPLICATE_ACCOUNT_MERGE
#   OTEGAMI_UITEST_FAKE_TRANSLATION
#   OTEGAMI_UITEST_DISABLE_CLOUD_SYNC
# launch *引数* (環境変数ではない) も同様に一部未使用のものがある:
#   -uiTestsSkipThreadRestoration
#   -otegamiEnableCloudSyncInSimulator
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$(dirname "${BASH_SOURCE[0]}")/lib/simulator.sh"

SCENARIO="${1:-}"
if [[ -z "$SCENARIO" ]]; then
  echo "usage: scripts/verify-screen.sh <scenario> [output-filename.png]" >&2
  echo "       see this script's own header comment for the scenario list" >&2
  exit 1
fi

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"
APPEARANCE="${APPEARANCE:-}"
LOCALE="${LOCALE:-}"
DISABLE_AVATAR_SOURCES="${DISABLE_AVATAR_SOURCES:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
ERASE_SIMULATOR="${ERASE_SIMULATOR:-0}"
WAIT_SECONDS="${WAIT_SECONDS:-4}"
DERIVED_DATA_PATH="/tmp/otegami-verify-screen-derived-data"

mkdir -p "$SCREENSHOT_DIR"

# シナリオ → (launch env vars / launch args / 既定の出力ファイル名)。
launch_env=("OTEGAMI_UITEST_DISABLE_CLOUD_SYNC=1") # 一覧・本文どちらもクラウド同期は不要 (`docs/verify.md`と同じ理由)
launch_args=("-uiTestsAutoAdvanceToContent")
default_out=""

# シナリオ→(env/args/出力ファイル名)のデータテーブル。以前はここに44分岐の
# `case "$SCENARIO" in ... esac` がそのまま書かれていたが、分岐の中身が
# ほぼ均質だったためテーブル駆動に変換した (Phase 5 scripts/Makefile衛生) —
# データ本体は scripts/lib/verify-screen-scenarios.sh 参照 (各シナリオの
# 詳しい説明はこのファイル冒頭の「Scenarios:」節が正)。
source "$(dirname "${BASH_SOURCE[0]}")/lib/verify-screen-scenarios.sh"

CANON_SCENARIO="${SCENARIO_ALIAS[$SCENARIO]:-$SCENARIO}"
if [[ ! -v SCENARIO_OUT[$CANON_SCENARIO] ]]; then
  echo "error: unknown scenario '$SCENARIO' — see this script's header comment for the list" >&2
  exit 1
fi
if [[ -n "${SCENARIO_ENV[$CANON_SCENARIO]:-}" ]]; then
  read -ra _scenario_extra_env <<< "${SCENARIO_ENV[$CANON_SCENARIO]}"
  launch_env+=("${_scenario_extra_env[@]}")
fi
if [[ -n "${SCENARIO_ARGS[$CANON_SCENARIO]:-}" ]]; then
  read -ra _scenario_extra_args <<< "${SCENARIO_ARGS[$CANON_SCENARIO]}"
  launch_args+=("${_scenario_extra_args[@]}")
fi
default_out="${SCENARIO_OUT[$CANON_SCENARIO]}"

if [[ "$DISABLE_AVATAR_SOURCES" == "1" ]]; then
  launch_env+=("OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES=1")
fi
launch_env+=("OTEGAMI_UITEST_DISABLE_NOTIFICATION_PERMISSION_REQUEST=1")

if [[ -n "$LOCALE" ]]; then
  case "$LOCALE" in
    ja) launch_args+=("-AppleLanguages" "(ja)" "-AppleLocale" "ja_JP") ;;
    en) launch_args+=("-AppleLanguages" "(en)" "-AppleLocale" "en_US") ;;
    *)
      echo "error: unknown LOCALE '$LOCALE' — expected 'ja' or 'en'" >&2
      exit 1
      ;;
  esac
fi

OUT_NAME="${2:-$default_out}"
OUT_PATH="$SCREENSHOT_DIR/$OUT_NAME"

resolve_simulator_udid

if [[ "$ERASE_SIMULATOR" == "1" ]]; then
  echo "==> Erasing simulator content (ERASE_SIMULATOR=1)"
  erase_simulator
fi

echo "==> Booting simulator (if needed)"
boot_simulator
# 保険 — DISABLE_AVATAR_SOURCES=0 で連絡先解決自体を確認したい場合や、
# フラグ導入前にインストールされた古いビルドが動いている場合でも権限
# ダイアログで待たされないようにする (`docs/verify.md`の既存の対策と同じ)。
grant_contacts_privacy

if [[ -n "$APPEARANCE" ]]; then
  echo "==> Setting appearance to '$APPEARANCE'"
  xcrun simctl ui "$UDID" appearance "$APPEARANCE"
fi

if [[ "$SKIP_BUILD" == "1" ]]; then
  echo "==> SKIP_BUILD=1 — reusing whatever's already installed"
else
  echo "==> Regenerating Xcode project and building (app only, no test bundle)"
  (cd apps/Otegami && xcodegen generate)
  xcodebuild \
    -project apps/Otegami/Otegami.xcodeproj \
    -scheme Otegami \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build

  APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/Otegami.app"
  if [[ ! -d "$APP_PATH" ]]; then
    echo "error: could not locate the built Otegami.app at $APP_PATH" >&2
    exit 1
  fi
  # Reinstalling *over* a previous install would keep that install's GRDB
  # database (and App Group container) around — every `OTEGAMI_UITEST_
  # INSERT_FAKE_*`フィクスチャ挿入は「同じメールアドレスの行が既に無ければ
  # 挿入」というガード付き (`AppEnvironment.init()`の各ブロック参照) なので、
  # 2回目以降の launch では何も挿入されず、`OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX`
  # による本文への直接遷移も (挿入ブロック自体がスキップされる以上)
  # 発火しない — 一覧画面のまま止まって見える。`uninstall`してから
  # `install`することで、この (build-and-install する) 通常経路は毎回
  # 「まっさらな新規インストール」になり、`html-*`シナリオが常に本文まで
  # 直行できるようにする (`ERASE_SIMULATOR=1`のようなシミュレータ全体の
  # 消去より軽い — Springboardの再起動や通知許可の決定は保持される)。
  echo "==> Installing the just-built app (uninstall first for a genuinely fresh app container)"
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$UDID" "$APP_PATH"
fi

echo "==> Launching '$SCENARIO' (env: ${launch_env[*]} / args: ${launch_args[*]})"
# `simctl launch`自身はenvを渡すフラグを持たない — 呼び出し元シェルの
# `SIMCTL_CHILD_<NAME>`環境変数だけが子プロセスへ引き継がれる
# (`xcrun simctl launch --help`参照)。`env`コマンドでその場限りの
# `SIMCTL_CHILD_*`を組み立てて渡す。
env_args=()
for kv in "${launch_env[@]}"; do
  env_args+=("SIMCTL_CHILD_${kv}")
done
env "${env_args[@]}" xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" "${launch_args[@]}"

echo "==> Waiting ${WAIT_SECONDS}s for the view to settle"
sleep "$WAIT_SECONDS"

echo "==> Screenshot -> $OUT_PATH"
xcrun simctl io "$UDID" screenshot "$OUT_PATH"

echo "==> Done: $OUT_PATH"
