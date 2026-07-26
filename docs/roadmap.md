# ロードマップ (将来項目)

M0〜M11、および design-phase-2/3 (デザイン刷新・端末内翻訳の実装) で
実装しなかった/意図的にスコープ外にした項目、または実装中に見つかった
既知の制約のうち、いつか手を付ける価値があるものをまとめる。優先順位は
付けていない。各項目の背景・詳細は該当する参照先を見ること。

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

## iCloud アカウント同期 (M11)

- **verify スクリプトの iCloud KVS/Keychain 汚染**: M11 で
  `scripts/verify-ios-m1.sh`/`verify-ios-m6.sh`/`verify-ios-icloud.sh` は
  `xcrun simctl uninstall` を `simctl erase` に置き換えた (この開発環境の
  シミュレータでは KVS/Keychain がアプリのアンインストールでは消えず、
  以前の verify 実行で cloud へ push されたアカウントが「フレッシュ
  インストール」のはずの状態に復活してしまうため —
  `.claude/skills/verify/SKILL.md` の M11 節参照)。M2-M5/M7-M9 の
  verify スクリプトはまだ旧来の `simctl uninstall` のままなので、将来
  これらを実行する際に同じ現象で account 一覧の前提が崩れる可能性が残って
  いる。実際に踏んだら同じ `simctl erase` パターンに揃えること。
- **Gmail アカウントの cloud 挿入パスの実機確認**: `.oauth2` kind の
  アカウントが cloud から新規挿入された場合の自動同期開始
  (`GoogleOAuth.TokenStore.hasStoredRefreshToken`/`.accessToken(for:)`
  経由) は実 Google アカウントでの 2 台間確認をしていない
  (`PENDING.md`)。

## UI/UX

- **To/Cc フィールドのトークン化**: `ComposerView` はカンマ区切りのプレーン
  テキストフィールド (plan: "トークン化は later")。宛先ごとのチップ表示・
  連絡先補完は未実装。
- **HTML 引用返信**: 返信の本文引用は常にプレーンテキスト (`> ` 引用)。
  元メールが HTML の場合の HTML 引用 (`<blockquote>`) は未対応
  (`ComposerView.quotedBody(from:)` — HTML 本文があっても
  `HTMLTextExtractor.plainText(fromHTML:)` でプレーンテキスト化してから
  `> ` を行頭に付けるだけ)。設計メモ (実装未着手、スコープが
  Composer 全体の HTML 対応に及ぶため一旦記録に留める):
  - 前提として `ComposerView` の `bodyText: String` (プレーンテキスト
    専用の `@State`) を HTML 本文にも対応させる必要がある。単純に
    `TextEditor` を `WKWebView` ベースのリッチエディタに差し替えるのは
    範囲が大きい — 現実的な最小実装は「ユーザー入力は従来通りプレーン
    テキストのまま、送信時に元メールが HTML だった場合だけ本文の末尾に
    `<blockquote>` で HTML 引用を追記する」という非対称なアプローチ
    (ユーザーが打った本文はプレーンテキストの `TextEditor` のまま、
    引用部分だけ HTML)。
  - 送信側 (`OpQueueProcessor.apply(op:)` の `.send` ケース /
    `MailCoreMessageBuilder`) は現状プレーンテキストの `text/plain`
    単一パートしか組み立てていない。HTML 引用を送るには
    `multipart/alternative` (text/plain フォールバック + text/html) の
    構築に対応する必要があり、`BuiltMessage`/`ComposeDraft` のデータ
    モデルにも HTML 本文フィールドを追加する必要がある。
  - 元メールの HTML をそのまま `<blockquote>` に埋め込むと、外部画像/
    スクリプトなど `HTMLExternalResourceScanner`/`WKContentRuleList` が
    受信時にブロックしている要素がそのまま送信メールに乗ってしまう
    リスクがある — サニタイズ (許可タグのホワイトリスト化など) が別途
    必要になりそうで、この点も実装コストを押し上げている。
  - 優先度: 実用上はプレーンテキスト引用でも支障は小さく (多くの
    メールクライアントはプレーンテキスト引用を許容する)、上記のスコープ
    の大きさに見合う優先度ではないと判断し、このセッションでは実装を
    見送った。
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
- **`OtegamiColor` への `warning` 系トークン追加**: 同期エラーバナー等が
  今も標準の `.orange` (システムセマンティックカラー) のまま。デザイン
  システムに正式な警告色トークンを追加するかどうかは未検討
  (`docs/design-system.md` design-phase-2 節)。
- **一括操作の「移動」の汎用フォルダピッカー化**: 現状はアーカイブ固定
  (スワイプの 1g と同じ宛先)。任意フォルダへの移動 UI は未実装
  (`docs/design-system.md` design-phase-2 節)。
- **スワイプの「操作」設定の汎用化**: 設定の「スワイプのクイック操作」は
  現状「既読/未読 と アーカイブ、どちらが先か」の1軸のみ。翻訳/後で の
  スワイプスロットが実装された時点で、任意のアクションを任意のスロット
  に割り当てる汎用レジストリへの拡張を再検討する (`docs/design-system.md`
  design-phase-3 節)。
- **`AccountFilterChip` 横スクロール行の多アカウント時の見た目**: アカウント
  5つ以上でチップ列がどう見えるか、実機の多アカウント環境ではまだ確認
  していない (`docs/design-system.md` design-phase-2 節)。

## 翻訳

- **一覧に要約を出す設定 (1l) の実装**: 設定のトグル自体はあり永続化も
  するが、一覧行への反映は未実装。スクロール中の英文メール全件に対して
  いつ・どのタイミングで背景翻訳/要約を走らせるか (トリガー・キャッシュ
  戦略) の設計が必要 (`docs/design-system.md` design-phase-3 節)。
- **翻訳のストリーミング表示**: `TranslationService.translateStream` は
  エンジン層に実装・実機検証済みだが、UI 側 (`TranslationBar`) は現状
  非ストリーミング版のみを呼んでいる。段落ごとの逐次更新表示は見送った
  (`docs/translation.md`/`docs/design-system.md` design-phase-3 節)。
- **返信の引用部分を除いた英訳**: 「英語に翻訳して送る」は `> ` 引用も
  含めて本文全体を丸ごと翻訳する。引用と新規入力を区別して新規入力分
  だけを翻訳するには本文の構造化が必要で見送った
  (`docs/design-system.md` design-phase-3 節)。
- **iOS Simulator の `.app` プロセスから呼んだ場合の
  `FoundationModels.LanguageModelError -1`**: エンジン層は同一マシンの
  `swift test` からは毎回成功するため、コード側の不具合ではなく
  Simulator/toolchain 固有の制限と見ているが、根本原因の調査（実機での
  再検証、または Apple 側の既知の制限の有無確認）はまだ済んでいない
  (`docs/translation.md`/`PENDING.md`)。

## パフォーマンス

- 100k メッセージでの検証は otegami-relay の watch 対象アカウントや
  `AttachmentFetcher` の大量ファイル同時取得など、まだ計測していない
  経路がいくつかある。`docs/performance.md` に記載の計測は一覧・検索・
  スレッド化のみ。

## リリース・配布

- **App Store / TestFlight 配布**: 未着手。Google OAuth 審査 (作者配布
  ビルドのみ必要) もこのタイミングで対応する。
- **macOS ビルドの Developer ID 署名 + notarization**: `make mac-app` で
  `dist/Otegami.app` を生成できるが、現状はアドホック署名のまま。自分の
  Mac 以外に配る場合は Gatekeeper 対応が必要 (`PENDING.md`「公開時に
  必要な対応」参照)。
