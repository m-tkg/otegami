#!/usr/bin/env bash
# scripts/verify-screen.sh のシナリオ定義テーブル。
#
# 以前は scripts/verify-screen.sh 内の44分岐 `case "$SCENARIO" in ... esac`
# だった — 各分岐の中身はほぼ均質 (launch_env+=(...) / launch_args+=(...) /
# default_out=... の代入だけ) だったため、テーブル駆動 (連想配列) に変換した
# (Phase 5 scripts/Makefile衛生)。ロジック自体 (シミュレータ起動・
# スクリーンショット取得) はここではなく scripts/verify-screen.sh 側に残っている
# — このファイルは純粋にデータ。
#
# 各シナリオの詳しい説明は scripts/verify-screen.sh 冒頭の「Scenarios:」節が
# 正 — ここのコメントは`case`アームから引き継いだ実装メモ (一部のシナリオのみ)。

declare -A SCENARIO_ENV=() SCENARIO_ARGS=() SCENARIO_OUT=() SCENARIO_ALIAS=()

# html-0 / html-security-notice
SCENARIO_OUT[html-0]="html-0-security-notice.png"
SCENARIO_ENV[html-0]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=0"
SCENARIO_ALIAS[html-security-notice]=html-0

# html-1 / html-no-colors
SCENARIO_OUT[html-1]="html-1-no-colors.png"
SCENARIO_ENV[html-1]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=1"
SCENARIO_ALIAS[html-no-colors]=html-1

# html-2 / html-self-dark-aware
SCENARIO_OUT[html-2]="html-2-self-dark-aware.png"
SCENARIO_ENV[html-2]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=2"
SCENARIO_ALIAS[html-self-dark-aware]=html-2

# html-3 / html-beta-testing-notice
SCENARIO_OUT[html-3]="html-3-beta-testing-notice.png"
SCENARIO_ENV[html-3]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=3"
SCENARIO_ALIAS[html-beta-testing-notice]=html-3

# html-4 / html-makerworld-like
SCENARIO_OUT[html-4]="html-4-makerworld-like.png"
SCENARIO_ENV[html-4]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=4"
SCENARIO_ALIAS[html-makerworld-like]=html-4

# html-5 / html-calendar-invite-realistic
SCENARIO_OUT[html-5]="html-5-calendar-invite-realistic.png"
SCENARIO_ENV[html-5]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=5"
SCENARIO_ALIAS[html-calendar-invite-realistic]=html-5

# html-6 / html-style-block-gray-text
SCENARIO_OUT[html-6]="html-6-style-block-gray-text.png"
SCENARIO_ENV[html-6]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=6"
SCENARIO_ALIAS[html-style-block-gray-text]=html-6

# html-7 / html-white-card-hero
SCENARIO_OUT[html-7]="html-7-white-card-hero.png"
SCENARIO_ENV[html-7]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=7"
SCENARIO_ALIAS[html-white-card-hero]=html-7

# Task #133: index 8 is already Task #128's SSO-notice fixture (see this
# script's own scenario-list comment above for why this skips straight
# to 9).
SCENARIO_OUT[html-9]="html-9-gmail-quote-history.png"
SCENARIO_ENV[html-9]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=9"
SCENARIO_ALIAS[html-gmail-quote-history]=html-9

# Task #205 (実機報告: 画像が出ない/幅・高さが崩れる/ソースを表示が
# 空白 — `AppEnvironment
# .uitestFakeHTMLMessageBodyResponsiveTableFooterNotice`のdoc comment
# 参照): `http:` 外部画像2枚 + `width="100%"`のネストしたレスポンシブ
# テーブル + 濃色背景フッターという実メールの骨格を再現。画像/幅の
# 見た目確認用 (「ソースを表示」自体はこのシナリオでは直接遷移して
# いない — `message-source`シナリオ参照)。
SCENARIO_OUT[html-10]="html-10-responsive-table-footer.png"
SCENARIO_ENV[html-10]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=10"
SCENARIO_ALIAS[html-responsive-table-footer]=html-10

# 実機報告 (ユーザー提供の実メール rakuten.eml、内容は伏せて構造だけ再現):
# 背景が最後まで解決しない一覧テーブル+縦長のデータ行 — `AppEnvironment
# .uitestFakeHTMLMessageBodyFundPriceNotificationTallTable`のdoc comment
# 参照。ダークモードの色判定と、展開時の固定高さバジェットを超える縦長
# コンテンツのスクロール挙動の確認用。
SCENARIO_OUT[html-11]="html-11-fund-price-notification-tall-table.png"
SCENARIO_ENV[html-11]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=11"
SCENARIO_ALIAS[html-fund-price-notification]=html-11

# Task #66: `CalendarInviteSectionView`'s card (title/time/location/
# organizer + 承諾/辞退/未定 buttons) — see `AppEnvironment
# .uitestFakeCalendarInviteICS`'s doc comment for why this reads the
# ICS from a locally-written file rather than a real IMAP/attachment
# download.
SCENARIO_OUT[calendar-invite]="calendar-invite.png"
SCENARIO_ENV[calendar-invite]="OTEGAMI_UITEST_INSERT_FAKE_CALENDAR_INVITE=1"

# Task #123: see this script's own header comment above for what this
# screenshot is checking (`QuoteHistorySectionView`'s toggle + card).
SCENARIO_OUT[quote-history]="quote-history.png"
SCENARIO_ENV[quote-history]="OTEGAMI_UITEST_INSERT_FAKE_QUOTED_PLAIN_MESSAGE=1"

# Task #103 (「ソースを表示」): html-0 fixture's message, with
# `-uitestsOpenMessageSourceDirectly` (`ThreadDetailView`'s
# `hasPinnedInitialExpansion`-keyed `.onChange`) opening
# `MessageSourceView`'s sheet without a "…" メニュー tap. The raw
# source itself is pre-written straight to `MessageSourceFetcher`'s
# cache file by `AppEnvironment` (`MessageSourceFetcher.prewarmCache`)
# for this same reason `calendar-invite` above reads its ICS from a
# locally-written file — this fake account's IMAP host never actually
# connects on this simulator/toolchain.
SCENARIO_OUT[message-source]="message-source.png"
SCENARIO_ENV[message-source]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=0"
SCENARIO_ARGS[message-source]="-uitestsOpenMessageSourceDirectly"

# Task #136: see this script's own header comment above — insertion
# only, no direct open, so the screenshot lands on the message list with
# the 3-message thread's row visible (count badge under the date).
SCENARIO_OUT[thread-list]="thread-list.png"
SCENARIO_ENV[thread-list]="OTEGAMI_UITEST_INSERT_FAKE_MULTI_MESSAGE_THREAD=1"

# Task #136: same fixture as `thread-list`, plus
# `OTEGAMI_UITEST_OPEN_MULTI_MESSAGE_THREAD_DIRECTLY=1` so
# `AppEnvironment.uitestDirectOpenThreadId` is set and `MailScreenView`'s
# `.task` pushes straight into `ThreadEntryView`/`ThreadDetailView` with
# no tap — the accordion (newest message expanded, other 2 collapsed).
SCENARIO_OUT[thread-accordion]="thread-accordion.png"
SCENARIO_ENV[thread-accordion]="OTEGAMI_UITEST_INSERT_FAKE_MULTI_MESSAGE_THREAD=1 OTEGAMI_UITEST_OPEN_MULTI_MESSAGE_THREAD_DIRECTLY=1"

# Task #146 (実機フィードバック「下の方の折りたたみ行を展開したとき、
# 開いたことに気づきにくい」): `thread-accordion`と同じ3通スレッドを
# 直接開いた上で、`-uitestsExpandOldestMessageDirectly`
# (`ThreadDetailView`の`hasPinnedInitialExpansion`-keyed`.onChange`)
# が一番下 (最古) の折りたたみ行をタップ無しで展開する —
# `accordionScrollTarget`の自動スクロールが効いていれば、その行の
# ヘッダが画面上部に来た状態でスクリーンショットが撮れる。
SCENARIO_OUT[thread-accordion-scroll]="thread-accordion-scroll.png"
SCENARIO_ENV[thread-accordion-scroll]="OTEGAMI_UITEST_INSERT_FAKE_MULTI_MESSAGE_THREAD=1 OTEGAMI_UITEST_OPEN_MULTI_MESSAGE_THREAD_DIRECTLY=1"
SCENARIO_ARGS[thread-accordion-scroll]="-uitestsExpandOldestMessageDirectly"

# list
SCENARIO_OUT[list]="list.png"
SCENARIO_ENV[list]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1"

# Task #131: see this script's own header comment above — same fake
# message fixture as `list`, plus `-uitestsExpandFabDirectly`
# (`MailScreenView.isFabExpanded`'s tap-free direct-transition flag) so
# the speed-dial FAB screenshots already expanded.
SCENARIO_OUT[list-fab-expanded]="list-fab-expanded.png"
SCENARIO_ENV[list-fab-expanded]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1"
SCENARIO_ARGS[list-fab-expanded]="-uitestsExpandFabDirectly"

# list-2accounts
SCENARIO_OUT[list-2accounts]="list-2accounts.png"
SCENARIO_ENV[list-2accounts]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT=1"

# Task #92→Task #99 (アカウントダイジェスト画面):
# `-uitestsOpenAccountDigestDirectly`は`MailScreenView`の`.task`ブロックが
# 読む「タップ不要の直接遷移」引数 (`-uitestsOpenSettingsDirectly`等と
# 同じパターン) — グルーピングボタンをタップせず`isGroupByAccount`を
# ONにし、一覧領域を`AccountDigestView`の埋め込み表示に切り替える
# (Task #99 でプッシュ遷移からトグル表示へ変更、ヘッダはそのまま)。
# Task #92 以前の`list-grouped`は`-listDisplay.groupByAccount 1`で一覧
# 自体をインラインSection分割していたが、そのインライン分割機能自体が
# 廃止された(この画面に置き換わった)ため、シナリオ名は後方互換で残し
# つつ中身をこちらに揃えた。
SCENARIO_OUT[list-grouped]="account-digest.png"
SCENARIO_ENV[list-grouped]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT=1"
SCENARIO_ARGS[list-grouped]="-uitestsOpenAccountDigestDirectly"
SCENARIO_ALIAS[account-digest]=list-grouped

# Task #142: このスクリプトの header comment 参照 — ピン留め済み1件+
# 未ピン1件 (`OTEGAMI_UITEST_INSERT_FAKE_PINNED_MESSAGE`) を注入し、
# `OTEGAMI_UITEST_FORCE_PINNED_ONLY=1`(`AppEnvironment.init()`が
# `UserDefaults.standard.set(true, forKey:)`する専用フック) でトグルを
# タップ無しで直接ONにする。
SCENARIO_OUT[list-pinned-only]="list-pinned-only.png"
SCENARIO_ENV[list-pinned-only]="OTEGAMI_UITEST_INSERT_FAKE_PINNED_MESSAGE=1 OTEGAMI_UITEST_FORCE_PINNED_ONLY=1"

# settings
SCENARIO_OUT[settings]="settings.png"
SCENARIO_ARGS[settings]="-uitestsOpenSettingsDirectly"

# Task #78: フローティング設定ボタン (`FolderListSheet
# .floatingSettingsButton`) のアクセント塗り統一確認用 — ハンバーガー
# メニューをタップ無しで直接開く。
SCENARIO_OUT[menu]="menu.png"
SCENARIO_ARGS[menu]="-uitestsOpenFolderMenuDirectly"

# Task #110: フォルダセクション(受信トレイ/アーカイブ/送信済み等)の
# 見出し行タップ=統合ビュー選択、開閉はシェブロン専用、という新しい
# 挙動の見た目確認用 — 2アカウント (`list-2accounts`と同じ組み合わせ)
# を注入し、`-uitestsExpandFolderMenuSectionsDirectly`
# (`FolderListSheet.resetCollapseStateToCurrentSelection()`) で全
# セクションを展開状態のまま直接開く。
SCENARIO_OUT[menu-expanded]="menu-expanded.png"
SCENARIO_ENV[menu-expanded]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT=1"
SCENARIO_ARGS[menu-expanded]="-uitestsOpenFolderMenuDirectly -uitestsExpandFolderMenuSectionsDirectly"

# Task #141 実機フィードバック (2026-07-29「すべてのメールを選ぶと
# ヘッダが『すべてのすべてのメール』になる」): タップ無しで直接
# `.unifiedRole(.all)`を選択し (`-uitestsSelectAllMailDirectly`、
# `MailScreenView`の`.task`ブロック参照)、ヘッダタイトルが二重化して
# いないことをscreenshotで確認する用。
SCENARIO_OUT[list-all-mail]="list-all-mail.png"
SCENARIO_ENV[list-all-mail]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT=1"
SCENARIO_ARGS[list-all-mail]="-uitestsSelectAllMailDirectly"

# Task #151 (「アーカイブ済みの可視化」): `list-all-mail`と同じ fake
# Gmail アカウントフィクスチャの「本当にアーカイブ済み」メッセージを
# タップ無しで直接開く (`uitestDirectOpenThreadId`の既存の仕組み) —
# `MessageHeaderCompactView`の`ArchivedBadge`表示の確認用。
SCENARIO_OUT[archived-message-detail]="archived-message-detail.png"
SCENARIO_ENV[archived-message-detail]="OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT=1 OTEGAMI_UITEST_OPEN_GMAIL_ARCHIVED_MESSAGE_DIRECTLY=1"

# Gmail 二重ラベルによるスレッド内メッセージ重複バグ (実機報告):
# 同じfake Gmailアカウントフィクスチャの「INBOX/All Mailの両方に同じ
# gmailMessageIdで重複したメッセージ」スレッド(`capturedDuplicateThreadId`、
# `AppEnvironment.swift`)をタップ無しで直接開く — `ThreadQuery
# .messages(threadId:db:)`の重複排除後、アコーディオンに1通だけ表示
# されることの確認用。
SCENARIO_OUT[duplicate-thread-detail]="duplicate-thread-detail.png"
SCENARIO_ENV[duplicate-thread-detail]="OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT=1 OTEGAMI_UITEST_OPEN_GMAIL_DUPLICATE_THREAD_DIRECTLY=1"

# Task #189: 設定 → 「一般」をタップ無しで直接開く (`AccountsListContent`
# の `-uitestsOpenGeneralSettingsDirectly` フック) — iCloud 同期トグルが
# 「アカウントの設定」からここへ移設されたことの確認用。
SCENARIO_OUT[general-settings]="general-settings.png"
SCENARIO_ARGS[general-settings]="-uitestsOpenSettingsDirectly -uitestsOpenGeneralSettingsDirectly"

# account-settings
SCENARIO_OUT[account-settings]="account-settings.png"
SCENARIO_ENV[account-settings]="OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT=1"
SCENARIO_ARGS[account-settings]="-uitestsOpenSettingsDirectly -uitestsOpenAccountSettingsDirectly"

# account-edit
SCENARIO_OUT[account-edit]="account-edit.png"
SCENARIO_ENV[account-edit]="OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT=1"
SCENARIO_ARGS[account-edit]="-uitestsOpenSettingsDirectly -uitestsOpenAccountSettingsDirectly -uitestsOpenFirstAccountEditDirectly"

# Task #171 follow-up (登録シークレット入力欄を削除): 設定 →
# 「一般」→「プッシュ通知」をタップ無しで直接開く
# (`GeneralSettingsView` の `-uitestsOpenPushNotificationsDirectly`
# フック、`account-settings` と同じ「1段深いところまで一気に」
# パターン)。iOS専用画面。Task #212 でこのフックの持ち主が
# `AccountSettingsCategoryView` から `GeneralSettingsView` へ
# 移設されたため、`-uitestsOpenAccountSettingsDirectly` の代わりに
# `-uitestsOpenGeneralSettingsDirectly` を積む。
SCENARIO_OUT[push-settings]="push-settings.png"
SCENARIO_ARGS[push-settings]="-uitestsOpenSettingsDirectly -uitestsOpenGeneralSettingsDirectly -uitestsOpenPushNotificationsDirectly"

# Task #173: 同じ画面を、`PushWatchStatusSection`(アカウント別 watch
# 状態一覧)が populated な状態で開く。実リレーへは繋がず、
# `AppEnvironment.init()`/`.fetchPushWatchSummaries()`のUITest専用
# フィクスチャ分岐 (3つの偽`.password`アカウント挿入 + push有効化を
# 強制 + 固定`WatchSummary`2件を返す) を使う — 実際のリレー登録・
# APNsトークン取得は一切発生しない。
SCENARIO_OUT[push-settings-watches]="push-settings-watches.png"
SCENARIO_ENV[push-settings-watches]="OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT=1 OTEGAMI_UITEST_INSERT_FAKE_PUSH_WATCH_ACCOUNTS=1 OTEGAMI_UITEST_FORCE_PUSH_ENABLED=1 OTEGAMI_UITEST_FIXED_PUSH_WATCH_SUMMARIES=1"
SCENARIO_ARGS[push-settings-watches]="-uitestsOpenSettingsDirectly -uitestsOpenGeneralSettingsDirectly -uitestsOpenPushNotificationsDirectly"

# Task #213 (実機フィードバック: Yahoo! JAPAN アカウントだけ通知の内容
# が出ない件を Mac 無しで切り分けたい): 設定→「一般」→「プッシュ通知」
# →「プッシュ通知の診断」を直接開く — `push-settings`と同じ「1段深い
# ところまで一気に」パターンにもう1段
# (`-uitestsOpenPushDiagnosticsDirectly`) 積む。記録が空の状態
# (シミュレータには本物の`NotificationService`実行が一度も無い) の
# 表示確認用。iOS専用画面。
SCENARIO_OUT[push-diagnostics]="push-diagnostics.png"
SCENARIO_ARGS[push-diagnostics]="-uitestsOpenSettingsDirectly -uitestsOpenGeneralSettingsDirectly -uitestsOpenPushNotificationsDirectly -uitestsOpenPushDiagnosticsDirectly"

# 同じ画面を、固定フィクスチャ (`PushDiagnosticsStore
# .uitestFixedRuns` — 成功1件・Yahooの`[LIMIT]`レート制限失敗1件) が
# populated な状態で開く — `push-settings-watches`と同じ「UITest専用
# env varで固定データを返す」パターン
# (`OTEGAMI_UITEST_FIXED_PUSH_WATCH_SUMMARIES`の代わりに
# `OTEGAMI_UITEST_FIXED_PUSH_DIAGNOSTICS`)。
SCENARIO_OUT[push-diagnostics-populated]="push-diagnostics-populated.png"
SCENARIO_ENV[push-diagnostics-populated]="OTEGAMI_UITEST_FIXED_PUSH_DIAGNOSTICS=1"
SCENARIO_ARGS[push-diagnostics-populated]="-uitestsOpenSettingsDirectly -uitestsOpenGeneralSettingsDirectly -uitestsOpenPushNotificationsDirectly -uitestsOpenPushDiagnosticsDirectly"

# Task #100: 設定 → メールビューア → 「ツールバーのカスタマイズ」を
# タップ無しで直接開く (`AccountsListContent`/`MailViewerSettingsView`
# それぞれの`-uitestsOpen*Directly`フックを積み重ねる、`account-edit`
# と同じ「1段深いところまで一気に」パターン)。
SCENARIO_OUT[toolbar-customize]="toolbar-customize.png"
SCENARIO_ARGS[toolbar-customize]="-uitestsOpenSettingsDirectly -uitestsOpenMailViewerSettingsDirectly -uitestsOpenToolbarCustomizeDirectly"

# 2026-07-30: 設定 → メールビューア → 「翻訳の診断」を直接開く —
# Translation はシミュレータで動かない (`docs/verify.md`) ので、実際の
# 判定/テスト翻訳結果ではなくレイアウト・エラー表示体裁の確認用。
SCENARIO_OUT[translation-diagnostics]="translation-diagnostics.png"
SCENARIO_ARGS[translation-diagnostics]="-uitestsOpenSettingsDirectly -uitestsOpenMailViewerSettingsDirectly -uitestsOpenTranslationDiagnosticsDirectly"

# 2026-07-30 (実機フィードバック — 退行「テスト翻訳を実行」がスピナーの
# まま無反応): 上の`translation-diagnostics`に加え
# `-uitestsRunTestTranslationDirectly`でタップ無しに「テスト翻訳を
# 実行」相当を起動する。シミュレータではTranslation自体が動かないため
# 「言語ペア未対応」等のエラーで止まるのが期待挙動 — 目的はハングせず
# スピナーが止まりエラー表示になることの確認。
SCENARIO_OUT[translation-diagnostics-test-run]="translation-diagnostics-test-run.png"
SCENARIO_ARGS[translation-diagnostics-test-run]="-uitestsOpenSettingsDirectly -uitestsOpenMailViewerSettingsDirectly -uitestsOpenTranslationDiagnosticsDirectly -uitestsRunTestTranslationDirectly"

# 2026-07-30 (実機フィードバック — 2度目の退行「同じConfigurationの
# 再代入はSwiftUIから見て変化なし」で2回目以降のリクエストが
# タイムアウトし続けた): 上と同じだが`-uitestsRunTestTranslationTwiceDirectly`
# で1回目が完全に終わってから2回目を直列に実行する — 「セッション
# 供給」カウンタが2まで増え、2回目もハングしないことの確認用。
SCENARIO_OUT[translation-diagnostics-test-run-twice]="translation-diagnostics-test-run-twice.png"
SCENARIO_ARGS[translation-diagnostics-test-run-twice]="-uitestsOpenSettingsDirectly -uitestsOpenMailViewerSettingsDirectly -uitestsOpenTranslationDiagnosticsDirectly -uitestsRunTestTranslationTwiceDirectly"

# Task #86: 空状態 (クエリ未入力、履歴タブ) — トップバー/タブの見た目
# 確認用。アカウントが無くても`SearchScreenView`自体は開けるが、
# フィクスチャ挿入分のアカウントがあった方が実際のスクリーンショットに
# 近い見た目になるので`list`と同じfakeメッセージを挿入しておく。
SCENARIO_OUT[search]="search.png"
SCENARIO_ENV[search]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1"
SCENARIO_ARGS[search]="-uitestsOpenSearchDirectly"

# Task #86: `OTEGAMI_UITEST_SEARCH_PRESET_QUERY`で検索欄にプリセット
# した状態 (チップ列+結果一覧が見える「結果表示中」) — "UITest"は
# `list`と同じfakeメッセージの件名 (「受信トレイのメール (UITest)」等)
# に共通して含まれる断片。
SCENARIO_OUT[search-active]="search-active.png"
SCENARIO_ENV[search-active]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_SEARCH_PRESET_QUERY=UITest"
SCENARIO_ARGS[search-active]="-uitestsOpenSearchDirectly"

# Task #129→#161: see this script's own header comment above —
# `-uitestsOpenComposerDirectly` opens a brand-new Composer with no
# "作成" button tap. This is the "閉" (formatting bar collapsed) state
# of Task #161's Spark-style bottom bar — see `composer-richtext-open`
# for the "開" state.
SCENARIO_OUT[composer-richtext]="composer-richtext.png"
SCENARIO_ENV[composer-richtext]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1"
SCENARIO_ARGS[composer-richtext]="-uitestsOpenComposerDirectly"

# Task #161: same Composer as `composer-richtext`, but with
# `-uitestsShowFormattingBarDirectly` pre-expanding `RichTextFormattingBar`
# (`ComposerView.isFormattingBarVisible`'s doc comment) — tap-free
# "開" state, no dependency on a "T" button tap actually registering.
SCENARIO_OUT[composer-richtext-open]="composer-richtext-open.png"
SCENARIO_ENV[composer-richtext-open]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1"
SCENARIO_ARGS[composer-richtext-open]="-uitestsOpenComposerDirectly -uitestsShowFormattingBarDirectly"

# Task #200 (Composer 宛先サジェスト): `OTEGAMI_UITEST_INSERT_FAKE_MULTI_MESSAGE_THREAD`
# (`AppEnvironment`のdoc comment) が挿入する田中花子/佐藤次郎の
# fromAddresses/toAddressesがそのまま`RecipientHistoryQuery`の材料に
# なる — 宛先欄が空の状態のスクリーンショット (タップ不要経路では
# フィールドへの入力そのものはできないため、候補ドロップダウンが
# 開いた状態は見せられない。macOS版はこのタスクで実際にクリック確認
# 済み、`docs/design-system.md`のTask #200節参照)。
SCENARIO_OUT[composer-recipient-suggestion]="composer-recipient-suggestion.png"
SCENARIO_ENV[composer-recipient-suggestion]="OTEGAMI_UITEST_INSERT_FAKE_MULTI_MESSAGE_THREAD=1"
SCENARIO_ARGS[composer-recipient-suggestion]="-uitestsOpenComposerDirectly"

# Task #162 (実機フィードバック「署名が本文に混ざって編集しづらい」):
# same brand-new Composer as `composer-richtext`, plus
# `OTEGAMI_UITEST_INSERT_FAKE_SIGNATURE` scoping a signature to the fake
# account (`AppEnvironment`'s doc comment on that flag) — a fresh
# composition auto-selects it (no signature ever chosen for this
# account yet → falls through to... here there's no `defaultSignatureId`
# either, so this alone wouldn't auto-select; the account picker's
# `.onChange` does, once `selectedAccountId` resolves to the fake
# account and `loadAvailableSignatures()` finds exactly one signature
# with no recorded last-choice — see `LastSignatureSettingsStore`'s doc
# comment for why an unrecorded account still falls through to
# `AccountRecord.defaultSignatureId`, `nil` here, so the screenshot
# shows the *picker* row ("署名: なし") rather than the picked/previewed
# state — good enough to confirm the "署名: " label prefix and the row's
# presence without a tap; picking a specific signature and confirming
# the gray preview appears is real-device-only, same as every other
# tap-driven effect this task already defers to real-device
# verification.
SCENARIO_OUT[composer-signature]="composer-signature.png"
SCENARIO_ENV[composer-signature]="OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1 OTEGAMI_UITEST_INSERT_FAKE_SIGNATURE=1"
SCENARIO_ARGS[composer-signature]="-uitestsOpenComposerDirectly"
