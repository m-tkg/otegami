# ロードマップ (将来項目)

M0〜M10 で実装しなかった/意図的にスコープ外にした項目、または実装中に
見つかった既知の制約のうち、いつか手を付ける価値があるものをまとめる。
優先順位は付けていない。各項目の背景・詳細は該当する参照先を見ること。

## 認証・プッシュ通知

- **Gmail アカウントのプッシュ通知 (XOAUTH2)**: otegami-relay v1 は
  `WatchAuth.Kind.password` のみ対応。Gmail アカウントは refresh token を
  リレーに預ける形の XOAUTH2 対応が必要 (`docs/relay-deployment.md`)。
- **macOS 版のプッシュ通知**: `NotificationService` Extension は iOS のみ。
  macOS 側の通知配信の仕組み (例: `UNUserNotificationCenter` + 独自の
  ローカル通知、またはmacOS 版 push 拡張の設計) は未着手。
- **iCloud のユーザー名短縮形**: `ICloudAccountSetupView` はフルアドレス
  (`user@icloud.com`) を IMAP/SMTP ユーザー名として使う実装。実 iCloud
  アカウントでの確認 (`PENDING.md`) の結果次第で短縮形への切替が必要になる
  可能性がある。

## 同期・データモデル

- **Drafts の IMAP 同期**: M10 で追加したローカル下書き保存
  (`DraftMessageRecord`) はローカル専用。サーバの `Drafts` メールボックス
  との双方向同期 (他クライアントで書いた下書きの取り込み、こちらの下書きの
  アップロード) は未実装。
- **下書きの添付ファイル**: `ComposerView.saveDraft()` は添付ファイルを
  保存しない (テキストフィールドのみ)。`outboxAttachment` と同様の仕組みで
  `draftAttachment` テーブルを持たせれば実現できるはず。
- **Trash メールボックスが存在しないサーバへの対応**: SPECIAL-USE を返さず
  `Trash` という名前のメールボックスも存在しないサーバに対しては、削除
  opQueue がいつまでも `mailboxNotFound` で保留され続ける。Trash の自動
  作成、またはユーザーへの「削除できません」バナー表示が必要
  (`docs/verify.md` M3 節)。
- **`ThreadAssigner.assignAllUnthreaded` のバッチ化**: 2万通の未スレッド化
  メッセージの一括スレッド化に約14秒かかる (`docs/performance.md`)。UI を
  ブロックしないため実害は小さいが、将来 10万通超のバックログや同期的な
  実行が必要になる場面ではスレッド作成・集計をバッチ化する最適化が要る。

## UI/UX

- **To/Cc フィールドのトークン化**: `ComposerView` はカンマ区切りのプレーン
  テキストフィールド (plan: "トークン化は later")。宛先ごとのチップ表示・
  連絡先補完は未実装。
- **HTML 引用返信**: 返信の本文引用は常にプレーンテキスト (`> ` 引用)。
  元メールが HTML の場合の HTML 引用 (`<blockquote>`) は未対応。
- **検索スコープピッカーの XCUITest 操作**: `.searchScopes` の UI 要素
  (「すべて」/「現在のメールボックス」の切替) を安定して XCUITest から
  操作する方法が未確立。単体テスト (`SearchQueryTests`) では
  `SearchScope.mailbox` をカバー済みだが、UI 操作の自動検証はスキップして
  いる (`docs/verify.md` M7 節)。
- **macOS Settings ウィンドウの「アカウント」タブの見た目**: `OtegamiSettingsView`
  は `AccountsListContent` (`AccountsSettingsView` から抽出) を直接埋め込む
  ことで TabView のコンテンツ切替バグ (M10 で発見・修正) を回避しているが、
  `AccountsSettingsView` 自体は依然としてシート専用の「閉じる」ボタン付き
  `NavigationStack` ラッパーのまま。将来的にアカウント一覧・設定全体を
  もう少し整理してもよい。
- **Composer を macOS のタイトルバー閉じるボタンで閉じた場合**: M10 で
  追加した「下書きとして保存/破棄」の確認ダイアログは、iOS の sheet
  スワイプ dismiss は `.interactiveDismissDisabled` でブロックしているが、
  macOS の Composer ウィンドウをタイトルバーの赤信号ボタンで閉じる操作は
  素通りしてしまう (未保存の変更が確認なしに失われる)。`NSWindowDelegate`
  相当のフック (SwiftUI では `.onExitCommand`/window close 監視) を使った
  対応が必要。

## 添付・パーサ

- **RFC 2231 ファイル名のみのメール**: 現在ピン留めしている mailcore2
  リビジョンは RFC 2231 拡張パラメータ (`filename*=UTF-8''...`) のみで
  日本語ファイル名を送ってくる他クライアント/サーバのメールでファイル名を
  拾えない (`docs/verify.md` M8 節)。RFC 2047 encoded-word へのフォール
  バックパースを自前で足すか、mailcore2 側の対応を待つ必要がある。
- **cid インライン画像のスクリーンショット検証**: `m8-02-cid-inline-image.png`
  は本文冒頭までしか写っておらず、実際の `<img src="cid:...">` 部分は
  スクロールしないと画面に入らない。事前スクロールしてから撮る改善が
  今後の課題として残る。

## パフォーマンス

- 100k メッセージでの検証は otegami-relay の watch 対象アカウントや
  `AttachmentFetcher` の大量ファイル同時取得など、まだ計測していない
  経路がいくつかある。`docs/performance.md` に記載の計測は一覧・検索・
  スレッド化のみ。

## リリース・配布

- **GitHub リポジトリの public 化**: 現状 private。公開時にリポジトリ名を
  `mailapp` から `otegami` に変更する (計画書の当初合意)。
- **App Store / TestFlight 配布**: 未着手。Google OAuth 審査 (作者配布
  ビルドのみ必要) もこのタイミングで対応する。
