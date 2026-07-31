#!/usr/bin/env python3
"""Regenerates apps/Otegami/Resources/Localizable.xcstrings from the ja->en
dict below. Not part of the Xcode project (lives in scripts/, not under
Resources/, so XcodeGen never treats it as a bundle resource) — a one-off/
occasionally-rerun authoring tool; its output is what's actually committed.
Run from anywhere in the repo: `python3 scripts/generate-localizable.py`.
See docs/localization.md for the coverage policy and how to extend this
list (most entries need nothing beyond adding a line here, since Text/
Button/Label already use the Japanese literal itself as the String Catalog
key — see that doc for the cases that need an actual Swift-side change).

**Drift reconciled at Task #145 (2026-07)**: the drift first noted during
Task #100 had grown to 82 entries present in the committed
`Localizable.xcstrings` but missing from this dict (mostly the Yahoo/
Outlook/Office365/Exchange/Microsoft account-setup screens, calendar
invite responses, and a few HTML-display/toolbar strings) plus one stale
entry whose Swift-side literal had since changed ("例: 会社用の署名" →
"例: あいさつ用の署名", `SignatureTemplateEditView`'s placeholder). Folded
all 82 back in as their own lines below (grouped under "--- Task #145
drift reconciliation ---") using the `en` value already committed in the
live catalog, and fixed the stale one in place. Verified this script's
output now byte-for-byte matches the committed catalog before committing
either.

**Keeping this from drifting again**: whenever you edit
`Localizable.xcstrings` directly via Xcode's String Catalog editor
(rather than adding a line here and rerunning the script), mirror the
same key/value back into this dict in the same commit — otherwise the
next unrelated run of this script will silently delete your addition.
If you're ever unsure whether the two are still in sync, diff the live
catalog's keys against this dict (`python3 -c` with `json.load` +
`importlib` works fine ad hoc) before rerunning and committing.
"""
import json
import pathlib

OUTPUT_PATH = pathlib.Path(__file__).resolve().parent.parent / "apps/Otegami/Resources/Localizable.xcstrings"

translations = {
    # --- 一覧 (MessageListView / MessageListRow / ThreadRowView) ---
    "既読にする": "Mark as Read",
    "未読にする": "Mark as Unread",
    "ピン留めを解除": "Unpin",
    "ピン留め": "Pin",
    "同期エラー": "Sync Error",
    # Task #145: this alert's dismiss button used to read "OK" itself (the
    # source-language literal, not just its English translation) — the
    # only outlier among this app's alert/dismiss buttons, which otherwise
    # all use a Japanese verb ("削除"/"キャンセル"/"閉じる"/etc., see
    # docs/localization.md). Changed the Swift-side literal to "閉じる" to
    # match, so this dict no longer needs an "OK" key at all.
    "キャンセル": "Cancel",
    "選択解除": "Deselect All",
    "全選択": "Select All",
    "再同期": "Refresh",
    # Task #194 (SyncProgressBanner — pull-to-refresh progress/cancel):
    "新着メールを確認中…": "Checking for new mail…",
    "既読・削除状態を同期中…": "Syncing read/deleted status…",
    "整合性を確認中…": "Checking for changes…",
    "メールボックスを再取得中…": "Refreshing mailbox…",
    "同期中…": "Syncing…",
    "再同期を試してください。": "Try refreshing.",
    "メッセージがありません": "No Messages",
    "既読に": "Read",
    "移動": "Move",
    "削除": "Delete",
    "未読のみ表示": "Unread Only",
    "未読のメールはありません": "No Unread Mail",

    # --- スレッド詳細 (ThreadDetailView / MessageView / footer toolbar / bars) ---
    "メール": "Mail",
    # Task #153 (スレッド全体のAI要約): 現時点でこのスクリプトを再実行して
    # いない (ファイル冒頭のKNOWN DRIFT注記どおり — 未解消のドリフトがある
    # 間は再実行禁止) ため、これらのエントリは `apps/Otegami/Resources
    # /Localizable.xcstrings` に直接手で追記済み。ドリフト解消時にこの辞書
    # から再生成しても消えないよう、ここにも同じ4件+ナビゲーションタイトル
    # の計5件を記録しておく。
    "スレッド": "Thread",
    "スレッドの要約": "Thread Summary",
    "スレッドを要約": "Summarize Thread",
    "スレッドの要約を表示": "Show Thread Summary",
    "スレッドの要約を再試行": "Retry Thread Summary",
    "テキストで表示": "Show as Text",
    "HTMLで表示": "Show as HTML",
    "添付ファイル": "Attachment",
    "本文なし": "No Content",
    "返信": "Reply",
    "全員に返信": "Reply All",
    "転送": "Forward",
    "検索": "Search",
    "情報": "Info",
    "その他": "More",
    "ミュート解除": "Unmute",
    "スレッドをミュート": "Mute Thread",
    "アーカイブ": "Archive",
    "迷惑メールにする": "Mark as Junk",
    "英語で返信を下書き": "Draft Reply in English",
    "ツールバーをカスタマイズ": "Customize Toolbar",
    # Task #188: 「その他」メニュー内、表示オフのアクションをまとめる
    # サブメニュー (`MessageDetailFooterToolbar.hiddenActionsMenu`) のラベル。
    "訳文": "Translation",
    "原文": "Original",
    "再試行": "Retry",
    "翻訳": "Translate",
    "要約": "Summarize",
    "再生成": "Regenerate",
    "英語 → 日本語（端末内で翻訳）": "English → Japanese (translated on-device)",
    "この端末では翻訳を利用できません": "Translation isn't available on this device",
    "AI要約（端末内で生成）": "AI Summary (generated on-device)",
    "この端末では要約を利用できません": "Summarization isn't available on this device",
    "メッセージが見つかりません": "No Messages Found",
    "識別子": "Identifiers",
    "ヘッダ": "Headers",
    "生ヘッダ (Received チェーンを含む RFC822 ヘッダ全体) はこのアプリでは保存していないため表示できません。上記はローカルに保存されている envelope 情報です。":
        "The raw RFC822 header (including the Received chain) isn't stored by this app, so it can't be shown. The information above is the envelope data stored locally.",
    "メールの情報": "Message Info",
    "閉じる": "Close",
    "件名": "Subject",
    "メールボックス": "Mailbox",
    "サイズ": "Size",

    # --- 作成 (ComposerView / DraftsView / OutboxView) ---
    "送信": "Send",
    "このメッセージを保存しますか？": "Save this message?",
    "下書きとして保存": "Save as Draft",
    "保存せずに破棄": "Discard",
    "差出人": "From",
    "宛先": "To",
    # Task #164 (実機フィードバック「メール作成のUIがおかしい。ラベルが複数
    # あるとか」): macOS Composer の Section見出し+行ラベル二重表示を解消
    # した際の行ラベル (`ComposerView.swift`のfromSection/addressSection/
    # subjectSectionのdoc comment参照) — 上の見出し用エントリ (コロンなし)
    # とは別キー。
    "差出人:": "From:",
    "宛先:": "To:",
    "Cc:": "Cc:",
    "Bcc:": "Bcc:",
    "件名:": "Subject:",
    "カンマ区切りで複数指定可": "Comma-separated for multiple",
    "本文": "Body",
    "ファイルを選択": "Choose File",
    "写真を選択": "Choose Photo",
    "写真を撮る": "Take Photo",
    "添付": "Attach",
    "ファイルを追加": "Add File",
    "テンプレート": "Templates",
    "テンプレートを挿入": "Insert Template",
    "(件名なし)": "(No Subject)",
    "下書き": "Drafts",
    "下書きを削除しますか？": "Delete this draft?",
    "この下書きを削除します。": "This draft will be deleted.",
    "送信待ち": "Outbox",
    "送信を取り消す": "Cancel Send",
    "新規作成": "New Message",
    "宛先を入力してください。": "Please enter a recipient.",

    # --- 検索 (SearchScreenView) ---
    "人": "People",
    "差出人・件名・本文から、すべてのアカウントを横断して検索します。\n「from:」「to:」「cc:」「subject:」でヘッダを絞り込めます。":
        "Searches sender, subject, and body across every account.\nUse “from:”, “to:”, “cc:”, or “subject:” to narrow by header.",
    "最近の検索": "Recent Searches",
    "履歴をすべて削除": "Clear All History",
    "検索中…": "Searching…",
    "全部": "All",
    "未読": "Unread",
    "すべて": "All",
    "このメールボックス": "This Mailbox",
    # Task #197: macOS の一覧ヘッダ検索欄 (`MacListSearchBar`) — スコープ
    # ピッカー自体は`.labelsHidden()`で非表示だが、VoiceOver/カバレッジ
    # チェック用に文言は必要。「クリア」は`SearchTopBar`の閉じるボタンとは
    # 役割が違う (検索クエリだけを消す) ため専用の文言にした。
    "検索範囲": "Search Scope",
    "検索文字列をクリア": "Clear Search Text",

    # --- 検索画面再構成 (Task #86, Sparkハンドオフ): トップバー (角丸
    # フィールド+星+丸い閉じるボタン)、「履歴」/「保存済み」タブ、保存済み
    # 検索。「英語」フィルタチップはユーザー要望で廃止したため上の節から
    # 削除済み (`SearchFilterOption`参照)。
    "履歴": "History",
    "保存済み": "Saved",
    "検索履歴はありません": "No Search History",
    "保存した検索はありません": "No Saved Searches",
    "検索フィールド左の星をタップすると、今の検索条件 (クエリ・絞り込み・アカウント) を名前を付けずに保存できます。":
        "Tap the star at the left of the search field to save the current query, filter, and account scope — unnamed.",
    "保存済みの検索": "Saved Searches",
    "この検索を保存": "Save This Search",
    "この検索の保存を解除": "Remove This Saved Search",

    # --- ハンバーガーメニュー / メール画面 (MailScreenView / FolderListSheet) ---
    "アカウントがありません": "No Accounts",
    "メールアカウントを追加してください。": "Please add a mail account.",
    "アカウントを追加": "Add Account",
    "作成": "Compose",
    "メニュー": "Menu",
    "フォルダ": "Folders",
    "すべての受信トレイ": "All Inboxes",
    "設定": "Settings",
    "すべての受信": "All Inboxes",

    # --- Task #106: 「全部」チップを「すべて」に改名しプルダウン化
    # (AccountFilterChipRow) — 「すべて」自体は既存キー (`検索`節の
    # フィルタチップと共有)。追加が要るのはメニュー2択のみ。
    "時系列": "Chronological",
    "アカウント別": "By Account",

    # --- 設定 (AccountsSettingsView) ---
    "アカウント": "Account",
    "アカウントがありません。": "No accounts.",
    "iCloud でアカウントを同期": "Sync Accounts via iCloud",
    "同じ Apple ID の他の iOS/Mac デバイスとアカウントの接続設定を同期します。パスワードは iCloud キーチェーンが別途同期します。":
        "Syncs account connection settings with your other iOS/Mac devices signed in with the same Apple ID. Passwords are synced separately by iCloud Keychain.",
    "プッシュ通知": "Push Notifications",
    "操作": "Actions",
    "短いスワイプで表示される操作は、そのままスワイプし切ると即座に実行されます（削除・迷惑メールを除く — 誤操作防止のため、必ずタップでの確定操作です）。長いスワイプの操作は、ボタンが表示されてからのタップでのみ実行されます。":
        "The action shown by a short swipe runs immediately if you swipe all the way through (except Delete and Junk, which always require a tap to confirm, to prevent accidents). The action shown by a long swipe only runs when you tap its button after it appears.",
    "スレッド表示": "Group into Threads",
    "送信者のプロフィールアイコンを表示": "Show Sender Avatars",
    "メール本文にも送信者アイコンを表示": "Also Show Avatars in Message View",
    "一覧・表示": "List & Display",
    # アバター強化バッチ フェーズ1: 旧文言 ("プロフィールアイコンは...外部
    # サービスへの問い合わせは一切行いません。") を置き換えた
    # (`MailListSettingsView.swift`) — 連絡先の写真を追加した時点でもう
    # 正確ではなくなったため。
    "連絡先の写真を表示": "Show Contact Photos",
    "プロフィールアイコンは、差出人のイニシャル+アカウント色を基本に、連絡先に一致する写真があればそれを優先して表示します（連絡先の照合はこの端末上だけで行われ、外部には送信されません）。":
        "Avatars default to the sender's initials and the account's color, preferring a matching contact photo when one exists (contact matching happens on this device only and is never sent externally).",
    "常にテキストで表示": "Always Show as Text",
    "メールの表示": "Message Display",
    "HTMLメールを既定でテキスト表示にします。メール詳細画面の切替ボタンで、メールごとに一時的に戻すこともできます。":
        "Shows HTML messages as plain text by default. You can switch back for an individual message using the toggle button in the message view.",
    "埋め込み画像を自動表示": "Auto-Show Embedded Images",
    "リモート画像を自動で読み込む": "Auto-Load Remote Images",
    "画像": "Images",
    # Task #207 (ユーザー要望「(平文httpの画像を)許可する方針でいいが、
    # 確認ダイアログは出してほしい」): 元の文言 (「いずれもオフの場合は…
    # 一時的に表示できます。」で終わっていた版) に、平文http画像の既定確認
    # 動作の説明を追記した — 古いキーはもう`MailViewerSettingsView.swift`
    # から参照されないのでこの辞書からも削除 (このファイル冒頭のdoc
    # comment「Keeping this from drifting again」の指示どおり)。
    "埋め込み画像はメールに直接添付・埋め込まれた画像（cid: インライン画像・画像添付）です。リモート画像は外部サーバーから読み込む画像で、自動で読み込むと送信者にメールを開いたことが伝わる場合があります（開封トラッキング）。いずれもオフの場合は、メール詳細画面の「画像を表示」ボタンでそのメールだけ一時的に表示できます。暗号化されていない接続 (http) で読み込む画像は、経路上で内容が書き換えられる可能性があるため、リモート画像を自動で読み込む場合でも既定では読み込み前に確認します。この動作は「常に許可」「常に拒否」に変更できます。":
        "Embedded images are attached directly inside the message (cid: inline images and image attachments). Remote images load from an external server, and loading them automatically can let the sender know you opened the message (open tracking). With either off, you can still show images for a single message using the “Show Images” button in the message view. Images loaded over an unencrypted connection (http) can be altered in transit, so even with remote images loading automatically, they're confirmed before loading by default. This behavior can be changed to “Always Allow” or “Always Block”.",
    "保護されていない画像 (http)": "Unprotected Images (http)",
    "保護されていない画像を確認": "Review Unprotected Images",
    "保護されていない接続の画像を読み込みますか？": "Load Images Over an Unprotected Connection?",
    "このメールには暗号化されていない接続 (http) で読み込む画像が含まれています。通信内容は経路上で書き換えられる可能性があります。":
        "This message contains images loaded over an unencrypted connection (http). The content could be altered in transit.",
    "読み込む": "Load",
    "確認する": "Ask Every Time",
    "常に許可": "Always Allow",
    "常に拒否": "Always Block",
    "アプリ内ブラウザ": "In-App Browser",
    "デフォルトブラウザ": "Default Browser",
    "リンク": "Links",
    "メール本文内のリンクをタップしたときに、アプリ内のブラウザで開くか、端末のデフォルトブラウザで開くかを選べます。":
        "Choose whether tapping a link in a message opens it in the in-app browser or your device's default browser.",
    "表示言語": "Display Language",
    "アプリの表示言語を切り替えます。変更を反映するには、アプリを再起動してください。":
        "Switches the app's display language. Restart the app for the change to take effect.",
    "英文を自動で翻訳": "Auto-Translate English Messages",
    "一覧に要約を出す": "Show Summaries in List",
    "翻訳は Apple Intelligence により端末内で行われ、外部に送信されません。":
        "Translation happens on-device via Apple Intelligence and is never sent anywhere else.",
    "このアプリについて": "About This App",
    "アカウントを削除しますか？": "Delete this account?",
    "再認証が必要です": "Reauthentication Required",
    "再認証": "Reauthenticate",
    "資格情報を待っています": "Waiting for Credentials",
    "パスワードを入力": "Enter Password",
    "再認証に失敗しました": "Reauthentication failed",

    # --- 表示言語ピッカー (LocalizationSettingsStore.AppLanguageOption) ---
    "システムに従う": "Match System",
    "日本語": "Japanese",

    # --- 実機フィードバック第2弾: I 設定画面の再構成 (AccountsListContent /
    # AccountSettingsCategoryView / MailViewerSettingsView /
    # MailListSettingsView / OtherSettingsView) ---
    # Task #189: 「一般」(GeneralSettingsView、新設カテゴリ) はこの節に
    # 属していた話ではないが、既存カテゴリ名の並びと同じ場所に置く。
    "一般": "General",
    "アカウントの設定": "Account Settings",
    "メールビューア": "Mail Viewer",
    "メール一覧": "Mail List",
    "デフォルトのアカウント": "Default Account",
    "新規メール作成時の差出人の既定を選べます。削除などで無効になった場合は先頭のアカウントに戻ります。":
        "Choose the default From account for new messages. If it becomes invalid (e.g. the account was deleted), this falls back to the first account.",
    "ブラウザ": "Browser",
    "リンクを開く方法": "Open Links In",
    "削除/アーカイブ後の動作": "After Delete/Archive",
    "メール本文画面から削除・アーカイブ・迷惑メールにする操作をしたあと、一覧に戻るか次のメールを自動で開くかを選べます。":
        "Choose whether to return to the list or automatically open the next message after deleting, archiving, or marking a message as junk from the message view.",
    "メール一覧に戻る": "Return to Mail List",
    "次のメールを開く": "Open Next Message",
    "AI 機能 (翻訳・要約)": "AI Features (Translation & Summary)",
    "AI 機能": "AI Features",
    "翻訳・要約は Apple Intelligence により端末内で行われ、外部に送信されません。オフにすると、メール本文画面の翻訳バー・AI要約ボタンの両方が表示されなくなります。":
        "Translation and summarization happen on-device via Apple Intelligence and are never sent anywhere else. Turning this off hides both the translation bar and the AI summary button in the message view.",
    "表示": "Display",
    "スワイプ": "Swipe",
    "統合受信トレイの未読数をアプリアイコンに表示します。": "Shows the unified inbox's unread count on the app icon.",
    "今すぐ終了": "Quit Now",
    "あとで": "Later",
    "表示言語を変更しました": "Display Language Changed",
    "変更を反映するには、アプリを完全に終了してもう一度起動してください（ホーム画面に戻るだけでは反映されません）。「今すぐ終了」でアプリを終了できます。":
        "To apply the change, fully quit the app and reopen it (returning to the Home Screen alone isn't enough). You can quit the app now with “Quit Now.”",
    "送信キャンセル": "Send Cancellation",
    "送信取り消しの猶予": "Cancel-Send Grace Period",
    "「送信」をタップしてから実際にサーバーへ送るまでの猶予時間です。この間は「送信を取り消す」で送信をキャンセルできます。アプリをバックグラウンドに切り替えると、残り時間に関わらず即座に送信されます。":
        "The grace period between tapping “Send” and the message actually being sent to the server. You can cancel sending during this time with “Cancel Send.” Switching the app to the background sends the message immediately, regardless of the remaining time.",
    "メールの表示 (HTML)": "Message Display (HTML)",
    "ONで一覧を会話単位にまとめます。OFFにすると一覧がメール単位になります。":
        "When on, the list groups messages into conversations. When off, the list shows one row per message.",
    "なし": "None",
    "5秒": "5 Seconds",
    "10秒": "10 Seconds",
    "1行": "1 Line",
    "2行": "2 Lines",
    "3行": "3 Lines",
    "既読/未読切替": "Toggle Read/Unread",

    # --- F 署名テンプレート (SignatureTemplatesSettingsView / SignatureTemplateEditView / AccountLabelColorPicker) ---
    "自動": "Auto",
    "署名テンプレート": "Signature Templates",
    "署名テンプレートを追加": "Add Signature Template",
    "署名テンプレートがありません。": "No signature templates.",
    "署名テンプレートを削除しますか？": "Delete this signature template?",
    "使用するアカウントが選択されていません": "No accounts selected",
    "例: あいさつ用の署名": "e.g. Greeting Signature",
    "使用するアカウント": "Accounts",
    "チェックしたアカウントで作成中のメールの「署名」欄からこの署名を選べます。複数選択できます。":
        "Accounts you check here can select this signature from the Signature field when composing a message. You can select more than one.",

    # --- AboutView ---
    "ライセンス: MIT": "License: MIT",
    "サードパーティライセンス": "Third-Party Licenses",
    "GitHub リポジトリ": "GitHub Repository",
    "既存のメールアカウント (Gmail / iCloud / 汎用 IMAP・SMTP) に接続する、\nオフラインファーストのオープンソースメールクライアントです。":
        "An offline-first, open-source mail client that connects to your existing mail accounts (Gmail / iCloud / generic IMAP & SMTP).",

    # --- AccountSetupView / AccountEditView / ICloudAccountSetupView / GmailAccountSetupView ---
    "なし (平文)": "None (Plain)",
    "表示名": "Display Name",
    "表示名 (省略時はメールアドレス)": "Display Name (defaults to email address)",
    "接続方式": "Security",
    "メールアドレス": "Email Address",
    "保存して同期開始": "Save & Start Syncing",
    "空欄の場合は認証なしで接続します。サーバーが認証に対応していない場合は、ユーザー名を入力していても自動的に認証を省略します。":
        "Leave blank to connect without authentication. If the server doesn't support authentication, it's skipped automatically even when a username is entered.",
    "SMTP (送信用。任意 — 未設定の場合は送信できません)": "SMTP (for sending; optional — sending won't work if unset)",
    "SMTP (送信用。任意)": "SMTP (for sending; optional)",
    "SMTP接続テスト": "Test SMTP Connection",
    "接続先 (固定)": "Server (fixed)",
    "接続先 (自動設定・変更不可)": "Server (preset, not editable)",
    "接続先 (自動設定)": "Server (preset)",
    "新しいパスワード (変更する場合のみ入力)": "New Password (enter only to change it)",
    "その他 (IMAP)": "Other (IMAP)",
    "新しい App 用パスワード (変更する場合のみ入力)": "New App-Specific Password (enter only to change it)",
    "種類": "Type",
    "アカウントを編集": "Edit Account",
    "新規メール作成時、このアカウントを差出人に選ぶと本文末尾に自動で挿入されます（返信・転送では自動挿入されません。作成画面の「署名」欄から手動で選べます）。":
        "When this account is selected as From on a new message, this is automatically appended to the body (not for replies/forwards — you can still pick it manually from the Signature field in the compose screen).",
    "App 用パスワード": "App-Specific Password",
    "appleid.apple.com で App 用パスワードを発行": "Generate an App-Specific Password at appleid.apple.com",
    "Google アカウントでの認証です。パスワードはこのアプリに保存されません。認証が切れた場合は「再認証」から再度サインインしてください。":
        "Authenticated via your Google account. Your password is never stored by this app. If authentication expires, sign in again using “Reauthenticate.”",
    "IMAP ポート番号を確認してください。": "Please check the IMAP port number.",
    "appleid.apple.com で発行した「App 用パスワード」が必要です。iCloud のパスワードそのものではログインできません。":
        "Requires an App-Specific Password generated at appleid.apple.com — your regular iCloud password won't work.",
    "iCloud メールアドレス": "iCloud Email Address",
    "iCloud アカウントを追加": "Add iCloud Account",
    "Gmail アカウントを追加": "Add Gmail Account",
    "Google でログイン": "Sign in with Google",
    "Google のログイン画面が表示されます。otegami はメールの送受信に必要な権限のみをリクエストします。":
        "Google's sign-in screen will open. otegami only requests the permissions needed to send and receive mail.",

    # --- TemplatesSettingsView / TemplateEditView (C8) ---
    "テンプレート": "Templates",
    "テンプレートを追加": "Add Template",
    "テンプレートがありません。": "No templates.",
    "テンプレートを削除しますか？": "Delete this template?",
    "件名（任意）": "Subject (Optional)",
    "すべてのアカウント": "All Accounts",
    "特定のアカウントを選ぶと、そのアカウントで作成中のメールでだけこのテンプレートを使えます。":
        "Choosing a specific account limits this template to messages composed from that account.",
    "件名を入れておくと、新規作成の本文・件名が両方空のときにこのテンプレートで両方埋められます。空のままなら本文だけが挿入されます（署名のような使い方）。":
        "If you set a subject, this template fills in both the subject and body when starting a brand-new, completely empty message. Otherwise only the body is inserted (useful as a signature-style snippet).",

    # --- MessageToolbarSettingsView (Task #100 で表示/非表示トグルを追加、
    # 旧「並び替えのみ」時代の footer 文言はここで差し替え) ---
    "ツールバーの編集": "Edit Toolbar",
    "表示するアイコン": "Icons Shown",
    "トグルをオフにしたアイコンは、ツールバーから消えて「その他」メニューの中から使えるようになります。ドラッグで、オンのアイコンがツールバーに並ぶ順序を変更できます。":
        "Icons you toggle off disappear from the toolbar and move into the “More” menu instead. Drag to reorder the icons that stay on.",
    "「その他」は常にツールバーの末尾に固定表示され、オフにしたり並べ替えたりすることはできません。":
        "“More” always stays fixed at the end of the toolbar — it can't be turned off or reordered.",

    # --- MailViewerSettingsView: フッターツールバー入口 (Task #100、
    # 2026-07-29 追加仕様でアクション集合が7→14に増えたため列挙をやめた) ---
    "フッターツールバー": "Footer Toolbar",
    "メール本文画面下部に並ぶアイコンの表示/非表示と順序を変更できます。非表示にしたアイコンは「その他」メニューから引き続き使えます。":
        "Choose which icons appear at the bottom of the message view, and in what order. Icons you hide are still available from the “More” menu.",

    # --- 2026-07-29 追加仕様: 「その他」ネイティブ項目の一級 MessageToolbarAction 化 ---
    "ミュート": "Mute",

    # --- AccountTypeSelectionView ---
    "アカウントの種類": "Account Type",
    "Gmail と iCloud はホスト設定が自動で入力されます。それ以外のプロバイダは「その他」から手動で設定してください。":
        "Gmail and iCloud have their host settings filled in automatically. For any other provider, set it up manually via “Other.”",

    # --- PushNotificationSettingsView ---
    # Task #173 follow-up (実機フィードバック 2026-07-30 「リレー URL は今の
    # 固定 URL という話をしたよ」): the relay-URL TextField (and its header/
    # footer) was removed entirely — the URL is a build-time value now
    # (`RelayURLConfig`), same as Task #171's registration secret — so the
    # three entries that used to live here ("自分でホストしたプッシュ中継
    # サーバ...", "リレー URL", "https:// が必須です...") are gone, and the
    # consent alert's message below no longer mentions "入力したリレー URL".
    "プッシュ通知は有効です": "Push Notifications Are Enabled",
    "無効にする": "Disable",
    "有効にする": "Enable",
    "設定アプリを開く": "Open Settings App",
    "資格情報の送信について": "About Sending Credentials",
    "同意して有効にする": "Agree & Enable",
    # Task #175: Gmail/Outlook (OAuth) accounts became push-watch-eligible
    # too (an OAuth refresh token is sent/stored encrypted the same way an
    # IMAP password is for a `.password` account) — this consent text used
    # to say those accounts were unsupported.
    "有効にすると、パスワード認証で設定した各アカウントの IMAP 接続情報（サーバー・ユーザー名・パスワード）がプッシュ中継サーバーへ送信され、暗号化して保存されます。Gmail・Outlook（OAuth 認証）アカウントは、パスワードの代わりにアクセス権のリフレッシュトークンが同様に送信され、暗号化して保存されます。いずれもリレーの運用者を信頼できる場合のみ有効にしてください。":
        "Turning this on sends each password-authenticated account's IMAP connection info (server, username, password) to the push relay server, where it's stored encrypted. For Gmail/Outlook (OAuth) accounts, an access refresh token is sent and stored encrypted the same way instead of a password. Only enable this if you trust the relay's operator.",
    "この配布ビルドにはプッシュ中継サーバーが設定されていません。自分のリレーを使う場合は docs/relay-deployment.md を参照して Config/Local.xcconfig に設定してください。":
        "This distribution build has no push relay server configured. If you're running your own relay, see docs/relay-deployment.md and set it in Config/Local.xcconfig.",
    # Task #173: per-account watch status list (`PushWatchStatusSection`).
    "アカウント別の状態": "Status by Account",
    # Task #210: widened from "停止しているアカウントは再登録できます。" —
    # `.notRegistered` rows now also get a button (see
    # `PushWatchStatusSection.showsReregisterButton`'s doc comment for why:
    # before this, a relay that lost every watch — the exact Task #208/#210
    # incident — left every row "未登録" with no way to fix it from here).
    "各アカウントのプッシュ通知 watch の状態です。停止しているアカウント、未登録のアカウントは登録し直せます。":
        "Each account's push-notification watch status. A stopped or not-registered account can be re-registered.",
    # Task #175: the empty state here used to be its own "no password
    # accounts" line ("パスワード認証のアカウントがありません。") — now that
    # Gmail/Outlook accounts are watch-eligible too, this is reached only
    # when there are no accounts at all, so it reuses the existing generic
    # "アカウントがありません。" key (defined once, earlier in this dict) —
    # no separate entry needed here.
    "再登録": "Re-register",
    # Task #210: distinct from "再登録" — used for the same button on a
    # `.notRegistered` row, where "re-" would misleadingly imply the relay
    # once had a watch for this account (see `PushWatchStatusRow
    # .reregisterButton`'s doc comment).
    "登録": "Register",
    "登録済み": "Registered",
    "未登録": "Not Registered",
    "停止（認証失敗）": "Stopped (Authentication Failed)",
    "停止（接続失敗）": "Stopped (Connection Failed)",
    # Task #175: a `.oauth` watch whose refresh token was rejected
    # (invalid_grant) — the fix is re-authenticating the account in the
    # app, not re-entering a password, so this is a distinct label from
    # `.authFailure`.
    "停止（再認証が必要）": "Stopped (Re-authentication Required)",
    "停止": "Stopped",
    # Task #175: Gmail/Outlook became watch-eligible, so this label no
    # longer names a specific provider — it's now only the rare edge case
    # `AppEnvironment.isPushWatchCandidate(_:)` still excludes.
    "対象外": "Not Supported",
    "状態を取得できません": "Status Unavailable",
    "最終接続: %@": "Last connected: %@",
    "最終試行: %@": "Last attempt: %@",
    # Task #176 (実機フィードバック 2026-07-30「通知にタイトル、差出人、本文の
    # 一部を出すかどうかの設定を追加して」): the 3 content toggles
    # (`NotificationContentSettingsStore`/`NotificationEnrichment`) plus this
    # new section's header/footer.
    "通知の内容": "Notification Content",
    "差出人を表示": "Show Sender",
    "件名を表示": "Show Subject",
    "本文プレビューを表示": "Show Body Preview",
    "OS の「設定 → 通知 → プレビューを表示」とは別の設定です。こちらは、このアプリが通知に載せる内容そのものを選びます（両方が有効な場合のみ、選んだ内容が実際に表示されます）。すべてオフにすると「新着メールがあります」のような内容を伴わない通知になります。":
        "This is separate from the OS's Settings → Notifications → Show Previews. This chooses what this app itself puts into a notification's content (both have to be on for what you choose here to actually show). With everything off, a notification looks like “You have new mail” with no further content.",
    # Task #171 originally had a "登録シークレット" SecureField/header/footer
    # here (self-hosted relay's optional RELAY_DEVICE_REGISTRATION_SECRET,
    # typed in by the user). Removed in the 2026-07-30 follow-up — see
    # `RelayRegistrationSecretConfig`'s doc comment — in favor of a
    # build-time value, so this screen no longer has that Section at all.

    # --- 実機フィードバック第3弾 (E): 設定画面配下の未登録文字列を洗い出して
    # 追加。動的な値を埋め込む補間文字列 (例: アカウント削除確認ダイアログの
    # "\(account.displayName) (\(account.email)) を削除すると...") は
    # docs/localization.md が既に明記している既存方針どおり対象外のまま
    # (エラーメッセージの多くと同じ理由 — 該当箇所は該当ファイルのdoc
    # comment参照)。技術用語 (IMAP/TLS/STARTTLS/Gmail/iCloud/Otegami) も
    # 両言語で見た目が同じだが、カタログ未登録のまま放置すると
    # 「登録済みかどうかが文字列ごとにまちまち」という調査コストを将来また
    # 生むため、英訳=原文のまま明示的に登録した。
    "IMAP": "IMAP",
    "TLS": "TLS",
    "STARTTLS": "STARTTLS",
    "Gmail": "Gmail",
    "iCloud": "iCloud",
    "Otegami": "Otegami",
    "https://relay.example.com": "https://relay.example.com",
    "ホスト": "Host",
    "ポート": "Port",
    "ユーザー名": "Username",
    "パスワード": "Password",
    "接続テスト": "Test Connection",
    "認証": "Authentication",
    "署名": "Signature",
    "デフォルト署名": "Default Signature",
    "ラベル色": "Label Color",
    "保存": "Save",
    "名前": "Name",
    "例: 定型の署名": "e.g. Standard Signature",
    "先頭のアカウント": "First Account",
    "削除・アーカイブ": "Delete & Archive",
    "プロフィール画像": "Profile Picture",
    "本文プレビューの行数": "Preview Line Count",
    "右・短いスワイプ": "Right · Short Swipe",
    "右・長いスワイプ": "Right · Long Swipe",
    "左・短いスワイプ": "Left · Short Swipe",
    "左・長いスワイプ": "Left · Long Swipe",
    "この配布ビルドには Google OAuth Client ID が設定されていません。docs/oauth-setup.md を参照して各自 Client ID を発行し、Config/Local.xcconfig に設定してください。":
        "This distribution build has no Google OAuth Client ID configured. See docs/oauth-setup.md to issue your own Client ID and set it in Config/Local.xcconfig.",

    # --- 実機フィードバック第3弾 (H): 表示名等のフィールドに永続ラベルを付与 —
    # 元は "表示名 (省略時はメールアドレス)"/"新しいパスワード (変更する場合
    # のみ入力)" のように1つの文字列だった placeholder を「ラベル」+「短い
    # placeholder」に分割したため、分割後の新しい断片だけをここに追加する
    # (「表示名」「App 用パスワード」等の共通部分は既存キーを再利用)。
    "新しいパスワード": "New Password",
    "新しい App 用パスワード": "New App-Specific Password",
    "変更する場合のみ入力": "Enter only to change it",
    "省略時はメールアドレス": "Defaults to email address",
    "メール作成": "Compose",

    # --- K (実機フィードバック第3弾): ハンバーガーメニューのアカウント
    # セクション折りたたみ — VoiceOver 用の状態値のみ (アカウント名自体は
    # 動的データなので対象外、`AccountSectionHeader`のdoc comment参照)。
    "折りたたみ": "Collapsed",
    "展開": "Expanded",

    # --- タスク#43: 設定画面の日英混在解消。既存カテゴリ (アカウント/
    # メールビューア/メール一覧/署名テンプレート/メール作成) + 直近追加分
    # (アバター診断画面・「連絡先の写真」診断行・メールボックス表示設定・
    # Google プロフィール写真トグル) を走査して見つかった未登録分。この
    # スクリプトは実行時に出力ファイルを**丸ごと上書き**するため、他の
    # 作業ブランチが直接 `Localizable.xcstrings` へ手動追加したエントリ
    # (このスクリプトの dict に無いもの) はこの節を更新しても再実行しない
    # 限り消えない — が、再実行すると当然消える。実際に再実行する場合は
    # `git diff apps/Otegami/Resources/Localizable.xcstrings` で手動追加分
    # が失われていないか必ず確認すること。
    "メールボックスの表示設定": "Mailbox Display Settings",
    "Gmail の「すべてのメール」など、一覧に出したくないメールボックスを個別に隠せます。":
        "You can hide individual mailboxes you don't want in the list, such as Gmail's “All Mail.”",
    "非表示にしたメールボックスは、ハンバーガーメニュー/サイドバーの一覧と統合受信トレイの集計に出なくなり、同期も止まります（電池・通信の節約のためです）。メールの移動先としては引き続き選べます。":
        "A hidden mailbox disappears from the hamburger menu/sidebar tree and the unified inbox count, and stops syncing (to save battery and data). You can still move mail into it.",
    "再接続すると、差出人の Google プロフィール写真 (保存済み連絡先を含む) を表示できるようになります。":
        "Reconnecting lets the sender's Google profile photo (including saved contacts) be shown.",
    "アバター診断": "Avatar Diagnostics",
    "権限を確認中…": "Checking Permission…",
    "連絡先の写真: 許可済み (完全)": "Contact Photos: Authorized (Full)",
    "連絡先の写真: 許可済み (基本) — 保存済み連絡先には未対応。「再認証」をお試しください":
        "Contact Photos: Authorized (Basic) — saved contacts aren't supported. Try “Reauthenticate.”",
    "連絡先の写真: 未許可 — 「再認証」をお試しください":
        "Contact Photos: Not Authorized — Try “Reauthenticate.”",
    "権限を確認できませんでした": "Couldn't Check Permission",
    "スコープ": "Scope",
    "Google に問い合わせて索引を再構築中…": "Rebuilding Index via Google…",
    "アクセストークンを取得できませんでした (再認証が必要な可能性があります)":
        "Couldn't Get Access Token (Reauthentication May Be Required)",
    "otherContacts.list (自動収集された連絡先)": "otherContacts.list (Auto-Collected Contacts)",
    "people/me/connections (保存済み連絡先)": "people/me/connections (Saved Contacts)",
    "people/me (自分のプロフィール写真)": "people/me (Your Profile Photo)",
    "索引": "Index",
    "総アドレス数": "Total Indexed Addresses",
    "最終構築時刻": "Last Built At",
    "もう一度診断する": "Run Diagnostics Again",
    "この画面を開くたびに Google へ実際に問い合わせて索引を再構築します。表示内容のスクリーンショットにはメールアドレスを含む場合があります (エラー本文中のアドレスはマスク済みですが、他の情報は含まれないか確認してから共有してください)。":
        "Opening this screen always contacts Google to rebuild the index. Screenshots of this screen may contain email addresses (addresses in error bodies are masked, but please double-check before sharing anything else shown here).",
    "結果": "Result",
    "HTTP ステータス": "HTTP Status",
    "取得エントリ数": "Entries Fetched",
    "写真ありエントリ数": "Entries With Photo",
    "索引の一部が破棄されました": "Part of the Index Was Discarded",
    "スコープ不足": "Insufficient Scope",
    "取得失敗": "Fetch Failed",
    "Google プロフィール写真を表示": "Show Google Profile Photos",
    "Gravatar の画像を表示": "Show Gravatar Images",
    "企業ロゴを表示": "Show Company Logos",
    "連絡先に写真が無い場合、Gmail アカウントが接続されていれば Google のプロフィール写真を表示することがあります。差出人のメールアドレスが Google に送信されます。設定でオフにできます。":
        "If no contact photo is found, a Google profile photo may be shown when a Gmail account is connected. The sender's email address is sent to Google. You can turn this off in Settings.",
    "それでも見つからない場合、Gravatar (gravatar.com) に登録された画像を表示することがあります。差出人アドレスのハッシュが gravatar.com に送信されます。設定でオフにできます。":
        "If still not found, an image registered at Gravatar (gravatar.com) may be shown. A hash of the sender's address is sent to gravatar.com. You can turn this off in Settings.",
    "それでも見つからない場合、差出人の会社ドメインの favicon を企業ロゴとして表示することがあります（フリーメール (Gmail 等) のアドレスは対象外です）。ドメイン名が接続先サーバーに送信されます。設定でオフにできます。":
        "If still not found, the sender's company domain's favicon may be shown as a company logo (free email domains like Gmail are excluded). The domain name is sent to that server. You can turn this off in Settings.",
    "プロフィールアイコンは差出人のイニシャルとアカウント色から生成され、外部サービスへの問い合わせは一切行いません。":
        "Avatars are generated from the sender's initials and the account's color, with no queries to any external service.",
    "署名テンプレートを編集": "Edit Signature Template",
    "テンプレートを編集": "Edit Template",

    # --- タスク#43 検証中に発見: `AboutView`のバージョン表示。
    # `Text("バージョン \(version) (\(build))")`の interpolation は Xcode の
    # String Catalog 抽出と同じ規則で「%@」プレースホルダのキーになる —
    # 動的な値そのものではなく固定部分のみ変わるため、このスクリプトの
    # 他の補間文字列 (エラーメッセージ等) とは違い翻訳価値があると判断した。
    "バージョン %@ (%@)": "Version %@ (%@)",

    # --- Task #145 drift reconciliation: entries already present in the
    # committed Localizable.xcstrings (added directly via Xcode's String
    # Catalog editor for Yahoo/Outlook/Office365/Exchange/Microsoft account
    # setup, calendar invite responses, and a few HTML-display/toolbar
    # strings) but missing from this dict until now ---
    "AI要約": "AI Summary",
    "Apple の承認待ちです": "Awaiting Apple's Approval",
    "Exchange": "Exchange",
    "Exchange アカウントを追加": "Add Exchange Account",
    "Gmail・iCloud・Yahoo・Yahoo! JAPAN・Exchange はホスト設定が自動で入力されます。それ以外のプロバイダは「その他」から手動で設定してください。":
        "Gmail, iCloud, Yahoo, Yahoo! JAPAN, and Exchange have their server settings filled in automatically. For other providers, use “Other” to set them up manually.",
    "Gmail・iCloud・Yahoo・Yahoo! JAPAN・Outlook・Office365・Exchange はホスト設定が自動で入力されます。それ以外のプロバイダは「その他」から手動で設定してください。":
        "Gmail, iCloud, Yahoo, Yahoo! JAPAN, Outlook, Office365, and Exchange have their server settings filled in automatically. For other providers, use “Other” to set them up manually.",
    "HTMLメールを既定でテキスト表示にします。メール詳細画面の切替ボタンで、メールごとに一時的に戻すこともできます。ダークモード表示中、白背景・濃い文字色を明示したメール（ライトデザインのメール）は、既定では反転せずメール本来の配色（白背景）のまま表示します。色指定を持たないメールは、読みやすい配色に自動で解決されます。メール自身がダークモードに対応済みの場合は何もしません。「ダークモードで暗い背景に反転」をオンにすると、ライトデザインのメールを暗い背景に反転して表示します（文字中心のメールで暗い背景を好む場合向け）。「メールの背景を常に白」をオンにすると、色指定の有無にかかわらずすべてのメールを常に白背景で表示します（このとき上の反転設定は無効になります）。":
        "Shows HTML messages as plain text by default. You can switch back for an individual message using the toggle button in the message view. While in Dark Mode, messages that explicitly set a white background and dark text (light-designed messages) are, by default, left in their original (white-background) colors rather than inverted. Messages with no color declarations at all resolve automatically to a readable color scheme. Messages that already support Dark Mode themselves are left untouched. Turning on “Invert to a Dark Background in Dark Mode” instead inverts light-designed messages to a dark background (for those who prefer a dark background for text-heavy messages). Turning on “Always Show Message Background in White” makes every message always render on a white background regardless of its own colors (the inversion setting above is disabled while this is on).",
    "Microsoft": "Microsoft",
    "Microsoft でログイン": "Sign in with Microsoft",
    "Microsoft のログイン画面が表示されます。会社・学校の Microsoft 365 アカウントでサインインしてください。":
        "Microsoft's sign-in screen will appear. Sign in with your work or school Microsoft 365 account.",
    "Microsoft のログイン画面が表示されます。個人の Outlook.com / Hotmail アカウントでサインインしてください。":
        "Microsoft's sign-in screen will appear. Sign in with your personal Outlook.com / Hotmail account.",
    "Microsoft アカウントでの認証です。パスワードはこのアプリに保存されません。認証が切れた場合は「再認証」から再度サインインしてください。":
        "This account authenticates with your Microsoft account. Your password is never stored in this app. If authentication expires, sign in again via “Reauthenticate.”",
    "Office365": "Office365",
    "Office365 アカウントを追加": "Add Office365 Account",
    "Otegami を既定のメールアプリに設定すると、他のアプリの「メールで送信」リンクや mailto: リンクを開いたときに Otegami が開くようになります。":
        "Setting Otegami as your default mail app makes it open when you tap a \"Mail\" link or a mailto: link in another app.",
    "Outlook": "Outlook",
    "Outlook アカウントを追加": "Add Outlook Account",
    "Yahoo": "Yahoo",
    "Yahoo のアカウント管理でアプリのパスワードを発行": "Get an app password from Yahoo Account Security",
    "Yahoo のアカウント管理で発行した「アプリのパスワード」が必要です。Yahoo のパスワードそのものではログインできません。":
        "You need an app password issued from Yahoo Account Security. Your regular Yahoo password won’t work.",
    "Yahoo アカウントを追加": "Add Yahoo Account",
    "Yahoo メールアドレス": "Yahoo Email Address",
    "Yahoo! JAPAN": "Yahoo! JAPAN",
    "Yahoo! JAPAN アカウントを追加": "Add Yahoo! JAPAN Account",
    "Yahoo!メールの「メールソフトでの利用設定 (IMAP/POP アクセス)」を有効にしておく必要があります。無効のままだと、正しいパスワードでも「メールサーバにアクセスできない」等のエラーで接続できません。":
        "You need to enable “Mail Software Access (IMAP/POP Access)” in Yahoo! Mail first. Without it, connecting will fail (e.g. “can’t reach the mail server”) even with the correct password.",
    "Yahoo!メールの設定で「メールソフトでの利用設定 (IMAP アクセス)」を有効にしておく必要があります。無効のままだと、正しいパスワードでも接続できません。":
        "You need to enable “Mail Software Access (IMAP Access)” in Yahoo! Mail settings first. Without it, connecting will fail even with the correct password.",
    "Yahoo!メールを開く": "Open Yahoo! Mail",
    "Yahoo!メールアドレス": "Yahoo! Mail Address",
    "iOS で既定のメールアプリになるには、Apple から com.apple.developer.mail-client の権限を取得する必要があります。この機能は権限が承認され、このビルドで有効化された後に使えるようになります。":
        "Becoming the default mail app on iOS requires the com.apple.developer.mail-client entitlement from Apple. This feature becomes usable once that's approved and enabled in this build.",
    "「設定」→「アプリ」→「既定のアプリ」→「メール」から Otegami を選んでください。": "Choose Otegami under Settings → Apps → Default Apps → Mail.",
    "この配布ビルドには Microsoft OAuth Client ID が設定されていません。docs/oauth-setup.md を参照して各自 Client ID を発行し、Config/Local.xcconfig に設定してください。":
        "This build has no Microsoft OAuth Client ID configured. See docs/oauth-setup.md to issue your own Client ID and set it in Config/Local.xcconfig.",
    "すべてのメール": "All Mail",
    "アカウントが見つかりません。": "Account not found.",
    "アカウントでグループ化": "Group by Account",
    "アプリのパスワード": "App Password",
    "オフにすると、ツールバーのボタンがアイコンだけになり、高さも詰まります。":
        "When off, toolbar buttons show icons only, and the bar becomes more compact.",
    "ソースを表示": "View Source",
    "ソースを読み込めませんでした。": "Couldn't load the message source.",
    "ソースを読み込めませんでした。オフラインの場合は接続を確認して再試行してください。":
        "Couldn't load the message source. If you're offline, check your connection and try again.",
    "ソースを読み込んでいます…": "Loading source…",
    "ダークモードで暗い背景に反転": "Invert to a Dark Background in Dark Mode",
    "デフォルトのメールアプリに設定": "Set as Default Mail App",
    "ドラッグして、メール本文画面下部のツールバーに並ぶアイコンの順序を変更できます。":
        "Drag to reorder the icons in the toolbar at the bottom of the message view.",
    "フラグ付きのみ表示": "Pinned Only",
    "フラグ付きのメールはありません": "No Pinned Messages",
    "プロフィールアイコンは、差出人のイニシャル+アカウント色を基本に、連絡先の写真・Google プロフィール写真・Gravatar・企業ロゴを優先順に探して表示します。どの情報源を使うか（外部への問い合わせを含む）は「メール一覧」設定の同名のトグルで個別にオフにできます。":
        "Avatars try, in order, the sender's matching contact photo, Google profile photo, Gravatar, and company logo, falling back to the sender's initials and the account's color. Which sources are used (including which ones contact an external service) can be turned off individually from the matching toggles in the Message List settings.",
    "ボタンのラベルを表示": "Show Button Labels",
    "メニューバーの「メール」アプリ (Mail) を開き、「メール」→「設定」→「一般」の「デフォルトのメールアプリ」から Otegami を選べます。バージョンによっては「システム設定」→「デスクトップと Dock」の「メールアプリ」の項目からも変更できます。":
        "Open the Mail app, then choose Otegami from Mail → Settings → General → \"Default Mail App Reader.\" On some macOS versions you can also change it from System Settings → Desktop & Dock → \"Mail App.\"",
    "メールのソース": "Message Source",
    "メールの背景を常に白（ライト表示）": "Always Show Message Background in White (Light Mode)",
    "リモート画像も読み込む": "Also Load Remote Images",
    "ログインID": "Login ID",
    "不参加": "Declined",
    "予定への招待": "Invitation",
    "原文に戻す": "Show Original",
    "参加": "Accepted",
    "埋め込み画像を表示": "Show Embedded Images",
    "委任": "Delegated",
    "手順: Yahoo!メールにログイン → 画面右上の歯車アイコン (設定) → 「メールの基本設定」→ 下の方にある「IMAP/POPアクセス」を「有効にする」に変更して保存。":
        "Steps: Sign in to Yahoo! Mail → the gear icon (Settings) in the top right → “Basic Mail Settings” → near the bottom, set “IMAP/POP Access” to enabled and save.",
    "承諾": "Accept",
    "招待の内容を読み込んでいます…": "Loading invitation…",
    "既定のメールアプリ": "Default Mail App",
    "未回答": "No response",
    "未定": "Maybe",
    "未読かつフラグ付きのメールはありません": "No Unread Pinned Messages",
    "添付ファイル %lld 個": "Attachments (%lld)",
    "現在の回答: %@": "Your response: %@",
    "画像を表示": "Show Images",
    "社内 (オンプレミス) の Exchange サーバーで IMAP アクセスが有効になっている環境向けです。ホスト名はシステム管理者に確認してください。Microsoft 365 / Outlook.com は「アカウントを追加」→「Outlook」または「Office365」からサインインしてください。":
        "For an on-premises Exchange server with IMAP access enabled. Ask your system administrator for the hostname. For Microsoft 365 / Outlook.com, use “Add Account” → “Outlook” or “Office365” instead.",
    "翻訳を再試行": "Retry Translation",
    "翻訳中": "Translating…",
    "表示は先頭512KBまでです。全文はシェアで書き出せます。": "Showing the first 512KB. Share to export the full message.",
    "要約を再試行": "Retry Summary",
    "要約を表示": "Show Summary",
    "要約中": "Summarizing…",
    "設定 Appで既定のメールアプリを選ぶ": "Choose the Default Mail App in Settings",
    "訳文に戻す": "Show Translation",
    "詳しく要約": "Summarize in Detail",
    "辞退": "Decline",
    "通常はメールアドレスと同じログインIDで接続できます。接続テストが失敗する場合は、ログインIDを「@yahoo.co.jp より前の Yahoo! JAPAN ID」だけに変更して再度お試しください。":
        "Usually the login ID is the same as your email address. If the connection test fails, try changing the login ID to just your Yahoo! JAPAN ID (the part before “@yahoo.co.jp”).",

    # --- Task #170 (言語設定不一致の総点検): scripts/check-localizable-
    # coverage.py で新規に検出したカタログ未登録の文字列。macOS メニュー
    # バー (OtegamiCommands, #158/#165), アップデート確認画面 (#158),
    # ハンバーガーメニューのカテゴリ見出し (MailboxRoleDisplay — 「アーカ
    # イブ」「下書き」等は既訳済みだったのに「受信トレイ」「送信済み」等が
    # 抜けており、表示言語を切り替えるとメニュー内で言語が混在していた),
    # トースト・バッジ・空状態など。
    "アカウントを選択": "Select an Account",
    # Task #170: `ThreadDetailView.navigationTitleText` builds this via
    # `String(localized: "スレッド (\(messages.count))")` — `String
    # (localized:)`'s `String.LocalizationValue` interpolation converts an
    # interpolated `Int` into a `%lld` format specifier at the extraction
    # level (not the literal number), the same convention this catalog
    # already uses for "添付ファイル %lld 個" above. Found via manual
    # screenshot verification (LOCALE=en scripts/verify-screen.sh
    # thread-accordion) — check-localizable-coverage.py's static scanner
    # can't resolve this class of call (any interpolated literal is
    # skipped as unresolvable, see its `unescape_swift_literal` doc
    # comment), so this one didn't show up in its report.
    "スレッド (%lld)": "Thread (%lld)",
    # Task #170: same `String(localized: "... \(x)")` format-specifier class
    # as the entry above — found by the same manual `grep 'String(localized:.*\\('`
    # sweep, not the automated scanner (see check-localizable-coverage.py's
    # docstring). `role.categoryDisplayName` (an already-localized `String`,
    # MailboxRoleDisplay) interpolates as `%@`; `MessageListView.title` /
    # `MailScreenView.selectUnifiedRole(_:)` share this exact template for
    # the cross-account "every mailbox with this role" navigation title
    # (e.g. "すべてのアーカイブ"/"All Archive").
    "すべての%@": "All %@",
    # MessageHeaderCompactView.toSummaryText: `name` interpolates as `%@`,
    # `extra` (an `Int`, `message.toAddresses.count - 1`) as `%lld`.
    "宛先: %@": "To: %@",
    "宛先: %@ 他%lld名": "To: %@ and %lld more",
    "アーカイブ済み": "Archived",
    "英語のメール": "English-language Mail",
    "HTMLメール": "HTML Mail",
    "元に戻す": "Undo",
    "本文を入力してください": "Enter a message",
    "添付ファイルの保存に失敗しました。ファイル名が無効です。": "Couldn't save the attachment. The filename is invalid.",
    "下書きはありません": "No Drafts",
    "編集": "Edit",
    "選択中の下書きを削除": "Delete Selected Draft",
    "送信待ちのメールはありません": "No Pending Messages",
    "リンクを削除": "Remove Link",
    "追加": "Add",
    "アーカイブ解除": "Unarchive",
    "受信トレイ": "Inbox",
    "メッセージが選択されていません": "No Message Selected",
    "その他のアクション": "More Actions",
    "失敗した操作はありません": "No Failed Operations",
    "破棄": "Discard",
    "同期に失敗したメールボックスはありません": "No Mailbox Sync Failures",
    "メールボックス同期エラー": "Mailbox Sync Error",
    "承諾済み": "Accepted",
    "辞退済み": "Declined",
    "未定で返答済み": "Responded Maybe",
    "委任済み": "Delegated",
    "招待の内容を読み込めませんでした。": "Couldn't load the invitation.",
    "この招待の内容を解析できませんでした。": "Couldn't parse this invitation.",
    "この招待には主催者の情報がありません。": "This invitation has no organizer information.",
    "宛先: (なし)": "To: (none)",
    "アップデートを確認": "Check for Updates",
    "確認しています…": "Checking…",
    "最新版です": "You're Up to Date",
    "新しいバージョンがあります": "A New Version Is Available",
    "ダウンロードページを開く": "Open Download Page",
    "確認できませんでした": "Couldn't Check for Updates",
    "サイドバーを表示": "Show Sidebar",
    "メールボックスを選択してください": "Select a Mailbox",
    "左のサイドバーからアカウントを追加、またはメールボックスを選択してください。": "Add an account or select a mailbox from the sidebar on the left.",
    "戻る": "Back",
    "フラグ付き": "Flagged",
    "送信済み": "Sent",
    "迷惑メール": "Junk",
    "ゴミ箱": "Trash",
    "新規メッセージ": "New Message",
    "メッセージ": "Message",
    "既読/未読を切り替え": "Toggle Read/Unread",
    "次のメールボックス": "Next Mailbox",
    "前のメールボックス": "Previous Mailbox",
    # Task #170: found alongside the above, in settings screens owned by a
    # concurrent agent (apps/Otegami/Sources/Features/Settings/ — see
    # CLAUDE.md's multi-agent shared-worktree rules) that this task was
    # told not to touch. Adding the catalog entries themselves is safe
    # (source language is ja, so the Japanese literal already committed in
    # those files just becomes this key — no edit to the owned files
    # needed to pick up the translation).
    "カテゴリの並び替え": "Reorder Categories",
    # Task #190: 「アカウントでグループ化」表示の一括操作 (スワイプ/
    # コンテキストメニュー) の確認ダイアログ ON/OFF (`MailListSettingsView`)。
    "一括操作の前に確認する": "Confirm Before Bulk Actions",
    "「アカウントでグループ化」表示でアカウント行をスワイプ（またはコンテキストメニュー）から一括操作するとき、実行前に確認ダイアログを出します。OFFにしても実行後5秒は取り消せます。":
        "Shows a confirmation dialog before running a bulk action from swiping (or the context menu) on an account row in “Group by Account” view. Even when off, you can still undo for 5 seconds after it runs.",
    "このビルドには Google OAuth Client ID が設定されていないため、Google 認証は行えません。詳細は docs/oauth-setup.md を参照してください。":
        "This build has no Google OAuth Client ID configured, so Google sign-in isn't available. See docs/oauth-setup.md for details.",
    "このビルドには Microsoft OAuth Client ID が設定されていないため、Microsoft 認証は行えません。詳細は docs/oauth-setup.md を参照してください。":
        "This build has no Microsoft OAuth Client ID configured, so Microsoft sign-in isn't available. See docs/oauth-setup.md for details.",
    "同じ Apple ID の他の iOS/Mac デバイスとアカウントの接続設定・表示設定 (一覧・ビューア・スワイプ操作など) を同期します。パスワードは iCloud キーチェーンが別途同期します。":
        "Syncs the account's connection and display settings (list/viewer/swipe actions, etc.) with your other iOS/Mac devices signed into the same Apple ID. Passwords are synced separately via iCloud Keychain.",
    # Task #189: iCloud 同期トグルを「アカウントの設定」から新設「一般」
    # (GeneralSettingsView) へ移設した際、Task #186 (設定全般が同期対象に
    # 広がった) の実態に合わせて footer を書き直した — 上の2つの旧文言は
    # もう Swift 側から参照されていないが、過去の screenshot 検証記録との
    # 対応のため削除していない (未使用キーは check-localizable-coverage.py
    # の警告のみ、fatalではない)。
    "同じ Apple ID の他の iOS/Mac デバイスと、アカウントの接続設定に加えて表示・翻訳・通知内容・署名・テンプレートなどの設定を同期します。パスワードは iCloud キーチェーンが別途同期し、メール本文などのキャッシュやプッシュ通知の設定など端末固有の項目は同期しません。":
        "Syncs account connection settings, along with display, translation, notification content, signature, and template settings, with your other iOS/Mac devices signed into the same Apple ID. Passwords are synced separately via iCloud Keychain; local caches such as message bodies and device-specific items like push notification settings are not synced.",
    "ドラッグして、フォルダメニューに並ぶカテゴリの表示順を変更できます。「その他」(独自フォルダ) は常に一番下に表示されます。":
        "Drag to reorder the categories shown in the folder menu. “Other” (custom folders) always stays at the bottom.",
    "フォルダメニューに並ぶ「受信トレイ」「アーカイブ」などカテゴリの表示順を変更できます。":
        "Change the order categories like “Inbox” and “Archive” appear in the folder menu.",
    "プロフィールアイコンは、差出人のイニシャル+アカウント色を基本に、連絡先の写真・Google プロフィール写真・Gravatar・企業ロゴを優先順に探して表示します。どの情報源を使うか (外部への問い合わせを含む) は「メール一覧」設定の同名のトグルで個別にオフにできます。":
        "Avatars try, in order, the sender's matching contact photo, Google profile photo, Gravatar, and company logo, falling back to the sender's initials and the account's color. Which sources are used (including which ones contact an external service) can be turned off individually from the matching toggles in the Message List settings.",

    # --- Pre-existing gap found while getting `make check-localization`
    # green for Task #171 (unrelated to that task itself): `TranslationDiagnosticsView`
    # (`MailViewerSettingsView`'s "翻訳の診断" entry point) landed on main
    # without ever being folded into this dict, so the coverage check was
    # already failing before this task touched anything. Filled in here
    # rather than left broken, since the task's own verification gate is
    # `make check-localization` green.
    "翻訳の診断": "Translation Diagnostics",
    "言語データの状態": "Language Data Status",
    "メール翻訳が実際に使う言語ペア (英語→日本語) について、Apple の Translation フレームワークに直接問い合わせた結果です。":
        "The result of asking Apple's Translation framework directly about the language pair (English → Japanese) that mail translation actually uses.",
    "セッション供給の状況": "Session Supply Status",
    "「設定要求」はこの端末が新しい翻訳セッションを要求した回数、「セッション供給」はホストビューが実際にセッションを渡してきた回数です。前者だけ増え続けて後者が増えない場合、セッションの供給経路自体が機能していません。":
        "“Configuration Requests” counts how many times this device has requested a new translation session; “Session Supplied” counts how many times the host view actually delivered one. If only the former keeps rising while the latter doesn't, the session supply path itself isn't working.",
    "テスト翻訳を実行": "Run Test Translation",
    "テスト翻訳": "Test Translation",
    "まだ記録がありません。メールを開いて翻訳を試すか、上の「テスト翻訳を実行」をお試しください。":
        "No records yet. Open a mail to try translation, or use “Run Test Translation” above.",
    "直近の翻訳試行 (最大5件)": "Recent Translation Attempts (up to 5)",
    "実際にメールを翻訳しようとした際の記録です。件数・文字数・文字の種類の比率のみを表示し、メール本文そのものは表示しません。":
        "A record of actual mail-translation attempts. Shows only counts, character totals, and the ratio of character types — never the mail body itself.",
    "成功": "Success",
    "失敗": "Failure",

    # --- Task #203 (実機フィードバック「HTMLの構造が壊れているメールで
    # 言語判定に失敗する」— Okta 通知メール): `TranslationDiagnosticsView`
    # に「直近の言語判定」セクションを追加した分。
    "直近の言語判定 (最大5件)": "Recent Language Detections (up to 5)",
    "まだ記録がありません。メールを開くと記録されます。":
        "No records yet. Opening a mail records one.",
    "メールを開くたびに再判定した結果です。プレーンテキスト/HTML どちらの候補で判定できたか、文字の種類の比率のみを表示します。":
        "The result of re-detecting the language every time a mail is opened. Shows only which candidate (plain text or HTML) succeeded, and the ratio of character types.",
    "判定できず": "Undetermined",

    # --- Task #202 (実機フィードバック「一度成功した後は必ず翻訳が失敗
    # する」): `TranslationServiceError.sessionUnavailable`の
    # `userFacingMessage` — package層 (`packages/OtegamiKit/Sources
    # /OtegamiTranslation/TranslationServiceError.swift`) からの唯一の
    # `String(localized:)`呼び出し。このpackageは自前の`Localizable
    # .xcstrings`を持たず、`check-localizable-coverage.py`もこのファイルは
    # 対象外 (`apps/Otegami/Sources`のみ走査) だが、`String(localized:)`は
    # 既定で`Bundle.main`(=アプリ本体) の string catalog を引くため、この
    # 辞書へキーを登録しさえすれば実機では正しく解決される。固定・
    # 補間なしの文字列なので、この辞書の他の静的UI文言と同じ扱いで問題
    # ない (冒頭の「補間文字列は対象外」はこの文字列には当てはまらない)。
    # `TranslationUnavailableReason.other`(同package、こちらは裸literalの
    # まま — 呼び出し側が別の失敗理由と共有する定型文で、あちらは
    # 新規のString(localized:)化が本タスクの範囲外) と全く同じ日本語
    # 文言をあえて再利用しており、このキーは新規追加。
    "時間をおいて再試行してください": "Please try again in a moment.",

    # --- Task #182 (macOS アプリ内アップデート、実機フィードバック「update
    # のチェックができる画面は About に移動してほしい。そこから update
    # ボタンも置いて、自身のアップデートができるようにしてほしい」):
    # `AboutView`/`AboutUpdateSection` — Task #158 が追加した独立ウィンドウ
    # `UpdateCheckView`の既存キー ("アップデートを確認"/"確認しています…"/
    # "最新版です"/"新しいバージョンがあります"/"ダウンロードページを開く"/
    # "確認できませんでした"、上のTask #145節にある) はそのまま再利用し、
    # ここには新規追加分だけを列挙する。旧メニュー項目専用だった
    # "アップデートを確認…"(省略記号付き)と、旧フッター注記
    # "プレリリースを含めて確認中"はメニュー項目/自動チェック機構ごと
    # 廃止したため、この節の追加と同時に上の節から削除した。
    "Otegamiについて": "About Otegami",
    "プレリリースも確認する": "Also Check Pre-releases",
    "更新": "Update",
    "検証しています…": "Verifying…",
    "更新を適用しています…": "Installing Update…",
    "更新が完了しました": "Update Installed",
    "今すぐ再起動": "Restart Now",
    "更新に失敗しました": "Update Failed",
    "ダウンロード中…": "Downloading…",
    "このリリースには配布ファイルが見つかりませんでした。": "This release has no downloadable file.",
    "書き込み権限がありません。ダウンロードページから手動でインストールしてください。":
        "No write permission. Please install manually from the download page.",
    "検証に失敗しました。安全のため更新を中止しました。ダウンロードページから手動でインストールしてください。":
        "Verification failed. The update was stopped for safety. Please install manually from the download page.",
    "ダウンロードに失敗しました。しばらくしてから再試行してください。":
        "The download failed. Please try again later.",
    "更新の適用に失敗しました。元のバージョンのまま変更していません。ダウンロードページから手動でインストールしてください。":
        "Installing the update failed. Nothing was changed — you're still on the original version. Please install manually from the download page.",
    "GitHubからの応答を解析できませんでした": "Couldn't parse the response from GitHub",
    "オフラインか、GitHubに接続できませんでした": "You're offline, or couldn't reach GitHub",
    # `String(localized: "template \(x)")`-style interpolated entries — see
    # `PushWatchStatusSection`'s own doc comment (Task #173) for why this
    # class of literal needs a manual dict entry (the automated
    # coverage-checker skips any literal containing Swift interpolation,
    # but `String.LocalizationValue`'s own extraction still resolves it to
    # a `%@`/`%lld` key at the framework level).
    "現在のバージョン: %@": "Current version: %@",
    "現在: %@": "Current: %@",
    "GitHubへの問い合わせに失敗しました (HTTP %lld)": "Couldn't reach GitHub (HTTP %lld)",

    # --- Task #187 (Yahoo! JAPAN 断続的認証失敗の誤誘導文言修正):
    # `MailTransportErrorMessage.classification`'s `.authenticationFailed`
    # branch when `hasSucceededBefore` is true (an existing account's
    # `AccountEditView`「接続テスト」, not a brand-new
    # `AccountSetupView`/`ICloudAccountSetupView` one) — the plain
    # "ユーザー名またはパスワードを確認してください。" wording is misleading for a
    # credential with a proven track record.
    # `(\(description))` is appended *outside* this literal in Swift (plain
    # string concatenation, not interpolation inside the
    # `String(localized:)` call) so this key stays a fixed sentence with no
    # `%@` — see `check-localizable-coverage.py`'s doc comment on why an
    # interpolated literal can't become a stable catalog key.
    "認証に失敗しました。ただし、この資格情報は過去に接続に成功しているため、パスワードの誤りではなく一時的な制限の可能性があります。しばらく時間をおいてから再度お試しください。":
        "Authentication failed. However, since these credentials have connected successfully before, this may be a temporary restriction rather than an incorrect password. Please wait a while and try again.",
}

# Disambiguation comments for a handful of short/reused source strings —
# these existed in the committed catalog (added directly via Xcode's String
# Catalog editor, e.g. Task #66's calendar-invite RSVP labels that are each
# reused for both a button and a read-only current-response label) and
# `build()` below would otherwise silently drop them on the next
# regeneration. Keyed by the same `ja` source string as `translations`.
comments = {
    "最終接続: %@": 'Task #173 PushWatchStatusSection row subtitle for a registered watch, e.g. "最終接続: 3分前" / "Last connected: 3 minutes ago" — %@ is a relative-time-formatted Date.',
    "最終試行: %@": 'Task #173 PushWatchStatusSection row subtitle for a stopped watch, e.g. "最終試行: 3分前" / "Last attempt: 3 minutes ago" — %@ is a relative-time-formatted Date.',
    "添付ファイル %lld 個": 'Task #76 attachment card list header, e.g. "添付ファイル 2 個" / "Attachments (2)".',
    "予定への招待": "Task #66 calendar invite card header, above the event title/time/location.",
    "現在の回答: %@": 'Task #66 calendar invite card: shows the RSVP already recorded for this invite, e.g. "現在の回答: 参加" / "Your response: Accepted".',
    "招待の内容を読み込んでいます…": "Task #66 calendar invite card: loading state while the text/calendar part downloads and parses.",
    "承諾": 'Task #66 calendar invite card: "Accept" RSVP button (also reused for the current-response label).',
    "辞退": 'Task #66 calendar invite card: "Decline" RSVP button (also reused for the current-response label).',
    "未定": 'Task #66 calendar invite card: "Maybe"/tentative RSVP button (also reused for the current-response label).',
    "参加": "Task #66 calendar invite card: current-response label for an accepted invite.",
    "不参加": "Task #66 calendar invite card: current-response label for a declined invite.",
    "未回答": "Task #66 calendar invite card: current-response label meaning no RSVP has been sent yet.",
    "委任": "Task #66 calendar invite card: current-response label for an invite delegated to someone else.",
}


def build():
    strings = {}
    for ja, en in translations.items():
        entry = {}
        comment = comments.get(ja)
        if comment:
            entry["comment"] = comment
        entry["localizations"] = {
            "en": {
                "stringUnit": {
                    "state": "translated",
                    "value": en,
                }
            }
        }
        strings[ja] = entry
    catalog = {
        "sourceLanguage": "ja",
        "strings": strings,
        "version": "1.0",
    }
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write("\n")
    print(f"Wrote {len(strings)} entries to {OUTPUT_PATH}")


if __name__ == "__main__":
    build()
