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
    "メールを検索": "Search Mail",
    "検索中…": "Searching…",
    "差出人・件名・本文 (from:/to:/subject: も使えます)": "Sender, subject, body (from:/to:/subject: also work)",
    "全部": "All",
    "未読": "Unread",
    "英語": "English",
    "すべて": "All",
    "このメールボックス": "This Mailbox",

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
    "プロフィールアイコンは差出人のイニシャルとアカウント色から生成され、外部サービスへの問い合わせは一切行いません。":
        "Avatars are generated from the sender's initials and the account's color — no external service is ever contacted.",
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
