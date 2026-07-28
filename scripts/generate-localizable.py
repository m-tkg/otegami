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

**KNOWN DRIFT (found during Task #100, unresolved)**: as of this comment,
the committed `Localizable.xcstrings` has ~30 more entries than this
`translations` dict produces (e.g. "画像を表示"/"埋め込み画像を表示"/
"リモート画像も読み込む"/"アカウントでグループ化" are in the shipped
catalog, actively referenced by `HTMLMessageView.swift`/`MailScreenView
.swift`, but absent here) — someone edited the `.xcstrings` file directly
(Xcode's own String Catalog editor, most likely) without mirroring the
addition back into this script. **Do not run this script and commit its
output until that drift is reconciled** — doing so silently deletes every
entry this dict doesn't know about, which is exactly the mistake Task #100
avoided by hand-patching new entries into the JSON instead of regenerating.
Reconciling means diffing the live catalog's keys against this dict and
folding the extras back in as their own lines below (or accepting them as
Xcode-editor-owned and excluding this script from the workflow entirely) —
out of scope for whatever bug/feature you're fixing right now unless that's
specifically what you're here to fix.
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
    "OK": "OK",
    "キャンセル": "Cancel",
    "選択解除": "Deselect All",
    "全選択": "Select All",
    "再同期": "Refresh",
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
    "To (カンマ区切り)": "To (comma-separated)",
    "Cc (カンマ区切り)": "Cc (comma-separated)",
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
    "埋め込み画像はメールに直接添付・埋め込まれた画像（cid: インライン画像・画像添付）です。リモート画像は外部サーバーから読み込む画像で、自動で読み込むと送信者にメールを開いたことが伝わる場合があります（開封トラッキング）。いずれもオフの場合は、メール詳細画面の「画像を表示」ボタンでそのメールだけ一時的に表示できます。":
        "Embedded images are attached directly inside the message (cid: inline images and image attachments). Remote images load from an external server, and loading them automatically can let the sender know you opened the message (open tracking). With either off, you can still show images for a single message using the “Show Images” button in the message view.",
    "アプリ内ブラウザ": "In-App Browser",
    "デフォルトブラウザ": "Default Browser",
    "リンク": "Links",
    "メール本文内のリンクをタップしたときに、アプリ内のブラウザで開くか、端末のデフォルトブラウザで開くかを選べます。":
        "Choose whether tapping a link in a message opens it in the in-app browser or your device's default browser.",
    "既定ではピン留めはこの端末・このアプリだけのローカルな印です。ONにすると、ピン留め/解除のたびに IMAP の \\Flagged フラグも更新し、他のメールクライアントでのフラグ操作も読み取ってピン留めに反映します。":
        "By default, pinning is a local marker for this app on this device only. When on, pinning/unpinning also updates the IMAP \\Flagged flag, and flag changes made in other mail clients are reflected back as pins.",
    "サーバーのフラグ (\\Flagged) と連動": "Sync with Server Flag (\\Flagged)",
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
    "例: 会社用の署名": "e.g. Work Signature",
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
    "自分でホストしたプッシュ中継サーバ (otegami-relay) の URL を入力してください。":
        "Enter the URL of your self-hosted push relay server (otegami-relay).",
    "リレー URL": "Relay URL",
    "https:// が必須です（ローカル開発時のみ http://localhost を使用できます）。":
        "https:// is required (http://localhost is allowed for local development only).",
    "プッシュ通知は有効です": "Push Notifications Are Enabled",
    "無効にする": "Disable",
    "有効にする": "Enable",
    "設定アプリを開く": "Open Settings App",
    "資格情報の送信について": "About Sending Credentials",
    "同意して有効にする": "Agree & Enable",
    "有効にすると、パスワード認証で設定した各アカウントの IMAP 接続情報（サーバー・ユーザー名・パスワード）が入力したリレー URL のサーバーへ送信され、暗号化して保存されます。リレーの運用者を信頼できる場合のみ有効にしてください。Gmail (OAuth) アカウントは現バージョンでは対象外です。":
        "Turning this on sends each password-authenticated account's IMAP connection info (server, username, password) to the server at the relay URL you entered, where it's stored encrypted. Only enable this if you trust the relay's operator. Gmail (OAuth) accounts aren't supported in this version.",

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
}


def build():
    strings = {}
    for ja, en in translations.items():
        strings[ja] = {
            "localizations": {
                "en": {
                    "stringUnit": {
                        "state": "translated",
                        "value": en,
                    }
                }
            }
        }
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
